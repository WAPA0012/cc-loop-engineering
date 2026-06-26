#!/bin/bash
# utils.sh — CC-Loop 引擎共享函数

# ---- 日志（在 utils.sh 定义，避免单独 source 时 log: command not found）----
log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "${STATE_DIR:-/tmp}/cc-loop.log" 2>/dev/null || echo "[$(date '+%H:%M:%S')] $*"; }

# ---- 字面 token 替换（不用 sed，安全处理特殊字符）----
render_prompt() {
    local template="$1"; shift
    local result="$template"
    while [ "$#" -ge 2 ]; do
        local token="{{$1}}"
        result=$(awk -v pat="$token" -v rep="$2" '
            BEGIN { n = length(pat) }
            {
                line = $0; res = ""
                while ((i = index(line, pat)) > 0) {
                    res = res substr(line, 1, i-1) rep
                    line = substr(line, i + n)
                }
                print res line
            }
        ' <<<"$result")
        shift 2
    done
    printf '%s' "$result"
}

# ---- 生成 repo map（符号索引）----
generate_repo_map() {
    local project_dir="$1"
    (cd "$project_dir" 2>/dev/null && grep -rnE '^\s*(def |class |async def |function |export (default )?function |export class |func |type )' \
        --include='*.py' --include='*.js' --include='*.mjs' --include='*.ts' --include='*.go' \
        . 2>/dev/null \
        | grep -v node_modules | grep -v '.git' | grep -v '/eval/' | grep -v '/dist/' | grep -v '/build/' \
        | head -150) || echo "(无法生成 repo map)"
}

# ---- 调用 agent（强模型）----
# 参数: prompt, model, tools, session, timeout
# timeout 仅作极端兜底（默认 3600s = 1小时）；正常结束靠 AI 写 result.json
run_agent() {
    local prompt="$1"
    local model="${2:-claude}"
    local tools="${3:-Read,Edit,Write,Bash,Glob,Grep}"
    local session="${4:-}"
    local timeout="${5:-3600}"
    local attempt=0 max_retries=2 rate_retry=0 max_rate=5 rate_wait=60

    while true; do
        local extra_args=""
        [ -n "$tools" ] && extra_args="$extra_args --allowedTools \"$tools\""
        extra_args="$extra_args --dangerously-skip-permissions"
        local use_mcp="${6:-yes}"
        if [ "$use_mcp" = "yes" ]; then
            extra_args="$extra_args --mcp-config $ENGINE_DIR/mcp_config.json --strict-mcp-config"
        else
            extra_args="$extra_args --strict-mcp-config"
        fi
        [ -n "$session" ] && extra_args="$extra_args --resume $session"

        # 用临时文件接收 stdout，避免管道阻塞（管道会等 claude 退出才返回，timeout 杀不掉）
        local tmp_out
        tmp_out=$(mktemp)
        # setsid 创建新进程组，timeout 后 kill 整个组（含 claude node 子进程）
        echo "$prompt" | setsid bash -c "timeout -k 10 $timeout claude -p --output-format json $extra_args" >"$tmp_out" 2>&1 &
        local grp_pid=$!
        # 等待 claude 自然结束（AI 写完 result.json 后 claude 返回，bash -c 退出）
        wait $grp_pid 2>/dev/null || true
        local result
        result=$(cat "$tmp_out" 2>/dev/null)
        rm -f "$tmp_out" 2>/dev/null
        # 兜底清理（timeout 触发时 setsid 进程组可能残留）
        pkill -9 -x claude 2>/dev/null || true

        if echo "$result" | grep -qiE "rate.limit|too many|429|throttl|overloaded|quota"; then
            rate_retry=$((rate_retry + 1))
            [ $rate_retry -gt $max_rate ] && break
            sleep "$rate_wait"
            rate_wait=$((rate_wait * 2))
            [ $rate_wait -gt 600 ] && rate_wait=600
            continue
        fi

        if echo "$result" | jq -e . >/dev/null 2>&1; then
            printf '%s' "$result"
            return 0
        fi

        attempt=$((attempt + 1))
        [ $attempt -ge $max_retries ] && break
        sleep $((attempt * 5))
    done
    echo '{"result":"","session_id":"","usage":{"input_tokens":0}}'
    return 1
}

# ---- 调用搜索者（stepfun 真联网检索 + step-3.7-flash 结构化整理）----
# 统一走 search_mcp.py 的 do_search，与各角色在循环内调用的 search MCP 工具是同一套实现。
# 参数: query [category_or_focus]  支持 category 或自由 focus 文本
run_search() {
    local query="$1"
    local arg2="${2:-}"
    # 判断 arg2 是固定 category 还是自由 focus
    local category="general" focus=""
    case "$arg2" in
        latest|papers|projects|articles|pitfalls|comparison|tutorial|spec|general|"")
            category="${arg2:-general}"
            ;;
        *)
            focus="$arg2"
            ;;
    esac
    # 直接调用 search_mcp.py 的 do_search（真联网 + LLM 整理）
    # key/URL/model 由 search_mcp.py 自行读环境变量，此处不传空值（避免覆盖默认值）
    python "$ENGINE_DIR/search_mcp.py" --once "$query" "$category" "$focus" 2>/dev/null
}

