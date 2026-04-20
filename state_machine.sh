#!/usr/bin/env bash
set -euo pipefail

# 状态机定义
declare -A STATE_MACHINE=()

# 状态定义
# 顶层状态
STATE_PENDING="pending"
STATE_RUNNING="running"
STATE_FINISHED="finished"
# 最终状态
STATE_FINAL_GOOD="good"
STATE_FINAL_SKIP="skip"
STATE_FINAL_BAD="bad"
STATE_FINAL_ARTIFACT_FAILED="artifact_failed"
STATE_FINAL_TEST_FAILED="test_failed"
STATE_FINAL_TIMEOUT="timeout"
# 构建状态
STATE_BUILD_NOT_STARTED="not_started"
STATE_BUILD_BUILDING="building"
STATE_BUILD_FAILED="build_failed"
STATE_BUILD_SUCCEEDED="build_succeeded"
STATE_BUILD_TIMEOUT="build_timeout"
STATE_BUILD_INTERRUPTED="build_interrupted"
# 构建类型
STATE_BUILD_TYPE_INCREMENTAL="incremental"
STATE_BUILD_TYPE_CLEAN="clean"
# 产物状态
STATE_ARTIFACT_CHECK_ERROR="artifact_check_error"
STATE_ARTIFACT_INVALID="artifact_invalid"
STATE_ARTIFACT_NOT_STARTED="artifact_not_started"
STATE_ARTIFACT_ACQUIRING="artifact_acquiring"
STATE_ARTIFACT_READY="artifact_ready"
STATE_ARTIFACT_FAILED="artifact_failed"
# 原因常量
STATE_REASON_BUILD_REACH_MAX_TRIES="build_reach_max_tries"
STATE_REASON_STALE_BUILDING_STATE="stale_building_state"
STATE_READY="ready"

# 事件定义
EVENT_BUILD_START="build_start"
EVENT_BUILD_SUCCESS="build_success"
EVENT_BUILD_FAILED="build_failed"
EVENT_BUILD_TIMEOUT="build_timeout"
EVENT_BUILD_INTERRUPTED="build_interrupted"
EVENT_ARTIFACT_VALID="artifact_valid"
EVENT_ARTIFACT_INVALID="artifact_invalid"
EVENT_ARTIFACT_CHECK_ERROR="artifact_check_error"
EVENT_FINAL_GOOD="final_good"
EVENT_FINAL_BAD="final_bad"
EVENT_FINAL_SKIP="final_skip"
EVENT_FINAL_ARTIFACT_FAILED="final_artifact_failed"
EVENT_FINAL_TEST_FAILED="final_test_failed"
EVENT_FINAL_TIMEOUT="final_timeout"
EVENT_RETRY_INCREMENTAL="retry_incremental"
EVENT_RETRY_CLEAN="retry_clean"
EVENT_RETRY_CONTINUE="retry_continue"

