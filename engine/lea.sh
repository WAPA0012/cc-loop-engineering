#!/bin/bash
# lea.sh — LEA 循环引擎主入口
# 用法: bash lea.sh <任务配置文件>
#
# 任务配置文件定义:
#   PROJECT_DIR     — 项目目录
#   GOAL             — 任务目标描述（自然语言）
#   VERIFY_CMD       — gate 验证命令（怎么算成功）
#   VERIFY_TYPE      — 验证类型（test/benchmark/custom）
#   SUCCESS_CRITERIA — 成功标准（如 "pass>=70" 或 "recall>=0.9"）
#   MAX_ROUNDS       — 最大循环轮次（默认 20）
#   MODEL            — 强模型调用方式（默认 claude -p）
#   SEARCH_MODEL     — 搜索者用的轻量模型（默认同 MODEL）
set -uo pipefail

LEA_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENGINE_DIR="$LEA_DIR/engine"
ROLES_DIR="$LEA_DIR/roles"
STATE_DIR_DEFAULT="$LEA_DIR/state"

# ---- 加载辅助函数 ----
source "$ENGINE_DIR/utils.sh"    # render_prompt, run_agent, run_search, generate_repo_map
source "$ENGINE_DIR/gate.sh"     # gate_verify（场景可插拔）

# ---- 加载任务配置 ----
CONFIG_FILE="${1:?用法: lea.sh <任务配置文件> [--mode solo|team]}"
if [ ! -f "$CONFIG_FILE" ]; then
    CONFIG_FILE="$LEA_DIR/scenarios/$1"
fi
source "$CONFIG_FILE"

# ---- 命令行参数覆盖（--mode 等）----
shift
while [ "$#" -gt 0 ]; do
    case "$1" in
        --mode)    MODE="$2"; shift 2 ;;
        --rounds)  MAX_ROUNDS="$2"; shift 2 ;;
        *)         shift ;;
    esac
done

# STATE_DIR 在配置里可能定义，否则用默认
STATE_DIR="${STATE_DIR:-$STATE_DIR_DEFAULT}"
RESULT_FILE="$STATE_DIR/result.json"
mkdir -p "$STATE_DIR"

# 默认值
PROJECT_DIR="${PROJECT_DIR:?配置缺少 PROJECT_DIR}"
GOAL="${GOAL:?配置缺少 GOAL}"
VERIFY_CMD="${VERIFY_CMD:-}"
VERIFY_TYPE="${VERIFY_TYPE:-test}"
SUCCESS_CRITERIA="${SUCCESS_CRITERIA:-}"
MAX_ROUNDS="${MAX_ROUNDS:-20}"
MODEL="${MODEL:-claude}"
SEARCH_MODEL="${SEARCH_MODEL:-$MODEL}"
STATE_DIR="${STATE_DIR:-$STATE_DIR_DEFAULT}"
MODE="${MODE:-solo}"   # solo = 单一工作者(默认)，team = 多角色(planner调度)
ROUND=0
NO_PROGRESS_COUNT=0

mkdir -p "$STATE_DIR"

# 状态文件路径
TASK_STATE="$STATE_DIR/task.json"        # 任务目标 + 验证标准
PROGRESS_FILE="$STATE_DIR/progress.json"  # 规划者每轮更新的进度
HISTORY_FILE="$STATE_DIR/history.jsonl"   # 每轮的完整记录
DECISION_FILE="$STATE_DIR/decision.json"  # 规划者本轮决策

# ---- 初始化任务状态 ----
init_state() {
    if [ ! -f "$TASK_STATE" ]; then
        cat > "$TASK_STATE" <<EOF
{
  "goal": $(echo "$GOAL" | jq -Rs .),
  "project_dir": "$PROJECT_DIR",
  "verify_cmd": $(echo "$VERIFY_CMD" | jq -Rs .),
  "verify_type": "$VERIFY_TYPE",
  "success_criteria": $(echo "$SUCCESS_CRITERIA" | jq -Rs .),
  "status": "in_progress",
  "started_at": "$(date -Iseconds)"
}
EOF
    fi

    if [ ! -f "$PROGRESS_FILE" ]; then
        echo '{"round":0,"done":false,"open_issues":[],"completed":[],"notes":"初始化"}' > "$PROGRESS_FILE"
    fi

    if [ ! -f "$HISTORY_FILE" ]; then
        : > "$HISTORY_FILE"
    fi
}

