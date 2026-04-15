#!/usr/bin/env bash
set -u

base_dir="${SCHEDULER_BASE_DIR:?SCHEDULER_BASE_DIR is not set}"
log_dir="${SCHEDULER_LOG_DIR:?SCHEDULER_LOG_DIR is not set}"
state_file="${SCHEDULER_STATE_FILE:?SCHEDULER_STATE_FILE is not set}"
summary_log="${SCHEDULER_SUMMARY_LOG:?SCHEDULER_SUMMARY_LOG is not set}"
newer_commit="${SCHEDULER_NEWER_COMMIT:?SCHEDULER_NEWER_COMMIT is not set}"
script_dir="${SCHEDULER_SCRIPT_DIR:?SCHEDULER_SCRIPT_DIR is not set}"
util_script="${SCHEDULER_UTIL_SCRIPT:?SCHEDULER_UTIL_SCRIPT is not set}"

# 用户自定义脚本：
# 1) build 脚本：执行构建
# 2) artifact check 脚本：检查统一 artifact 目录下的产物是否存在且合法
build_step_script="${SCHEDULER_BUILD_STEP_SCRIPT:?SCHEDULER_BUILD_STEP_SCRIPT is not set}"
artifact_check_script="${SCHEDULER_ARTIFACT_CHECK_SCRIPT:?SCHEDULER_ARTIFACT_CHECK_SCRIPT is not set}"
verify_script="${SCHEDULER_VERIFY_SCRIPT:-$script_dir/user_scripts/verify_latest_build.sh}"

mkdir -p "$log_dir"

reverse_exit=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --reverse-exit)
      reverse_exit=1
      shift
      ;;
    -h|--help)
      cat <<'EOF'
Usage:
  scheduler_step.sh [--reverse-exit]

Environment:
  SCHEDULER_BUILD_STEP_SCRIPT      Optional build script path
  SCHEDULER_ARTIFACT_CHECK_SCRIPT  Optional artifact validation script path

Artifact validation script contract:
  * exit 0   : artifact exists and is valid, can be used directly
  * exit 1   : artifact missing or invalid
  * exit 125 : validation infrastructure error / cannot determine
EOF
      exit 0
      ;;
    *)
      echo "Error: unknown option: $1" >&2
      exit 125
      ;;
  esac
done

if [[ ! -f "$util_script" ]]; then
  echo "Error: util script not found: $util_script" >&2
  exit 125
fi

if [[ ! -f "$build_step_script" ]]; then
  echo "Error: build step script not found: $build_step_script" >&2
  exit 125
fi

if [[ ! -f "$artifact_check_script" ]]; then
  echo "Error: artifact check script not found: $artifact_check_script" >&2
  exit 125
fi

if [[ ! -f "$verify_script" ]]; then
  echo "Error: verify script not found: $verify_script" >&2
  exit 125
fi

finalize_exit() {
  local status=$?

  if [[ "$reverse_exit" -eq 1 ]]; then
    case "$status" in
      125) exit 125 ;;
      0)   exit 1 ;;
      *)   exit 0 ;;
    esac
  else
    exit "$status"
  fi
}

trap 'finalize_exit' EXIT

# shellcheck disable=SC1090
source "$util_script"

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

current_commit="$(git -C "$base_dir" rev-parse HEAD 2>/dev/null)" || exit 125
current_commit_short="$(git -C "$base_dir" rev-parse --short HEAD 2>/dev/null)" || exit 125
export SCHEDULER_CURRENT_COMMIT="$current_commit"
export SCHEDULER_CURRENT_COMMIT_SHORT="$current_commit_short"

log_file="$log_dir/${current_commit_short}.log"
export SCHEDULER_CURRENT_LOG_FILE="$log_file"

scheduler_ensure_commit_status "$current_commit" "$log_file"
scheduler_prepare_commit_dirs "$current_commit"

artifact_dir="$(scheduler_commit_artifact_dir "$current_commit")"
build_dir="$(scheduler_commit_build_dir "$current_commit")"
worktree_dir="$(scheduler_commit_worktree_dir "$current_commit")"

