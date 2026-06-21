#!/bin/bash
# gate.sh — CC-Loop 机械验证（场景可插拔）
#
# gate_verify <type> <cmd> <project_dir> <success_criteria> <state_dir>
# 输出: 第一行 accept|reject，后续行是详情
#
# type 可选:
#   test     — 跑测试，解析 pass/fail（支持 node --test 和 pytest）
#   benchmark — 跑 benchmark，判断指标是否达标
#   custom   — 跑自定义命令，退出码 0 = accept
#   none     — 不验证（直接 accept）

gate_verify() {
    local type="$1"
    local cmd="$2"
    local project_dir="$3"
    local criteria="$4"
    local state_dir="$5"

    if [ -z "$cmd" ] || [ "$type" = "none" ]; then
        echo "accept"
        echo "(无验证命令，默认通过)"
        return
    fi

    local output
    output=$(cd "$project_dir" 2>/dev/null && eval "$cmd" 2>&1) || true

    case "$type" in
        test)
            gate_check_test "$output" "$criteria"
            ;;
        benchmark)
            gate_check_benchmark "$output" "$criteria"
            ;;
        custom)
            # 退出码 0 = accept（eval 已经跑过，检查 output 里有没有 error）
            if echo "$output" | grep -qiE 'error|traceback|failed'; then
                echo "reject"
                echo "自定义验证发现错误"
            else
                echo "accept"
                echo "自定义验证通过"
            fi
            ;;
        *)
            echo "accept"
            echo "(未知验证类型 $type，默认通过)"
            ;;
    esac
}

# ---- 测试验证 ----
gate_check_test() {
    local output="$1"
    local criteria="$2"
    local pass fail

    # pytest 格式
    if echo "$output" | grep -qiE '[0-9]+\s+passed'; then
        pass=$(echo "$output" | grep -oiE '[0-9]+\s+passed' | grep -oE '[0-9]+' | head -1)
        fail=$(echo "$output" | grep -oiE '[0-9]+\s+(failed|error)' | grep -oE '[0-9]+' | head -1)
    # node --test 格式
    elif echo "$output" | grep -qiE '\bpass\s+[0-9]+'; then
        pass=$(echo "$output" | grep -oiE '\bpass\s+[0-9]+' | grep -oE '[0-9]+' | head -1)
        fail=$(echo "$output" | grep -oiE '\bfail\s+[0-9]+' | grep -oE '[0-9]+' | head -1)
    else
        echo "reject"
        echo "无法解析测试输出"
        return
    fi

    pass=${pass:-0}
    fail=${fail:-0}

    # 有 criteria 就检查达标，否则只看 fail==0
    if [ -n "$criteria" ]; then
        # criteria 形如 "pass>=70"（提取阈值，支持小数如 "pass>=85.5"）
        local threshold
        threshold=$(echo "$criteria" | grep -oE '[0-9]+(\.[0-9]+)?' | tail -1)
        if [ -n "$threshold" ] && [ "$pass" -ge "$threshold" ]; then
            echo "accept"
            echo "$pass pass, $fail fail (达标 $criteria)"
        else
            echo "reject"
            echo "$pass pass, $fail fail (未达 $criteria)"
        fi
    elif [ "$fail" -eq 0 ]; then
        echo "accept"
        echo "$pass pass, 0 fail"
    else
        echo "reject"
        echo "$pass pass, $fail fail"
    fi
}

# ---- benchmark 验证 ----
gate_check_benchmark() {
    local output="$1"
    local criteria="$2"

    # criteria 形如 "recall>=0.9" 或 "latency<=100"
    local metric_name op threshold
    metric_name=$(echo "$criteria" | grep -oiE '^[a-z_]+' | head -1)
    op=$(echo "$criteria" | grep -oE '>=|<=|>|<' | head -1)
    threshold=$(echo "$criteria" | grep -oE '[0-9.]+$' | head -1)

    if [ -z "$threshold" ]; then
        echo "accept"
        echo "(无阈值，默认通过)"
        return
    fi

    # 从输出里提取指标值（尝试多种格式）
    local value
    value=$(echo "$output" | grep -oiE "${metric_name}[:\s]*[0-9.]+" | grep -oE '[0-9.]+' | head -1)
    if [ -z "$value" ]; then
        # 尝试百分比格式
        value=$(echo "$output" | grep -oiE '[0-9]+(\.[0-9]+)?\s*%' | grep -oE '[0-9.]+' | head -1)
    fi

    if [ -z "$value" ]; then
        echo "reject"
        echo "无法从输出提取 $metric_name"
        return
    fi

    # 比较
    local ok
    case "$op" in
        ">=") awk "BEGIN{exit !($value >= $threshold)}" && ok=1 || ok=0 ;;
        "<=") awk "BEGIN{exit !($value <= $threshold)}" && ok=1 || ok=0 ;;
        ">")  awk "BEGIN{exit !($value > $threshold)}" && ok=1 || ok=0 ;;
        "<")  awk "BEGIN{exit !($value < $threshold)}" && ok=1 || ok=0 ;;
        *)    ok=1 ;;
    esac

    if [ "$ok" = "1" ]; then
        echo "accept"
        echo "$metric_name=$value ($criteria 达标)"
    else
        echo "reject"
        echo "$metric_name=$value ($criteria 未达标)"
    fi
}
