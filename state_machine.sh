#!/usr/bin/env bash
set -euo pipefail

# 状态机定义
declare -A STATE_MACHINE=()

# 状态定义
STATE_FINAL_GOOD="good"
STATE_FINAL_SKIP="skip"
STATE_BUILD_NOT_STARTED="not_started"
STATE_BUILD_BUILDING="building"
STATE_BUILD_FAILED="failed"
STATE_BUILD_SUCCEEDED="succeeded"
STATE_BUILD_TIMEOUT="timeout"
STATE_BUILD_INTERRUPTED="interrupted"
STATE_BUILD_TYPE_INCREMENTAL="incremental"
STATE_BUILD_TYPE_CLEAN="clean"
STATE_ARTIFACT_CHECK_ERROR="artifact_check_error"
STATE_ARTIFACT_INVALID="artifact_invalid"
STATE_REASON_BUILD_REACH_MAX_TRIES="build_reach_max_tries"
STATE_REASON_STALE_BUILDING_STATE="stale_building_state"

# 状态转换规则
# 格式: [当前状态:事件] -> 新状态
declare -A STATE_TRANSITIONS=(
    # 构建相关转换
    ["not_started:build_start"]="building"
    ["building:build_success"]="succeeded"
    ["building:build_failed"]="failed"
    ["building:build_timeout"]="timeout"
    ["building:build_interrupted"]="interrupted"

    # 产物检查相关转换
    ["succeeded:artifact_valid"]="ready"
    ["succeeded:artifact_invalid"]="failed"
    ["succeeded:artifact_check_error"]="check_error"

    # 重试相关转换
    ["failed:retry_incremental"]="building"
    ["failed:retry_clean"]="building"
    ["timeout:retry_continue"]="building"
    ["interrupted:retry_continue"]="building"
    ["check_error:retry_clean"]="building"
)

# 状态机类工厂函数
create_state_machine() {
    local commit="$1"
    local util_script="${2:-}"

    if [[ -z "$util_script" && -n "${SCHEDULER_UTIL_SCRIPT:-}" ]]; then
        util_script="$SCHEDULER_UTIL_SCRIPT"
    fi

    # 加载util脚本
    if [[ -n "$util_script" && -f "$util_script" ]]; then
        # shellcheck disable=SC1090
        source "$util_script"
    fi

    # 获取当前状态
    local current_state
    current_state=$(get_current_state "$commit")

    # 返回状态机方法集合
    cat <<EOF
{
  "commit": "$commit",
  "state": "$current_state",
  "set_state": "state_machine_set_state '$commit'",
  "get_state": "state_machine_get_state '$commit'",
  "get_context": "state_machine_get_context '$commit'",
  "transition": "state_machine_transition '$commit'",
  "validate": "state_machine_validate_transition"
}
EOF
}

# 设置状态（内部函数）
state_machine_set_state() {
    local commit="$1"
    local new_state="$2"
    local reason="${3:-}"

    local current_state
    current_state=$(get_current_state "$commit")

    # 验证状态转换是否合法
    if ! state_machine_validate_transition "$current_state" "$new_state"; then
        echo "Error: Invalid state transition from $current_state to $new_state" >&2
        return 1
    fi

    # 更新状态
    scheduler_set_status_fields "$commit" "STATE=$new_state"

    echo "[state] $commit: $current_state -> $new_state${reason:+ ($reason)}"
}

# 获取当前状态
state_machine_get_state() {
    local commit="$1"
    get_current_state "$commit"
}

# 获取状态上下文
state_machine_get_context() {
    local commit="$1"
    local context=""
    context+="BUILD_STATE=$(get_build_state "$commit" || echo "unknown") "
    context+="BUILD_TYPE=$(get_build_type "$commit" || echo "unknown") "
    context+="ATTEMPT_COUNT=$(get_attempt_count "$commit" || echo "0") "
    context+="FAILURE_REASON=$(get_failure_reason "$commit" || echo "none") "
    context+="ARTIFACT_STATE=$(get_artifact_state "$commit" || echo "unknown")"
    echo "$context"
}