# ---- 心跳 ----
heartbeat() { date +%s > "$STATE_DIR/heartbeat.txt" 2>/dev/null || true; }

# ============ 角色执行器 ============
# 注意：RESULT_FILE 在 loop.sh 里 STATE_DIR 定义后设置

exec_searcher() {
    local query="$1"
    local category="${2:-general}"
    heartbeat
    log "[searcher] 搜索 ($category): $query"
    local search_result
    search_result=$(run_search "$query" "$category")
    # 多次搜索追加（不同角度的结果累积到同一个文件）
    if [ "$category" = "general" ]; then
        echo "$search_result" > "$STATE_DIR/search_result.md"
    else
        echo -e "\n\n--- $category 搜索结果 ---\n" >> "$STATE_DIR/search_result.md"
        echo "$search_result" >> "$STATE_DIR/search_result.md"
    fi
    log "[searcher] 完成 ($category)，结果存入 search_result.md"
}

exec_innovator() {
    local context="$1"
    heartbeat
    local search_result=""
    [ -f "$STATE_DIR/search_result.md" ] && search_result=$(cat "$STATE_DIR/search_result.md")
    local repo_map
    repo_map=$(generate_repo_map "$PROJECT_DIR")
    local prompt
    prompt=$(render_prompt "$(cat "$ROLES_DIR/innovator.md")" \
        GOAL "$GOAL" PROJECT_DIR "$PROJECT_DIR" \
        CONTEXT "$context" \
        SEARCH_RESULTS "$search_result" \
        REPO_MAP "$repo_map" \
        RESULT_FILE "$STATE_DIR/innovations.json")
    log "[innovator] 创意中..."
    run_agent "$prompt" "$MODEL" "Read,Edit,Write,Bash,Glob,Grep" "" 3600 "yes" >/dev/null
}

exec_solo() {
    local goal="$1"
    local repo_map="$2"
    local progress="$3"
    local round="$4"
    local user_directive="${5:-}"
    heartbeat
    # 如果有用户介入指令，追加到目标后面
    local effective_goal="$goal"
    if [ -n "$user_directive" ]; then
        effective_goal="$goal

【用户介入指令】$user_directive"
    fi
    local prompt
    prompt=$(render_prompt "$(cat "$ROLES_DIR/solo.md")" \
        GOAL "$effective_goal" \
        PROJECT_DIR "$PROJECT_DIR" \
        TEST_CMD "${VERIFY_CMD:-}" \
        REPO_MAP "$repo_map" \
        PROGRESS "$progress" \
        RESULT_FILE "$RESULT_FILE")
    log "[solo] worker 自主工作（轮 $round）..."
    rm -f "$RESULT_FILE"
    run_agent "$prompt" "$MODEL" "Read,Edit,Write,Bash,Glob,Grep" "" 3600 "yes" >/dev/null
}