# log() 已在 utils.sh 定义，此处不再重复

# ---- 主循环 ----
init_state
log "============================================"
log "  LEA 启动"
log "  目标: $GOAL"
log "  项目: $PROJECT_DIR"
log "  验证: $VERIFY_TYPE — $VERIFY_CMD"
log "  上限: $MAX_ROUNDS 轮"
log "============================================"

while [ $ROUND -lt $MAX_ROUNDS ]; do
    ROUND=$((ROUND + 1))
    SOLO_DONE=false

    # ---- 人机协作：检测信号文件 ----
    # 用户随时可以创建信号文件来介入：
    #   touch state/stop_signal    → 立即停止循环
    #   echo "新指令" > state/pause_signal  → 暂停，把指令注入下一轮 prompt
    if [ -f "$STATE_DIR/stop_signal" ]; then
        log "[用户] 收到停止信号，结束循环"
        rm -f "$STATE_DIR/stop_signal"
        break
    fi
    # 读取暂停指令（如果有），注入到本轮
    USER_DIRECTIVE=""
    if [ -f "$STATE_DIR/pause_signal" ]; then
        USER_DIRECTIVE=$(cat "$STATE_DIR/pause_signal" 2>/dev/null)
        log "[用户] 介入指令: $USER_DIRECTIVE"
        rm -f "$STATE_DIR/pause_signal"
    fi

    log ""
    log "━━━ 第 $ROUND 轮 ━━━"

    # 1. 决策：solo 模式跳过 planner，worker 自己决策；team 模式由 planner 调度
    rm -f "$DECISION_FILE" "$RESULT_FILE"
    REPO_MAP=$(generate_repo_map "$PROJECT_DIR")
    PROGRESS=$(cat "$PROGRESS_FILE")

    if [ "$MODE" = "solo" ]; then
        # ---- solo 模式：直接派 worker，它自己读 progress 自己决策 ----
        log "[solo] 第 $ROUND 轮，worker 自主工作..."
        exec_solo "$GOAL" "$REPO_MAP" "$PROGRESS" "$ROUND" "$USER_DIRECTIVE"

        # 读 worker 的结果
        solo_status=$(jq -r '.status // "in_progress"' "$RESULT_FILE" 2>/dev/null)
        solo_summary=$(jq -r '.summary // ""' "$RESULT_FILE" 2>/dev/null)
        log "[solo] 状态: $solo_status — ${solo_summary:0:100}"

        ACTION="solo_work"
        ROLE="solo"
        TARGET="$solo_summary"
        REASON="$solo_status"

        # solo done/blocked 不直接 break——让下面的 history/progress 更新执行完再 break
        if [ "$solo_status" = "done" ]; then
            SOLO_DONE=true
        elif [ "$solo_status" = "blocked" ]; then
            log "[solo] worker 报告受阻：$solo_summary"
            NO_PROGRESS_COUNT=$((NO_PROGRESS_COUNT + 1))
        fi
    else
        # ---- team 模式：planner 决策 → 派角色 ----
        effective_goal="$GOAL"
        if [ -n "$USER_DIRECTIVE" ]; then
            effective_goal="$GOAL