# 状态转换
state_machine_transition() {
    local commit="$1"
    local event="$2"
    local reason="${3:-}"

    local current_state
    current_state=$(get_current_state "$commit")

    # 根据事件确定目标状态
    local target_state=""
    case "$event" in
        "build_start")
            target_state="building"
            ;;
        "build_success")
            target_state="succeeded"
            ;;
        "build_failed")
            target_state="failed"
            ;;
        "build_timeout")
            target_state="timeout"
            ;;
        "build_interrupted")
            target_state="interrupted"
            ;;
        "artifact_valid")
            target_state="ready"
            ;;
        "artifact_invalid")
            target_state="artifact_invalid"
            ;;
        "artifact_check_error")
            target_state="artifact_check_error"
            ;;
        "final_good")
            target_state="good"
            ;;
        "final_bad")
            target_state="bad"
            ;;
        "final_skip")
            target_state="skip"
            ;;
        *)
            echo "Error: Unknown event: $event" >&2
            return 1
            ;;
    esac

    # 执行状态转换
    state_machine_set_state "$commit" "$target_state" "$reason"
}

# 验证状态转换
state_machine_validate_transition() {
    local from="$1"
    local to="$2"

    # 允许的最终状态转换
    case "$to" in
        "good"|"bad"|"skip"|"artifact_failed"|"test_failed"|"timeout")
            # 可以从任何状态转换为最终状态
            return 0
            ;;
    esac

    # 检查是否有定义的状态转换规则
    local key="${from}:${to}"
    if [[ -n "${STATE_TRANSITIONS[$key]:-}" ]]; then
        return 0
    fi

    # 允许的运行时状态转换
    case "$to" in
        "running"|"finished"|"pending")
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# 检查util函数是否可用
_scheduler_func_available() {
    type "$1" >/dev/null 2>&1
}

# 获取当前状态
get_current_state() {
    local commit="$1"
    if _scheduler_func_available "scheduler_get_status_field"; then
        scheduler_get_status_field "$commit" STATE || echo "pending"
    else
        echo "pending"
    fi
}

# 获取构建状态
get_build_state() {
    local commit="$1"
    if _scheduler_func_available "scheduler_get_status_field"; then
        scheduler_get_status_field "$commit" BUILD_STATE || echo "not_started"
    else
        echo "not_started"
    fi
}

# 获取构建类型
get_build_type() {
    local commit="$1"
    if _scheduler_func_available "scheduler_get_status_field"; then
        scheduler_get_status_field "$commit" BUILD_TYPE || echo "none"
    else
        echo "none"
    fi
}

# 获取尝试次数
get_attempt_count() {
    local commit="$1"
    if _scheduler_func_available "scheduler_get_status_field"; then
        scheduler_get_status_field "$commit" BUILD_ATTEMPT_COUNT || echo "0"
    else
        echo "0"
    fi
}

# 获取失败原因
get_failure_reason() {
    local commit="$1"
    if _scheduler_func_available "scheduler_get_status_field"; then
        scheduler_get_status_field "$commit" BUILD_FAILURE_REASON || echo "none"
    else
        echo "none"
    fi
}

# 获取产物状态
get_artifact_state() {
    local commit="$1"
    if _scheduler_func_available "scheduler_get_status_field"; then
        scheduler_get_status_field "$commit" ARTIFACT_STATE || echo "not_started"
    else
        echo "not_started"
    fi
}

# 获取产物失败原因
get_artifact_failure_reason() {
    local commit="$1"
    if _scheduler_func_available "scheduler_get_status_field"; then
        scheduler_get_status_field "$commit" ARTIFACT_FAILURE_REASON || echo "none"
    else
        echo "none"
    fi
}

# 获取构建状态快照（对应原load_build_state_snapshot函数）
get_build_state_snapshot() {
    local commit="$1"

    local build_state artifact_failure_reason build_attempt_count build_type
    build_state=$(get_build_state "$commit")
    artifact_failure_reason=$(get_artifact_failure_reason "$commit")
    build_attempt_count=$(get_attempt_count "$commit")
    build_type=$(get_build_type "$commit")

    # 设置默认值
    [[ -z "$build_state" ]] && build_state="$STATE_BUILD_NOT_STARTED"
    [[ -z "$artifact_failure_reason" ]] && artifact_failure_reason="none"
    [[ -z "$build_type" ]] && build_type="$STATE_BUILD_TYPE_INCREMENTAL"

    # 输出变量赋值（可以通过eval解析）
    cat <<EOF
BUILD_STATE="$build_state"
ARTIFACT_FAILURE_REASON="$artifact_failure_reason"
BUILD_ATTEMPT_COUNT="$build_attempt_count"
BUILD_TYPE="$build_type"
EOF
}