export SCHEDULER_STEP_BUILD_DIR="$build_dir"
export SCHEDULER_STEP_WORKTREE_DIR="$worktree_dir"
export SCHEDULER_STEP_ARTIFACT_DIR="$artifact_dir"

# 给用户脚本看的上下文
export SCHEDULER_VERIFY_ARTIFACT_PATH="${SCHEDULER_VERIFY_ARTIFACT_PATH:-}"
export SCHEDULER_BUILD_DIR="$build_dir"
export SCHEDULER_WORKTREE_DIR_CURRENT="$worktree_dir"

if git -C "$base_dir" rev-list --first-parent "$newer_commit" | grep -Fxq "$current_commit"; then
  head_offset="$(git -C "$base_dir" rev-list --count --first-parent "${current_commit}..${newer_commit}")"
  head_desc="${SCHEDULER_NEWER_COMMIT_SHORT:-newer}~${head_offset}"
else
  head_desc="not-on-first-parent-chain"
fi

if [[ -f "$state_file" ]]; then
  # shellcheck disable=SC1090
  source "$state_file"
else
  total_count=0
  total_elapsed=0
fi

total_count=$((total_count + 1))

start_time="$(date +%s)"
start_human="$(date '+%F %T')"
author_time="$(git -C "$base_dir" show -s --format=%ai HEAD)"
commit_time="$(git -C "$base_dir" show -s --format=%ci HEAD)"
final_status="$(scheduler_get_status_field "$current_commit" FINAL_STATUS || true)"

case "$final_status" in
  "$STATE_FINAL_GOOD")
    echo "[state] commit already finalized as GOOD, skip rerun"
    exit 0
    ;;
  bad|artifact_failed|test_failed|timeout)
    echo "[state] commit already finalized as BAD-like status ($final_status), skip rerun"
    exit 1
    ;;
  "$STATE_FINAL_SKIP")
    echo "[state] commit already finalized as SKIP, skip rerun"
    exit 125
    ;;
esac

echo "========================================"
echo "Scheduler run #: $total_count"
echo "Current commit: $current_commit_short ($current_commit)"
echo "Revision relative to newer commit: $head_desc"
echo "Commit time: $commit_time"
echo "Author time: $author_time"
echo "Start time: $start_human"
echo "Log file: $log_file"
echo "Artifact dir: $artifact_dir"
echo "Build dir: $build_dir"
echo "Artifact check script: $artifact_check_script"
echo "Build step script: $build_step_script"
echo "Verify script: $verify_script"
echo "========================================"

{
  echo "========================================"
  echo "Scheduler run #: $total_count"
  echo "Current commit: $current_commit_short ($current_commit)"
  echo "Revision relative to newer commit: $head_desc"
  echo "Commit time: $commit_time"
  echo "Author time: $author_time"
  echo "Start time: $start_human"
  echo "Log file: $log_file"
  echo "Artifact dir: $artifact_dir"
  echo "Build dir: $build_dir"
  echo "Artifact check script: $artifact_check_script"
  echo "Build step script: $build_step_script"
  echo "Verify script: $verify_script"
  echo "========================================"
} >> "$summary_log"


set +e

run_artifact_check() {
  "$artifact_check_script" >>"$log_file" 2>&1
  return $?
}
kill_build_group() {
  local pgid="$1"
  local grace_seconds="${2:-3}"

  [[ -z "$pgid" ]] && return 0

  echo "[build] sending TERM to process group $pgid" | tee -a "$log_file"
  kill -TERM -- "-$pgid" 2>/dev/null || true

  local i
  for ((i=0; i<grace_seconds; i++)); do
    if ! kill -0 "$pgid" 2>/dev/null; then
      return 0
    fi
    sleep 1
  done

  echo "[build] sending KILL to process group $pgid" | tee -a "$log_file"
  kill -KILL -- "-$pgid" 2>/dev/null || true
}
cleanup_build_on_signal() {
  local sig="${1:-EXIT}"

  echo
  echo "[build] caught signal: $sig" | tee -a "$log_file"
  
  if [[ -n "${build_pid:-}" ]]; then
    kill_build_group "$build_pid" 3
  fi
}

