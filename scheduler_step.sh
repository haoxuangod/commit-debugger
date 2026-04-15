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
  good)
    echo "[state] commit already finalized as GOOD, skip rerun"
    exit 0
    ;;
  bad|artifact_failed|test_failed|timeout)
    echo "[state] commit already finalized as BAD-like status ($final_status), skip rerun"
    exit 1
    ;;
  skip)
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
  while true; do
    previous_build_state="$(scheduler_get_status_field "$current_commit" BUILD_STATE || true)"
    previous_build_failure_reason="$(scheduler_get_status_field "$current_commit" BUILD_FAILURE_REASON || true)"
    previous_artifact_failure_reason="$(scheduler_get_status_field "$current_commit" ARTIFACT_FAILURE_REASON || true)"
    build_attempt_count="$(scheduler_get_status_field "$current_commit" BUILD_ATTEMPT_COUNT || true)"
    previous_build_type="$(scheduler_get_status_field "$current_commit" BUILD_TYPE || "incremental")"
    build_type="incremental"
    if (( build_attempt_count < max_try_times )); then
      echo "build_attempt_count:$build_attempt_count (can try)"
    else
      echo "reach max tries:$build_attempt_count>=$max_try_times"
      scheduler_mark_build_final_failed "$current_commit" "build_reach_max_tries"
      build_status=111
      break
    fi

    start_new_build="true"
    continuing_previous_build="false"
    BUILD_FALLBACK_REASON="none"
    if [[ "$previous_build_state" == "not_started" || "$always_clean_build" == "true" ]]; then
      build_type="clean"
    else
      # build_dir 不存在或者为空目录 或者是第一次build-> 必须 clean
      need_clean_build=0
      if [[ ! -d "$build_dir" ]] || [[ -z "$(ls -A "$build_dir" 2>/dev/null)" || ((build_attempt_count == 0)) ]]; then
        need_clean_build=1
      fi

      if [[ "$previous_build_state" == "building" ]]; then
        build_type="incremental"
        start_new_build="false"
        continuing_previous_build="true"
        BUILD_FALLBACK_REASON="resume_from_building_state"
      fi

      if [[ "$previous_build_state" == "failed" && "$previous_build_type" == "incremental" ]]; then
        build_type="clean"
        BUILD_FALLBACK_REASON="incremental_build_failed"
      elif [[ "$previous_build_state" == "succeeded" ]] &&
           [[ "$previous_artifact_failure_reason" == "artifact_check_error" ||
              "$previous_artifact_failure_reason" == "artifact_invalid" ]]; then
          build_type="clean"
          BUILD_FALLBACK_REASON="${previous_artifact_failure_reason}"
      elif [[ "$need_clean_build" -eq 1 ]]; then
        build_type="clean"
        BUILD_FALLBACK_REASON="build_dir_is_empty_or_not_exist"
      fi

      if [[ "$previous_build_state" == "timeout" || "$previous_build_state" == "interrupted" ]]; then
        build_type="incremental"
        if [[ "$previous_build_failure_reason" == *_continued ]]; then
          start_new_build="true"
          continuing_previous_build="false"
          BUILD_FALLBACK_REASON="${previous_build_type}_build_${previous_build_state}_retry_new_attempt"
        else
          start_new_build="false"
          continuing_previous_build="true"
          BUILD_FALLBACK_REASON="${previous_build_type}_build_${previous_build_state}_continue_previous_attempt"
        fi
      fi
    fi
  
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

    if [[ "$build_status" -eq 0 ]]; then
      scheduler_mark_build_succeeded "$current_commit"
      if [[ "$artifact_check_status" -eq 0 ]]; then
        scheduler_mark_artifact_ready "$current_commit" "$artifact_dir" "build"
      elif [[ "$artifact_check_status" -eq 125 ]]; then
        if [[ "$build_type" == "clean" ]]; then
          scheduler_mark_artifact_failed "$current_commit" "artifact_check_error"
        else
          scheduler_mark_artifact_failure_reason "$current_commit" "artifact_check_error"
          continue
        fi
      else
        if [[ "$build_type" == "clean" ]]; then
          scheduler_mark_artifact_failed "$current_commit" "artifact_invalid"
        else
          scheduler_mark_artifact_failure_reason "$current_commit" "artifact_invalid"
          continue
        fi
      fi
      break
    fi

    if [[ "$build_status" -eq 124 ]]; then
      failure_reason="${build_type}_build_timeout"
      if [[ "$continuing_previous_build" == "true" ]]; then
        failure_reason="${failure_reason}_continued"
      fi
      echo $failure_reason
      scheduler_mark_build_timeout "$current_commit" $failure_reason
    elif [[ "$build_status" -eq 130 || "$build_status" -eq 143 ]]; then
      failure_reason="${build_type}_build_interrupted"
      if [[ "$continuing_previous_build" == "true" ]]; then
        failure_reason="${failure_reason}_continued"
      fi
      echo $failure_reason
      scheduler_mark_build_interrupted "$current_commit" $failure_reason
    elif [[ "$build_status" -ne 0 ]]; then
      failure_reason="${build_type}_build_failed"
      echo $failure_reason
      scheduler_mark_build_failed "$current_commit" $failure_reason
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