# 构建决策函数（对应原determine_build_plan函数）
determine_build_plan() {
    local max_try="$1"
    local build_dir_path="$2"
    local build_attempt_count="$3"
    local always_clean_build="$4"
    local build_state="$5"
    local artifact_failure_reason="$6"
    local build_type="$7"

    local result_build_type="$STATE_BUILD_TYPE_INCREMENTAL"
    local start_new_build="true"
    local continuing_previous_build="false"
    local fallback_reason="none"
    local stop_build_loop="false"
    local need_clean_build=0

    if (( build_attempt_count >= max_try )); then
        echo "$STATE_BUILD_TYPE_INCREMENTAL"
        echo "true"
        echo "false"
        echo "$STATE_REASON_BUILD_REACH_MAX_TRIES"
        echo "true"
        return 0
    fi

    if [[ "$build_state" == "$STATE_BUILD_NOT_STARTED" || "$always_clean_build" == "true" ]]; then
        result_build_type="$STATE_BUILD_TYPE_CLEAN"
        echo "$result_build_type"
        echo "$start_new_build"
        echo "$continuing_previous_build"
        echo "$fallback_reason"
        echo "$stop_build_loop"
        return 0
    fi

    # build_dir 不存在/为空，或者第一次构建，必须 clean build。
    if [[ ! -d "$build_dir_path" ]] || [[ -z "$(ls -A "$build_dir_path" 2>/dev/null)" || ((build_attempt_count == 0)) ]]; then
        need_clean_build=1
    fi

    # 状态机决策逻辑
    case "$build_state" in
        "$STATE_BUILD_BUILDING")
            start_new_build="true"
            continuing_previous_build="false"
            fallback_reason="$STATE_REASON_STALE_BUILDING_STATE"
            if [[ "$need_clean_build" -eq 1 ]]; then
                result_build_type="$STATE_BUILD_TYPE_CLEAN"
            else
                result_build_type="$STATE_BUILD_TYPE_INCREMENTAL"
            fi
            ;;
        "$STATE_BUILD_FAILED")
            if [[ "$build_type" == "$STATE_BUILD_TYPE_INCREMENTAL" ]]; then
                result_build_type="$STATE_BUILD_TYPE_CLEAN"
                fallback_reason="incremental_build_failed"
            fi
            ;;
        "$STATE_BUILD_SUCCEEDED")
            if [[ "$artifact_failure_reason" == "$STATE_ARTIFACT_CHECK_ERROR" ||
                  "$artifact_failure_reason" == "$STATE_ARTIFACT_INVALID" ]]; then
                result_build_type="$STATE_BUILD_TYPE_CLEAN"
                fallback_reason="${artifact_failure_reason}"
            fi
            ;;
        "$STATE_BUILD_TIMEOUT"|"$STATE_BUILD_INTERRUPTED")
            result_build_type="$STATE_BUILD_TYPE_INCREMENTAL"
            # 注意：这里需要检查failure_reason是否以"_continued"结尾，但原函数检查的是STATE_PREV_BUILD_FAILURE_REASON
            # 由于我们只有build_state，这里简化处理：总是开始新的构建
            start_new_build="true"
            continuing_previous_build="false"
            fallback_reason="${build_type}_build_${build_state}_retry_new_attempt"
            ;;
        *)
            if [[ "$need_clean_build" -eq 1 ]]; then
                result_build_type="$STATE_BUILD_TYPE_CLEAN"
                fallback_reason="build_dir_is_empty_or_not_exist"
            fi
            ;;
    esac

    echo "$result_build_type"
    echo "$start_new_build"
    echo "$continuing_previous_build"
    echo "$fallback_reason"
    echo "$stop_build_loop"
}