#SCHEDULER_BUILD_TIMEOUT_SECONDS 需要在外部被设置
run_build_once() {
  local build_mode="$1"   # incremental | clean

  local build_start_ts build_start_human build_end_ts build_end_human
  local build_pid raw_line new_line cols max_len
  local build_timeout_seconds elapsed_since_start timed_out

  build_start_ts="$(date +%s)"
  build_start_human="$(date '+%F %T')"
  build_timeout_seconds="${SCHEDULER_BUILD_TIMEOUT_SECONDS:-1000}"
  timed_out=0

  echo "[build] mode: $build_mode"
  echo "[build] start: $build_start_human"
  echo "[build] timeout: ${build_timeout_seconds}s"

  # shellcheck disable=SC1090
  source "$script_dir/utils/env_utils.sh"

  remove_env PATH "$build_dir/bin"
  prepend_env PATH "$build_dir/bin"

  export SCHEDULER_BUILD_MODE="$build_mode"
  setsid "$build_step_script" >>"$log_file" 2>&1 &
  build_pid=$!
  #防止ctrl+c退出时还在构建，导致删除目录后会继续生成脏的build数据，从而增量构建必定失败
  trap 'cleanup_build_on_signal INT; exit 130' INT
  trap 'cleanup_build_on_signal TERM; exit 143' TERM

  last_line="[build] starting..."
  printf '%s' "$last_line"

  while kill -0 "$build_pid" 2>/dev/null; do
    cols="$(tput cols 2>/dev/null || echo 120)"
    max_len=$((cols - 1))

    raw_line="$(tail -n 2 "$log_file" 2>/dev/null | head -n 1 | tr '\r\n' ' ')"

    new_line="$(
      printf '%s\n' "$raw_line" | sed -nE '
        s/^.*(\[[0-9]+\/[0-9]+\][[:space:]].+)$/[build] \1/p
        t
        s/^-- Configuring done(.*)$/[cmake] Configuring done\1/p
        t
        s/^-- Generating done(.*)$/[cmake] Generating done\1/p
        t
        s#^-- Build files have been written to:[[:space:]]*(.*)$#[cmake] Build files written: \1#p
      '
    )"

    if [[ -n "$new_line" && "$new_line" != "$last_line" ]]; then
      if (( ${#new_line} > max_len )); then
        new_line="${new_line:0:max_len-3}..."
      fi

      if [[ "$new_line" == \[cmake\]* ]]; then
        printf '\r\033[K%s\n' "$new_line"
        last_line="$new_line"
      else
        printf '\r\033[K%s' "$new_line"
        last_line="$new_line"
      fi
    fi

    elapsed_since_start=$(( $(date +%s) - build_start_ts ))
    if (( elapsed_since_start >= build_timeout_seconds )); then
      timed_out=1
      echo
      echo "[build] timeout reached after ${elapsed_since_start}s, terminating build pid=$build_pid" | tee -a "$log_file"

      kill_build_group "$build_pid"

      break
    fi

    sleep 0.2
  done

  printf '\r\033[K%s\n' "$last_line"

  if [[ "$timed_out" -eq 1 ]]; then
    wait "$build_pid" 2>/dev/null || true
    build_status=124
  else
    wait "$build_pid"
    build_status=$?
  fi

  build_end_ts="$(date +%s)"
  build_end_human="$(date '+%F %T')"
  build_elapsed=$((build_end_ts - build_start_ts))

  echo "[build] end: $build_end_human"
  echo "[build] elapsed: ${build_elapsed}s"

  return "$build_status"
}

STATE_PREV_BUILD_STATE="$STATE_BUILD_NOT_STARTED"
STATE_PREV_BUILD_FAILURE_REASON="none"
STATE_PREV_ARTIFACT_FAILURE_REASON="none"
STATE_PREV_BUILD_ATTEMPT_COUNT=0
STATE_PREV_BUILD_TYPE="$STATE_BUILD_TYPE_INCREMENTAL"

load_build_state_snapshot() {
  local commit="$1"
  local raw_attempt_count

  STATE_PREV_BUILD_STATE="$(scheduler_get_status_field "$commit" BUILD_STATE || true)"
  STATE_PREV_BUILD_FAILURE_REASON="$(scheduler_get_status_field "$commit" BUILD_FAILURE_REASON || true)"
  STATE_PREV_ARTIFACT_FAILURE_REASON="$(scheduler_get_status_field "$commit" ARTIFACT_FAILURE_REASON || true)"
  raw_attempt_count="$(scheduler_get_status_field "$commit" BUILD_ATTEMPT_COUNT || true)"
  STATE_PREV_BUILD_TYPE="$(scheduler_get_status_field "$commit" BUILD_TYPE || true)"

  [[ -z "$STATE_PREV_BUILD_STATE" ]] && STATE_PREV_BUILD_STATE="$STATE_BUILD_NOT_STARTED"
  [[ -z "$STATE_PREV_BUILD_FAILURE_REASON" ]] && STATE_PREV_BUILD_FAILURE_REASON="none"
  [[ -z "$STATE_PREV_ARTIFACT_FAILURE_REASON" ]] && STATE_PREV_ARTIFACT_FAILURE_REASON="none"
  [[ -z "$STATE_PREV_BUILD_TYPE" ]] && STATE_PREV_BUILD_TYPE="$STATE_BUILD_TYPE_INCREMENTAL"

  if [[ "$raw_attempt_count" =~ ^[0-9]+$ ]]; then
    STATE_PREV_BUILD_ATTEMPT_COUNT="$raw_attempt_count"
  else
    STATE_PREV_BUILD_ATTEMPT_COUNT=0
  fi
}

# 统一管理构建重试策略，避免主流程里出现过多嵌套 if。
# 输出格式（按行）：
#   1) build_type               => incremental | clean
#   2) start_new_build          => true | false
#   3) continuing_previous      => true | false
#   4) fallback_reason          => 文本原因
#   5) stop_build_loop          => true | false（是否达到最大重试次数）
determine_build_plan() {
  local max_try="$1"
  local build_dir_path="$2"
  local build_attempt_count="$3"
  local always_clean_build="$4"

  local build_type="$STATE_BUILD_TYPE_INCREMENTAL"
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

  if [[ "$STATE_PREV_BUILD_STATE" == "$STATE_BUILD_NOT_STARTED" || "$always_clean_build" == "true" ]]; then
    build_type="$STATE_BUILD_TYPE_CLEAN"
    echo "$build_type"
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

  # 处于 building 状态时，默认继续同一次构建（不新增 attempt）。
  if [[ "$STATE_PREV_BUILD_STATE" == "$STATE_BUILD_BUILDING" ]]; then
    start_new_build="false"
    continuing_previous_build="true"
    fallback_reason="resume_from_building_state"
  fi

  # 增量构建失败后，下一轮降级为 clean。
  if [[ "$STATE_PREV_BUILD_STATE" == "$STATE_BUILD_FAILED" && "$STATE_PREV_BUILD_TYPE" == "$STATE_BUILD_TYPE_INCREMENTAL" ]]; then
    build_type="$STATE_BUILD_TYPE_CLEAN"
    fallback_reason="incremental_build_failed"
  # 构建成功但产物校验失败，也强制 clean。
  elif [[ "$STATE_PREV_BUILD_STATE" == "$STATE_BUILD_SUCCEEDED" ]] &&
       [[ "$STATE_PREV_ARTIFACT_FAILURE_REASON" == "$STATE_ARTIFACT_CHECK_ERROR" ||
          "$STATE_PREV_ARTIFACT_FAILURE_REASON" == "$STATE_ARTIFACT_INVALID" ]]; then
    build_type="$STATE_BUILD_TYPE_CLEAN"
    fallback_reason="${STATE_PREV_ARTIFACT_FAILURE_REASON}"
  elif [[ "$need_clean_build" -eq 1 ]]; then
    build_type="$STATE_BUILD_TYPE_CLEAN"
    fallback_reason="build_dir_is_empty_or_not_exist"
  fi

  # timeout/interrupted 时优先“续跑”，已经续跑过一次则开新 attempt。
  if [[ "$STATE_PREV_BUILD_STATE" == "$STATE_BUILD_TIMEOUT" || "$STATE_PREV_BUILD_STATE" == "$STATE_BUILD_INTERRUPTED" ]]; then
    build_type="$STATE_BUILD_TYPE_INCREMENTAL"
    if [[ "$STATE_PREV_BUILD_FAILURE_REASON" == *_continued ]]; then
      start_new_build="true"
      continuing_previous_build="false"
      fallback_reason="${STATE_PREV_BUILD_TYPE}_build_${STATE_PREV_BUILD_STATE}_retry_new_attempt"
    else
      start_new_build="false"
      continuing_previous_build="true"
      fallback_reason="${STATE_PREV_BUILD_TYPE}_build_${STATE_PREV_BUILD_STATE}_continue_previous_attempt"
    fi
  fi

  echo "$build_type"
  echo "$start_new_build"
  echo "$continuing_previous_build"
  echo "$fallback_reason"
  echo "$stop_build_loop"
}

# 处理一次构建后的状态落盘。
# 返回值语义：
#   0 => 可结束当前 commit 的构建流程（成功或 clean 失败已定论）
#   1 => 需要继续下一轮重试
handle_build_outcome() {
  local commit="$1"
  local build_type="$2"
  local continuing_previous_build="$3"
  local build_status="$4"
  local artifact_check_status="$5"

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

artifact_check_status=1
build_status=0
verify_status=125
verify_elapsed=-1
build_elapsed=0
final_attempt="none"
did_build=0

#需要变成全局变量
max_try_times=5
# 第一次先直接检查统一 artifact 目录里有没有合法产物
scheduler_mark_running "$current_commit"
run_artifact_check
artifact_check_status=$?

if [[ "$artifact_check_status" -eq 0 ]]; then
  scheduler_mark_artifact_ready "$current_commit" "$artifact_dir" "download"
  echo "[artifact] valid artifact already exists, skip build"
  final_attempt="reuse-artifact"
else
  did_build=1

  final_attempt="none"
  always_clean_build="false"
  # 构建循环：读取上一次状态 -> 决策本次策略 -> 执行构建 -> 按结果落盘。
  while true; do
    load_build_state_snapshot "$current_commit"
    build_attempt_count="$STATE_PREV_BUILD_ATTEMPT_COUNT"

    mapfile -t plan < <(
      determine_build_plan \
        "$max_try_times" \
        "$build_dir" \
        "$build_attempt_count" \
        "$always_clean_build"
    )
    build_type="${plan[0]}"
    start_new_build="${plan[1]}"
    continuing_previous_build="${plan[2]}"
    BUILD_FALLBACK_REASON="${plan[3]}"
    stop_build_loop="${plan[4]}"

    if [[ "$stop_build_loop" == "true" ]]; then
      echo "reach max tries:$build_attempt_count>=$max_try_times"
      scheduler_mark_build_final_failed "$current_commit" "$STATE_REASON_BUILD_REACH_MAX_TRIES"
      build_status=111
      break
    fi
    echo "build_attempt_count:$build_attempt_count (can try)"
    echo "BUILD_FALLBACK_REASON: $BUILD_FALLBACK_REASON"
    echo "START_NEW_BUILD: $start_new_build"
    final_attempt="$build_type"
    scheduler_mark_build_attempt_start "$current_commit" "$build_type" "$start_new_build"
    scheduler_mark_building "$current_commit" "$build_type"
    
    run_build_once "$build_type"
    build_status=$?

    if [[ "$build_status" -eq 0 ]]; then
      run_artifact_check
      artifact_check_status=$?
    else
      artifact_check_status=1
    fi

    if handle_build_outcome \
      "$current_commit" \
      "$build_type" \
      "$continuing_previous_build" \
      "$build_status" \
      "$artifact_check_status"; then
      break
    fi

    #防止未知错误导致一直快速循环，卡死，无法使用ctrl+c结束
    sleep 1
    
  done

fi

if [[ "$artifact_check_status" -eq 0 ]]; then
  verify_start_ts="$(date +%s)"
  verify_start_human="$(date '+%F %T')"
  echo "[verify] start: $verify_start_human"
  echo "[verify] using latest build artifacts under: $build_dir"

  "$verify_script" >>"$log_file" 2>&1
  verify_status=$?

  verify_end_ts="$(date +%s)"
  verify_end_human="$(date '+%F %T')"
  verify_elapsed=$((verify_end_ts - verify_start_ts))
  echo "[verify] end: $verify_end_human"
  echo "[verify] elapsed: ${verify_elapsed}s"

  if [[ "$verify_status" -eq 0 ]]; then
    echo "[verify] success"
  else
    echo "[verify] failed"
  fi
fi

end_time="$(date +%s)"
end_human="$(date '+%F %T')"
elapsed=$((end_time - start_time))
total_elapsed=$((total_elapsed + elapsed))

cat > "$state_file" <<EOF
total_count=$total_count
total_elapsed=$total_elapsed
EOF

echo "----------------------------------------"
echo "Scheduler run #: $total_count"
echo "Current commit: $current_commit_short ($current_commit)"
echo "Final attempt: $final_attempt"
echo "End time: $end_human"
echo "Build elapsed: ${build_elapsed}s"
echo "Verify elapsed: ${verify_elapsed}s"
echo "Artifact check exit code: $artifact_check_status"
if [[ "$did_build" -eq 1 ]]; then
  echo "Build exit code: $build_status"
fi
if [[ "$artifact_check_status" -eq 0 ]]; then
  echo "Verify exit code: $verify_status"
fi
echo "Elapsed this run: ${elapsed}s"
echo "Accumulated elapsed: ${total_elapsed}s"

{
  echo "End time: $end_human"
  echo "Final attempt: $final_attempt"
  echo "Build elapsed: ${build_elapsed}s"
  echo "Verify elapsed: ${verify_elapsed}s"
  echo "Artifact check exit code: $artifact_check_status"
  if [[ "$did_build" -eq 1 ]]; then
    echo "Build exit code: $build_status"
  fi
  if [[ "$artifact_check_status" -eq 0 ]]; then
    echo "Verify exit code: $verify_status"
  fi
  echo "Elapsed this run: ${elapsed}s"
  echo "Accumulated elapsed: ${total_elapsed}s"
} >> "$summary_log"

if [[ "$artifact_check_status" -eq 0 && "$verify_status" -eq 0 ]]; then
  scheduler_mark_testing_ready "$current_commit"
  scheduler_mark_good "$current_commit"

  echo "Result: GOOD"
  echo "----------------------------------------"
  {
    echo "Result: GOOD"
    echo "----------------------------------------"
    echo
  } >> "$summary_log"
  exit 0
fi

if [[ "$artifact_check_status" -ne 0 ]]; then
  artifact_state="$(scheduler_get_status_field "$current_commit" ARTIFACT_STATE || true)"
  if [[ "$artifact_state" != "failed" ]]; then
    artifact_failure_reason="$(scheduler_get_status_field "$current_commit" ARTIFACT_FAILURE_REASON || true)"
    if [[ -z "$artifact_failure_reason" || "$artifact_failure_reason" == "none" ]]; then
      if [[ "$artifact_check_status" -eq 125 ]]; then
        artifact_failure_reason="artifact_check_error"
      else
        artifact_failure_reason="artifact_invalid"
      fi
    fi
    scheduler_mark_artifact_failed "$current_commit" "$artifact_failure_reason"
  fi
  echo "Result: BAD (artifact unavailable or invalid)"
  echo "Last 50 lines of log:"
  tail -n 50 "$log_file"
  {
    echo "Result: BAD (artifact unavailable or invalid)"
    echo "----------------------------------------"
    echo
  } >> "$summary_log"
  exit 1
fi

scheduler_mark_test_failed "$current_commit"
echo "Result: BAD (verify failed)"
echo "Last 50 lines of log:"
tail -n 50 "$log_file"
{
  echo "Result: BAD (verify failed)"
  echo "----------------------------------------"
  echo
} >> "$summary_log"
exit 1