# 状态转换规则
# 格式: [当前状态:事件] -> 新状态
declare -A STATE_TRANSITIONS=(
    # 构建相关转换
    ["$STATE_BUILD_NOT_STARTED:$EVENT_BUILD_START"]="$STATE_BUILD_BUILDING"
    ["$STATE_BUILD_BUILDING:$EVENT_BUILD_SUCCESS"]="$STATE_BUILD_SUCCEEDED"
    ["$STATE_BUILD_BUILDING:$EVENT_BUILD_FAILED"]="$STATE_BUILD_FAILED"
    ["$STATE_BUILD_BUILDING:$EVENT_BUILD_TIMEOUT"]="$STATE_BUILD_TIMEOUT"
    ["$STATE_BUILD_BUILDING:$EVENT_BUILD_INTERRUPTED"]="$STATE_BUILD_INTERRUPTED"
    # 防止stale building状态：如果当前是building状态，允许直接转换为其他构建状态
    ["$STATE_BUILD_BUILDING:$EVENT_BUILD_START"]="$STATE_BUILD_BUILDING"  # 已经在第83行定义了，这里明确注释

    # 产物检查相关转换
    ["$STATE_BUILD_SUCCEEDED:$EVENT_ARTIFACT_VALID"]="$STATE_READY"
    ["$STATE_BUILD_SUCCEEDED:$EVENT_ARTIFACT_INVALID"]="$STATE_BUILD_FAILED"
    ["$STATE_BUILD_SUCCEEDED:$EVENT_ARTIFACT_CHECK_ERROR"]="$STATE_ARTIFACT_CHECK_ERROR"

    # 重试相关转换
    ["$STATE_BUILD_FAILED:$EVENT_RETRY_INCREMENTAL"]="$STATE_BUILD_BUILDING"
    ["$STATE_BUILD_FAILED:$EVENT_RETRY_CLEAN"]="$STATE_BUILD_BUILDING"
    ["$STATE_BUILD_TIMEOUT:$EVENT_RETRY_CONTINUE"]="$STATE_BUILD_BUILDING"
    ["$STATE_BUILD_INTERRUPTED:$EVENT_RETRY_CONTINUE"]="$STATE_BUILD_BUILDING"
    ["$STATE_ARTIFACT_CHECK_ERROR:$EVENT_RETRY_CLEAN"]="$STATE_BUILD_BUILDING"

    # 额外的构建开始转换（兼容现有代码）
    ["$STATE_BUILD_BUILDING:$EVENT_BUILD_START"]="$STATE_BUILD_BUILDING"  # 允许从 building 状态重新开始构建
    ["$STATE_BUILD_FAILED:$EVENT_BUILD_START"]="$STATE_BUILD_BUILDING"
    ["$STATE_BUILD_TIMEOUT:$EVENT_BUILD_START"]="$STATE_BUILD_BUILDING"
    ["$STATE_BUILD_INTERRUPTED:$EVENT_BUILD_START"]="$STATE_BUILD_BUILDING"
    ["$STATE_ARTIFACT_CHECK_ERROR:$EVENT_BUILD_START"]="$STATE_BUILD_BUILDING"
    ["$STATE_READY:$EVENT_BUILD_START"]="$STATE_BUILD_BUILDING"

    # 防止stale building状态问题：直接从building状态转换为其他构建状态
    ["$STATE_BUILD_BUILDING:$EVENT_BUILD_SUCCESS"]="$STATE_BUILD_SUCCEEDED"
    ["$STATE_BUILD_BUILDING:$EVENT_BUILD_FAILED"]="$STATE_BUILD_FAILED"
    ["$STATE_BUILD_BUILDING:$EVENT_BUILD_TIMEOUT"]="$STATE_BUILD_TIMEOUT"
    ["$STATE_BUILD_BUILDING:$EVENT_BUILD_INTERRUPTED"]="$STATE_BUILD_INTERRUPTED"
    ["$STATE_BUILD_BUILDING:$EVENT_ARTIFACT_VALID"]="$STATE_READY"
    ["$STATE_BUILD_BUILDING:$EVENT_ARTIFACT_INVALID"]="$STATE_BUILD_FAILED"
    ["$STATE_BUILD_BUILDING:$EVENT_ARTIFACT_CHECK_ERROR"]="$STATE_ARTIFACT_CHECK_ERROR"

    # 最终状态转换（特权转换，允许从任何状态）
    # 这些转换不在此表中定义，由state_machine_validate_transition特殊处理
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

# 设置状态（内部函数，主要用于直接设置状态，不通过事件）
state_machine_set_state() {
    local commit="$1"
    local new_state="$2"
    local reason="${3:-}"

    local current_state
    current_state=$(get_current_state "$commit")
    echo "[state] try to set state: cur:$current_state new_state:$new_state"
    # 基础验证：只检查最终状态特权转换
    # 注意：对于事件驱动的转换，验证在state_machine_transition中完成
    case "$new_state" in
        "$STATE_FINAL_GOOD")
            scheduler_set_status_fields "$commit" "STATE=finished" "FINAL_STATUS=$new_state"
            echo "[state] $commit: $current_state -> $new_state (final)${reason:+ ($reason)}"
            return 0
            ;;
        "$STATE_FINAL_BAD")
            scheduler_set_status_fields "$commit" "STATE=finished" "FINAL_STATUS=$new_state"
            echo "[state] $commit: $current_state -> $new_state (final)${reason:+ ($reason)}"
            return 0
            ;;
        "$STATE_FINAL_SKIP")
            scheduler_set_status_fields "$commit" "STATE=finished" "FINAL_STATUS=$new_state"
            echo "[state] $commit: $current_state -> $new_state (final)${reason:+ ($reason)}"
            return 0
            ;;
        "$STATE_FINAL_ARTIFACT_FAILED")
            scheduler_set_status_fields "$commit" \
                "STATE=finished" \
                "FINAL_STATUS=$new_state" \
                "ARTIFACT_STATE=failed" \
                "ARTIFACT_FAILURE_REASON=${reason:-none}"
            echo "[state] $commit: $current_state -> $new_state (final)${reason:+ ($reason)}"
            return 0
            ;;
        "$STATE_FINAL_TEST_FAILED")
            scheduler_set_status_fields "$commit" "STATE=finished" "FINAL_STATUS=$new_state"
            echo "[state] $commit: $current_state -> $new_state (final)${reason:+ ($reason)}"
            return 0
            ;;
        "$STATE_FINAL_TIMEOUT")
            scheduler_set_status_fields "$commit" "STATE=finished" "FINAL_STATUS=$new_state"
            echo "[state] $commit: $current_state -> $new_state (final)${reason:+ ($reason)}"
            return 0
            ;;
        *)
            # 对于非最终状态转换，只记录警告但不阻止
            # 真正的验证应该在state_machine_transition中通过事件完成
            if [[ "$current_state" != "$new_state" ]]; then
                echo "[state] Warning: Direct state transition from $current_state to $new_state${reason:+ ($reason)}"
                echo "[state] Note: For event-driven transitions, use state_machine_transition()"
            fi
            ;;
    esac
    # 根据状态类型更新相应的字段
    case "$new_state" in
        "$STATE_BUILD_BUILDING")
            # BUILDING 状态需要保持现有的 BUILD_TYPE
            local build_type
            build_type=$(get_build_type "$commit" || echo "$STATE_BUILD_TYPE_INCREMENTAL")
            scheduler_set_status_fields "$commit" \
                "BUILD_STATE=$new_state" \
                "BUILD_TYPE=$build_type" \
                "ARTIFACT_STATE=acquiring" \
                "ARTIFACT_SOURCE=build" \
                "ARTIFACT_FAILURE_REASON=none" \
                "BUILD_FAILURE_REASON=none" \
                "FINAL_STATUS=pending" \
                "STATE=running"
            ;;
        "$STATE_BUILD_SUCCEEDED")
            scheduler_set_status_fields "$commit" \
                "BUILD_STATE=$new_state" \
                "ARTIFACT_FAILURE_REASON=none" \
                "BUILD_FAILURE_REASON=none"
            ;;
        "$STATE_BUILD_FAILED"|"$STATE_BUILD_TIMEOUT"|"$STATE_BUILD_INTERRUPTED")
            scheduler_set_status_fields "$commit" \
                "BUILD_STATE=$new_state" \
                "BUILD_FAILURE_REASON=${reason:-none}"
            ;;
        "$STATE_READY")
            # READY 状态需要额外的参数（artifact_dir, artifact_source），这里只设置基础字段
            # 具体的 artifact 信息由专门的函数设置
            scheduler_set_status_fields "$commit" \
                "ARTIFACT_STATE=ready" \
                "ARTIFACT_FAILURE_REASON=none"
            ;;
        "$STATE_ARTIFACT_CHECK_ERROR"|"$STATE_ARTIFACT_INVALID"|"$STATE_ARTIFACT_FAILED")
            scheduler_set_status_fields "$commit" \
                "ARTIFACT_STATE=failed" \
                "ARTIFACT_FAILURE_REASON=${reason:-none}"
            ;;
        *)
            # 默认情况：只更新 BUILD_STATE
            scheduler_set_status_fields "$commit" "BUILD_STATE=$new_state"
            ;;
    esac

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

    # 查找转换规则
    local key="${current_state}:${event}"
    local target_state="${STATE_TRANSITIONS[$key]:-}"

    # 如果转换表中没有定义，检查是否为最终状态转换特权
    if [[ -z "$target_state" ]]; then
        # 最终状态转换特权检查
        case "$event" in
            "$EVENT_FINAL_GOOD")
                target_state="$STATE_FINAL_GOOD"
                ;;
            "$EVENT_FINAL_BAD")
                target_state="$STATE_FINAL_BAD"
                ;;
            "$EVENT_FINAL_SKIP")
                target_state="$STATE_FINAL_SKIP"
                ;;
            "$EVENT_FINAL_ARTIFACT_FAILED")
                target_state="$STATE_FINAL_ARTIFACT_FAILED"
                ;;
            "$EVENT_FINAL_TEST_FAILED")
                target_state="$STATE_FINAL_TEST_FAILED"
                ;;
            "$EVENT_FINAL_TIMEOUT")
                target_state="$STATE_FINAL_TIMEOUT"
                ;;
            *)
                echo "Error: No transition defined from $current_state via event $event" >&2
                return 1
                ;;
        esac
    fi

    # 执行状态转换
    state_machine_set_state "$commit" "$target_state" "$reason"
}