【用户介入指令】$USER_DIRECTIVE"
        fi
        PLANNER_PROMPT=$(render_prompt "$(cat "$ROLES_DIR/planner.md")" \
            GOAL "$effective_goal" \
            PROJECT_DIR "$PROJECT_DIR" \
            REPO_MAP "$REPO_MAP" \
            PROGRESS "$PROGRESS" \
            ROUND "$ROUND" \
            DECISION_FILE "$DECISION_FILE")

        log "[planner] 规划中..."
        run_agent "$PLANNER_PROMPT" "$MODEL" "Read,Glob,Grep,Write" "" 3600 "no"

        if [ ! -f "$DECISION_FILE" ]; then
            log "[planner] 未产出决策，跳过本轮"
            continue
        fi

        ACTION=$(jq -r '.action // "stop"' "$DECISION_FILE" 2>/dev/null)
        TARGET=$(jq -r '.target // ""' "$DECISION_FILE" 2>/dev/null)
        REASON=$(jq -r '.reason // ""' "$DECISION_FILE" 2>/dev/null)
        ROLE=$(jq -r '.role // "builder"' "$DECISION_FILE" 2>/dev/null)

        log "[planner] 决策: $ROLE → $ACTION ($TARGET)"
        log "[planner] 理由: $REASON"

        if [ "$ACTION" = "stop" ] || [ "$ACTION" = "done" ] || [ "$ROLE" = "stop" ]; then
            log "规划者判定任务完成，停止"
            jq -n --argjson round "$ROUND" --arg role "$ROLE" --arg action "$ACTION" \
                '{round:$round, last_role:$role, last_action:$action, last_gate:"stop", updated_at:now}' > "$PROGRESS_FILE"
            break
        fi

        SEARCH_CATEGORY=$(jq -r '.category // "general"' "$DECISION_FILE" 2>/dev/null)
        case "$ROLE" in
            search)    exec_searcher "$TARGET" "$SEARCH_CATEGORY" ;;
            innovator) exec_innovator "$TARGET" ;;
            builder)   exec_builder "$TARGET" "$ACTION" ;;
            critic)    exec_critic "$TARGET" ;;
            tester)    exec_tester "$TARGET" ;;
            reviewer)  exec_reviewer "$TARGET" ;;
            *)         log "未知角色: $ROLE，跳过"; continue ;;
        esac
    fi

    # 3. gate 验证（仅对改动代码的角色；solo 也触发 gate）
    GATE_STATUS="skip"
    GATE_DETAIL=""
    case "$ROLE" in
        builder|solo)
            GATE_RESULT=$(gate_verify "$VERIFY_TYPE" "$VERIFY_CMD" "$PROJECT_DIR" "$SUCCESS_CRITERIA" "$STATE_DIR")
            GATE_STATUS=$(echo "$GATE_RESULT" | head -1)
            GATE_DETAIL=$(echo "$GATE_RESULT" | tail -n +2)

            if [ "$GATE_STATUS" = "accept" ]; then
                log "[gate] ✓ 通过 — $GATE_DETAIL"
                gate_git "$PROJECT_DIR" add -A
                gate_git "$PROJECT_DIR" -c user.email=lea@local -c user.name=lea commit -q -m "round $ROUND: $ROLE $ACTION" 2>/dev/null
                NO_PROGRESS_COUNT=0
            else
                log "[gate] ✗ 回滚 — $GATE_DETAIL"
                gate_git "$PROJECT_DIR" checkout -- . 2>/dev/null
                gate_git "$PROJECT_DIR" clean -fdq 2>/dev/null
                NO_PROGRESS_COUNT=$((NO_PROGRESS_COUNT + 1))
            fi
            ;;
    esac

    # 4. 记录历史（用 jq 安全转义，避免 TARGET/ACTION 里的引号/换行破坏 JSON）
    jq -nc --argjson round "$ROUND" --arg role "$ROLE" --arg action "$ACTION" \
          --arg target "$TARGET" --arg gate "$GATE_STATUS" \
        '{round:$round, role:$role, action:$action, target:$target, gate:$gate}' >> "$HISTORY_FILE"

    # 5. 更新 progress.json（planner 下一轮读这个，必须有最新状态）
    LAST_GATE="$GATE_STATUS"
    jq -n --argjson round "$ROUND" --arg role "$ROLE" --arg action "$ACTION" \
          --arg gate "$GATE_STATUS" --arg target "$TARGET" \
        '{round:$round, last_role:$role, last_action:$action, last_gate:$gate, last_target:$target, updated_at:now}' > "$PROGRESS_FILE"

    # 6. 早停
    if [ $NO_PROGRESS_COUNT -ge 5 ]; then
        log "连续 $NO_PROGRESS_COUNT 轮无进展，停止"
        break
    fi

    # 7. solo 模式完成检测（在 history/progress 写入之后才 break）
    if [ "$SOLO_DONE" = "true" ]; then
        log "[solo] worker 报告任务完成，停止"
        break
    fi
done

# ---- 最终验证 ----
log ""
log "============================================"
log "  循环结束（$ROUND 轮）"
log "============================================"
if [ -n "$VERIFY_CMD" ]; then
    FINAL=$(gate_verify "$VERIFY_TYPE" "$VERIFY_CMD" "$PROJECT_DIR" "$SUCCESS_CRITERIA" "$STATE_DIR")
    log "最终验证: $(echo "$FINAL" | head -1) — $(echo "$FINAL" | tail -n +2)"
fi