# 处理构建结果（对应原handle_build_outcome函数）
handle_build_outcome() {
    local commit="$1"
    local build_type="$2"
    local continuing_previous_build="$3"
    local build_status="$4"
    local artifact_check_status="$5"
    local artifact_dir="$6"

    local failure_reason

    if [[ "$build_status" -eq 0 ]]; then
        scheduler_mark_build_succeeded "$commit"
        if [[ "$artifact_check_status" -eq 0 ]]; then
            scheduler_mark_artifact_ready "$commit" "$artifact_dir" "build"
            return 0
        fi

        if [[ "$artifact_check_status" -eq 125 ]]; then
            if [[ "$build_type" == "clean" ]]; then
                scheduler_mark_artifact_failed "$commit" "artifact_check_error"
                return 0
            fi
            scheduler_mark_artifact_failure_reason "$commit" "artifact_check_error"
            return 1
        fi

        if [[ "$build_type" == "clean" ]]; then
            scheduler_mark_artifact_failed "$commit" "artifact_invalid"
            return 0
        fi
        scheduler_mark_artifact_failure_reason "$commit" "artifact_invalid"
        return 1
    fi

    if [[ "$build_status" -eq 124 ]]; then
        failure_reason="${build_type}_build_timeout"
        [[ "$continuing_previous_build" == "true" ]] && failure_reason="${failure_reason}_continued"
        echo "$failure_reason"
        scheduler_mark_build_timeout "$commit" "$failure_reason"
    elif [[ "$build_status" -eq 130 || "$build_status" -eq 143 ]]; then
        failure_reason="${build_type}_build_interrupted"
        [[ "$continuing_previous_build" == "true" ]] && failure_reason="${failure_reason}_continued"
        echo "$failure_reason"
        scheduler_mark_build_interrupted "$commit" "$failure_reason"
    else
        failure_reason="${build_type}_build_failed"
        echo "$failure_reason"
        scheduler_mark_build_failed "$commit" "$failure_reason"
    fi

    return 1
}

# 状态检查函数
is_building() {
    local state="${1:-$(get_current_state "$commit")}"
    [[ "$state" == "building" ]]
}

is_succeeded() {
    local state="${1:-$(get_current_state "$commit")}"
    [[ "$state" == "succeeded" ]]
}

is_failed() {
    local state="${1:-$(get_current_state "$commit")}"
    [[ "$state" == "failed" ]]
}

is_timeout() {
    local state="${1:-$(get_current_state "$commit")}"
    [[ "$state" == "timeout" ]]
}

is_interrupted() {
    local state="${1:-$(get_current_state "$commit")}"
    [[ "$state" == "interrupted" ]]
}

is_ready() {
    local state="${1:-$(get_current_state "$commit")}"
    [[ "$state" == "ready" ]]
}

# 状态转换函数
transition_to() {
    local commit="$1"
    local new_state="$2"
    local reason="${3:-}"

    local current_state
    current_state=$(get_current_state "$commit")

    # 记录状态转换
    echo "[state] Transitioning $commit: $current_state -> $new_state${reason:+ ($reason)}"

    # 执行状态转换
    scheduler_set_status_fields "$commit" "STATE=$new_state"
}

# 构建状态快照
capture_build_snapshot() {
    local commit="$1"
    local snapshot_file="$2"

    cat > "$snapshot_file" <<EOF
COMMIT=$commit
TIMESTAMP=$(date +%s)
STATE=$(get_current_state "$commit")
BUILD_STATE=$(get_build_state "$commit")
BUILD_TYPE=$(get_build_type "$commit")
ATTEMPT_COUNT=$(get_attempt_count "$commit")
FAILURE_REASON=$(get_failure_reason "$commit")
ARTIFACT_STATE=$(get_artifact_state "$commit")
EOF
}

# 从快照恢复
restore_build_snapshot() {
    local commit="$1"
    local snapshot_file="$2"

    if [[ -f "$snapshot_file" ]]; then
        # shellcheck disable=SC1090
        source "$snapshot_file"

        # 恢复状态
        scheduler_set_status_fields "$commit" \
            "STATE=$STATE" \
            "BUILD_STATE=$BUILD_STATE" \
            "BUILD_TYPE=$BUILD_TYPE" \
            "BUILD_ATTEMPT_COUNT=$ATTEMPT_COUNT" \
            "BUILD_FAILURE_REASON=$FAILURE_REASON"

        return 0
    fi

    return 1
}

# 导出状态机函数
export STATE_FINAL_GOOD STATE_FINAL_SKIP STATE_BUILD_NOT_STARTED STATE_BUILD_BUILDING
export STATE_BUILD_FAILED STATE_BUILD_SUCCEEDED STATE_BUILD_TIMEOUT STATE_BUILD_INTERRUPTED
export STATE_BUILD_TYPE_INCREMENTAL STATE_BUILD_TYPE_CLEAN STATE_ARTIFACT_CHECK_ERROR
export STATE_ARTIFACT_INVALID STATE_REASON_BUILD_REACH_MAX_TRIES STATE_REASON_STALE_BUILDING_STATE