# 验证状态转换（基础验证，不依赖事件）
state_machine_validate_transition() {
    local from="$1"
    local to="$2"

    # 允许的最终状态转换（特权转换）
    case "$to" in
        "$STATE_FINAL_GOOD"|"$STATE_FINAL_BAD"|"$STATE_FINAL_SKIP"|"$STATE_FINAL_ARTIFACT_FAILED"|"$STATE_FINAL_TEST_FAILED"|"$STATE_FINAL_TIMEOUT")
            # 可以从任何状态转换为最终状态
            return 0
            ;;
    esac

    # 允许的运行时状态转换
    case "$to" in
        "$STATE_RUNNING"|"$STATE_FINISHED"|"$STATE_PENDING")
            return 0
            ;;
        *)
            # 对于其他转换，需要基于事件的验证
            # 这里返回1表示需要更详细的验证（在state_machine_transition中处理）
            return 1
            ;;
    esac
}

# 检查util函数是否可用
_scheduler_func_available() {
    type "$1" >/dev/null 2>&1
}

# 获取当前构建状态
get_current_state() {
    local commit="$1"
    if _scheduler_func_available "scheduler_get_status_field"; then
        # 首先检查是否为最终状态
        local final_status
        final_status=$(scheduler_get_status_field "$commit" FINAL_STATUS 2>/dev/null || echo "pending")
        if [[ "$final_status" != "pending" ]]; then
            echo "$final_status"
        else
            scheduler_get_status_field "$commit" BUILD_STATE || echo "$STATE_BUILD_NOT_STARTED"
        fi
    else
        echo "$STATE_BUILD_NOT_STARTED"
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

# 检查构建系统是否支持继续构建
_check_build_system_supports_resume() {
    local build_dir_path="$1"

    # 如果构建目录不存在或为空，不支持继续构建
    [[ ! -d "$build_dir_path" ]] && return 1
    [[ -z "$(ls -A "$build_dir_path" 2>/dev/null)" ]] && return 1

    # 检查常见的构建系统文件
    if [[ -f "$build_dir_path/build.ninja" ]] && [[ -s "$build_dir_path/build.ninja" ]]; then
        # Ninja 构建系统支持增量构建，通常可以继续
        return 0
    elif [[ -f "$build_dir_path/Makefile" ]] && [[ -s "$build_dir_path/Makefile" ]]; then
        # Make 构建系统支持增量构建，通常可以继续
        return 0
    elif [[ -f "$build_dir_path/CMakeCache.txt" ]]; then
        # CMake 构建系统：如果只是构建阶段中断，通常可以继续
        # 但如果是配置阶段中断，可能需要重新配置
        # 这里保守假设可以继续，因为CMakeCache.txt存在表明配置已完成
        return 0
    fi

    # 没有找到已知的构建系统文件
    return 1
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

    # 如果构建目录存在但不为空，检查是否包含有效的构建系统文件
    if [[ "$need_clean_build" -eq 0 ]] && [[ -d "$build_dir_path" ]] && [[ -n "$(ls -A "$build_dir_path" 2>/dev/null)" ]]; then
        # 检查常见的构建系统文件是否存在且有效（对于build.ninja，还要检查是否非空）
        local valid_build_file=0

        if [[ -f "$build_dir_path/build.ninja" ]] && [[ -s "$build_dir_path/build.ninja" ]]; then
            valid_build_file=1
        elif [[ -f "$build_dir_path/Makefile" ]] && [[ -s "$build_dir_path/Makefile" ]]; then
            valid_build_file=1
        elif [[ -f "$build_dir_path/CMakeCache.txt" ]]; then
            # CMakeCache.txt 可能为空但仍然有效
            valid_build_file=1
        fi

        if [[ "$valid_build_file" -eq 0 ]]; then
            # 构建目录存在但不包含有效的构建系统文件，需要clean构建
            need_clean_build=1
        fi
    fi

    # 状态机决策逻辑
    case "$build_state" in
        "$STATE_BUILD_BUILDING")
            # 之前构建中断（进程意外退出）
            # 检查构建系统是否支持继续构建
            if _check_build_system_supports_resume "$build_dir_path"; then
                # 构建系统支持继续构建，尝试增量构建
                result_build_type="$STATE_BUILD_TYPE_INCREMENTAL"
                start_new_build="true"
                continuing_previous_build="false"
                fallback_reason="resume_interrupted_build"
                echo "[determine_build_plan] Interrupted build detected, attempting to resume with incremental build" >&2
            else
                # 构建系统不支持继续构建或构建目录无效，使用clean构建
                result_build_type="$STATE_BUILD_TYPE_CLEAN"
                start_new_build="true"
                continuing_previous_build="false"
                fallback_reason="$STATE_REASON_STALE_BUILDING_STATE"
                echo "[determine_build_plan] Interrupted build detected, build dir invalid or unsupported build system, using clean build" >&2
            fi

            # 如果之前已经决定需要clean构建，覆盖上述决策
            if [[ "$need_clean_build" -eq 1 ]]; then
                result_build_type="$STATE_BUILD_TYPE_CLEAN"
                fallback_reason="${fallback_reason}_need_clean"
            fi
            ;;
        "$STATE_BUILD_FAILED")
            if [[ "$build_type" == "$STATE_BUILD_TYPE_INCREMENTAL" ]]; then
                # 增量构建失败，尝试clean构建
                result_build_type="$STATE_BUILD_TYPE_CLEAN"
                fallback_reason="incremental_build_failed"
            else
                # clean构建也失败，继续使用clean构建
                result_build_type="$STATE_BUILD_TYPE_CLEAN"
                fallback_reason="clean_build_failed_retry"
            fi
            ;;
        "$STATE_BUILD_SUCCEEDED")
            if [[ "$artifact_failure_reason" == "$STATE_ARTIFACT_CHECK_ERROR" ||
                  "$artifact_failure_reason" == "$STATE_ARTIFACT_INVALID" ]]; then
                # 构建成功但产物检查失败，需要clean构建重新生成产物
                result_build_type="$STATE_BUILD_TYPE_CLEAN"
                fallback_reason="${artifact_failure_reason}"
            fi
            ;;
        "$STATE_BUILD_TIMEOUT"|"$STATE_BUILD_INTERRUPTED")
            # 超时或被中断的构建，检查是否可以继续
            result_build_type="$STATE_BUILD_TYPE_INCREMENTAL"
            fallback_reason="${build_type}_build_${build_state}_retry_incremental"
            start_new_build="true"
            continuing_previous_build="false"
            ;;
        *)
            # 其他状态（如not_started等）
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
        # 构建成功
        state_machine_transition "$commit" "$EVENT_BUILD_SUCCESS"
        if [[ "$artifact_check_status" -eq 0 ]]; then
            # artifact 有效
            state_machine_transition "$commit" "$EVENT_ARTIFACT_VALID"
            scheduler_mark_artifact_ready "$commit" "$artifact_dir" "build"
            return 0
        fi

        if [[ "$artifact_check_status" -eq 125 ]]; then
            # artifact 检查错误
            if [[ "$build_type" == "clean" ]]; then
                state_machine_transition "$commit" "$EVENT_ARTIFACT_CHECK_ERROR" "artifact_check_error"
                return 0
            fi
            state_machine_transition "$commit" "$EVENT_ARTIFACT_CHECK_ERROR" "artifact_check_error"
            return 1
        fi

        # artifact 无效
        if [[ "$build_type" == "clean" ]]; then
            state_machine_transition "$commit" "$EVENT_ARTIFACT_INVALID" "artifact_invalid"
            return 0
        fi
        state_machine_transition "$commit" "$EVENT_ARTIFACT_INVALID" "artifact_invalid"
        return 1
    fi

    if [[ "$build_status" -eq 124 ]]; then
        failure_reason="${build_type}_build_timeout"
        [[ "$continuing_previous_build" == "true" ]] && failure_reason="${failure_reason}_continued"
        echo "$failure_reason"
        state_machine_transition "$commit" "$EVENT_BUILD_TIMEOUT" "$failure_reason"
    elif [[ "$build_status" -eq 130 || "$build_status" -eq 143 ]]; then
        failure_reason="${build_type}_build_interrupted"
        [[ "$continuing_previous_build" == "true" ]] && failure_reason="${failure_reason}_continued"
        echo "$failure_reason"
        state_machine_transition "$commit" "$EVENT_BUILD_INTERRUPTED" "$failure_reason"
    else
        failure_reason="${build_type}_build_failed"
        echo "$failure_reason"
        state_machine_transition "$commit" "$EVENT_BUILD_FAILED" "$failure_reason"
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
# 导出状态常量
export STATE_PENDING STATE_RUNNING STATE_FINISHED
export STATE_FINAL_GOOD STATE_FINAL_SKIP STATE_FINAL_BAD STATE_FINAL_ARTIFACT_FAILED STATE_FINAL_TEST_FAILED STATE_FINAL_TIMEOUT
export STATE_BUILD_NOT_STARTED STATE_BUILD_BUILDING STATE_BUILD_FAILED STATE_BUILD_SUCCEEDED STATE_BUILD_TIMEOUT STATE_BUILD_INTERRUPTED
export STATE_BUILD_TYPE_INCREMENTAL STATE_BUILD_TYPE_CLEAN
export STATE_ARTIFACT_CHECK_ERROR STATE_ARTIFACT_INVALID STATE_ARTIFACT_NOT_STARTED STATE_ARTIFACT_ACQUIRING STATE_ARTIFACT_READY STATE_ARTIFACT_FAILED
export STATE_REASON_BUILD_REACH_MAX_TRIES STATE_REASON_STALE_BUILDING_STATE
export STATE_READY

# 导出事件常量
export EVENT_BUILD_START EVENT_BUILD_SUCCESS EVENT_BUILD_FAILED EVENT_BUILD_TIMEOUT EVENT_BUILD_INTERRUPTED
export EVENT_ARTIFACT_VALID EVENT_ARTIFACT_INVALID EVENT_ARTIFACT_CHECK_ERROR
export EVENT_FINAL_GOOD EVENT_FINAL_BAD EVENT_FINAL_SKIP EVENT_FINAL_ARTIFACT_FAILED EVENT_FINAL_TEST_FAILED EVENT_FINAL_TIMEOUT
export EVENT_RETRY_INCREMENTAL EVENT_RETRY_CLEAN EVENT_RETRY_CONTINUE