exec_builder() {
    local target="$1"
    local action="${2:-build}"
    heartbeat
    local repo_map
    repo_map=$(generate_repo_map "$PROJECT_DIR")
    local progress
    progress=$(cat "$PROGRESS_FILE" 2>/dev/null || echo '{}')
    local prompt
    prompt=$(render_prompt "$(cat "$ROLES_DIR/builder.md")" \
        GOAL "$GOAL" PROJECT_DIR "$PROJECT_DIR" \
        TASK "$action: $target" \
        REPO_MAP "$repo_map" \
        PROGRESS "$progress" \
        RESULT_FILE "$RESULT_FILE")
    log "[builder] 执行: $action ($target)"
    rm -f "$RESULT_FILE"
    run_agent "$prompt" "$MODEL" "Read,Edit,Write,Bash,Glob,Grep" "" 3600 >/dev/null
    local status
    status=$(jq -r '.status // "unknown"' "$RESULT_FILE" 2>/dev/null || echo "unknown")
    log "[builder] 状态: $status"
}

exec_critic() {
    local target="$1"
    heartbeat
    local repo_map
    repo_map=$(generate_repo_map "$PROJECT_DIR")
    local prompt
    prompt=$(render_prompt "$(cat "$ROLES_DIR/critic.md")" \
        GOAL "$GOAL" PROJECT_DIR "$PROJECT_DIR" \
        TARGET "$target" \
        REPO_MAP "$repo_map" \
        RESULT_FILE "$RESULT_FILE")
    log "[critic] 审查: $target"
    rm -f "$RESULT_FILE"
    run_agent "$prompt" "$MODEL" "Read,Edit,Write,Bash,Glob,Grep" "" 3600 "yes" >/dev/null
}

exec_tester() {
    local target="$1"
    heartbeat
    local repo_map
    repo_map=$(generate_repo_map "$PROJECT_DIR")
    local prompt
    prompt=$(render_prompt "$(cat "$ROLES_DIR/tester.md")" \
        GOAL "$GOAL" PROJECT_DIR "$PROJECT_DIR" \
        TARGET "$target" \
        REPO_MAP "$repo_map" \
        TEST_CMD "${VERIFY_CMD:-}" \
        RESULT_FILE "$RESULT_FILE")
    log "[tester] 写测试: $target"
    rm -f "$RESULT_FILE"
    run_agent "$prompt" "$MODEL" "Read,Edit,Write,Bash,Glob,Grep" "" 3600 >/dev/null
}

exec_reviewer() {
    local target="$1"
    heartbeat
    local repo_map
    repo_map=$(generate_repo_map "$PROJECT_DIR")
    # 获取 diff（对比上次提交，因为 gate 可能已经 commit 了 builder 的改动）
    local diff_text
    diff_text=$(cd "$PROJECT_DIR" && git diff HEAD~1 HEAD 2>/dev/null | head -200)
    if [ -z "$diff_text" ]; then
        diff_text="(无 diff——可能是本轮没有代码改动，或改动已被后续 commit 覆盖)"
    fi
    local prompt
    prompt=$(render_prompt "$(cat "$ROLES_DIR/reviewer.md")" \
        GOAL "$GOAL" PROJECT_DIR "$PROJECT_DIR" \
        TARGET "$target" \
        DIFF "$diff_text" \
        REPO_MAP "$repo_map" \
        RESULT_FILE "$RESULT_FILE")
    log "[reviewer] 评估改动影响: $target"
    rm -f "$RESULT_FILE"
    run_agent "$prompt" "$MODEL" "Read,Edit,Write,Bash,Glob,Grep" "" 3600 >/dev/null
}

# ---- gate git 辅助 ----
gate_git() {
    local project_dir="$1"; shift
    (cd "$project_dir" && git "$@")
}
