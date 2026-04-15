#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./run_scheduler.sh [options] -- [scheduler options]

Options:
  -s, --scheduler       Scheduler name, default: bisect
                        Supported: bisect, linear
  -d, --base-dir        Repository base directory, default: current directory

  -n, --newer-commit    Newer commit, default: HEAD
      --newer-time      Resolve newer commit from the last commit before the given time

  -o, --older-commit    Older commit
      --older-time      Resolve older commit from the last commit before the given time

      --first-parent-only
                        Resolve time-based commits only from HEAD's first-parent chain

      --artifact-dir    Artifact root directory,
                        default: <base_dir>/scheduler-artifacts/<scheduler>
      --log-dir         Log directory, default: <artifact_dir>/logs
      --step-script     Step script path, default: <base_dir>/scheduler_step.sh
  -h, --help            Show this help

Notes:
  * --older-commit and --older-time are mutually exclusive
  * --newer-commit and --newer-time are mutually exclusive
  * One of --older-commit or --older-time is required
  * If --newer-commit and --newer-time are both omitted, newer commit defaults to HEAD
  * By default, time-based resolution searches all commits reachable from HEAD
  * --first-parent-only restricts time-based resolution to HEAD's first-parent chain
  * Time values accept common date/time expressions understood by Git, for example:
      "2026-03-24"
      "2026-03-24 18:15"
      "2026-03-24 18:15:27 +0800"
      "2 days ago"
      "yesterday"
      "now"
  * Time-based options are resolved first, then normalized with git rev-parse
  * Arguments after '--' are passed through to the selected scheduler

Examples:
  ./run_scheduler.sh --scheduler bisect -o HEAD~100
  ./run_scheduler.sh -s bisect -d /path/to/repo -n HEAD -o abc1234
  ./run_scheduler.sh -s bisect --older-time "2026-03-24"
  ./run_scheduler.sh -s bisect --older-time "2026-03-24 18:15"
  ./run_scheduler.sh -s bisect --older-time "2 days ago"
  ./run_scheduler.sh -s bisect --older-time "2026-03-24" --newer-time "2026-03-26"
  ./run_scheduler.sh -s bisect -o abc1234 --newer-time "yesterday"
  ./run_scheduler.sh -s bisect --first-parent-only --older-time "2026-03-24" --newer-time "now"

  ./run_scheduler.sh -s linear -o OLD -n NEW -- --direction backward --target first-good
  ./run_scheduler.sh -s linear -o OLD -n NEW -- --history-mode topo --target all
  ./run_scheduler.sh \
    -s linear \
    -o OLD \
    -n NEW \
    --artifact-check-script /path/to/check_artifact.sh \
    --build-step-script /path/to/build.sh
EOF
}

scheduler="bisect"
base_dir="$(pwd)"
newer_commit="HEAD"
older_commit=""
older_time=""
newer_time=""
artifact_dir=""
log_dir=""
step_script=""
scheduler_args=()
first_parent_only=0
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
util_script="$script_dir/utils/util.sh"
build_step_script="$script_dir/user_scripts/build_step.sh"
artifact_check_script="$script_dir/user_scripts/artifact_check.sh"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -s|--scheduler)
      scheduler="$2"
      shift 2
      ;;
    -d|--base-dir)
      base_dir="$2"
      shift 2
      ;;
    -n|--newer-commit)
      newer_commit="$2"
      shift 2
      ;;
    -o|--older-commit)
      older_commit="$2"
      shift 2
      ;;
    --older-time)
      older_time="$2"
      shift 2
      ;;
    --newer-time)
      newer_time="$2"
      shift 2
      ;;
    --first-parent-only)
      first_parent_only=1
      shift
      ;;
    --artifact-dir)
      artifact_dir="$2"
      shift 2
      ;;
    --log-dir)
      log_dir="$2"
      shift 2
      ;;
    --step-script)
      step_script="$2"
      shift 2
      ;;
    --build-step-script)
      build_step_script="$2"
      shift 2
      ;;
    --artifact-check-script)
      artifact_check_script="$2"
      shift 2
      ;;
    --)
      shift
      scheduler_args=("$@")
      break
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ ! -d "$base_dir/.git" ]]; then
  echo "Error: base_dir is not a git repository: $base_dir" >&2
  exit 1
fi

if ! command -v ccache >/dev/null 2>&1; then
  echo "[WARNING] ccache could not be found; incremental/repeated builds may be significantly slower" >&2
fi

if [[ -z "$artifact_dir" ]]; then
  artifact_dir="$base_dir/scheduler-artifacts/$scheduler"
fi

if [[ -z "$log_dir" ]]; then
  log_dir="$artifact_dir/logs"
fi

if [[ -z "$step_script" ]]; then
  step_script="$script_dir/scheduler_step.sh"
fi

if [[ ! -f "$step_script" ]]; then
  echo "Error: step script not found: $step_script" >&2
  exit 1
fi

if [[ ! -f "$util_script" ]]; then
  echo "Error: util script not found: $util_script" >&2
  exit 1
fi

scheduler_script="$script_dir/schedulers/${scheduler}.sh"
if [[ ! -f "$scheduler_script" ]]; then
  echo "Error: scheduler script not found: $scheduler_script" >&2
  exit 1
fi

status_dir="$artifact_dir/status"
commit_status_dir="$status_dir/commits"
worktree_dir="$artifact_dir/worktrees"
build_root_dir="$artifact_dir/builds"
artifact_root_dir="$artifact_dir/artifacts"

mkdir -p \
  "$artifact_dir" \
  "$log_dir" \
  "$status_dir" \
  "$commit_status_dir" \
  "$worktree_dir" \
  "$build_root_dir" \
  "$artifact_root_dir"

state_file="$log_dir/state.txt"
summary_log="$log_dir/summary.log"
scheduler_log="$log_dir/scheduler.log"

rm -f "$state_file" "$summary_log" "$scheduler_log"

resolve_commit_by_time() {
  local ref_time="$1"

  if [[ "$first_parent_only" -eq 1 ]]; then
    git -C "$base_dir" rev-list -1 --first-parent --before="$ref_time" HEAD
  else
    git -C "$base_dir" rev-list -1 --before="$ref_time" HEAD
  fi
}

if [[ -n "$older_time" ]]; then
  if [[ -n "$older_commit" ]]; then
    echo "Error: --older-commit and --older-time are mutually exclusive" >&2
    exit 1
  fi
  older_commit="$(resolve_commit_by_time "$older_time")"
  if [[ -z "$older_commit" ]]; then
    echo "Error: no commit found before older time: $older_time" >&2
    exit 1
  fi
fi

if [[ -z "$older_commit" ]]; then
  echo "Error: one of --older-commit or --older-time is required" >&2
  exit 1
fi

if [[ -n "$newer_time" ]]; then
  if [[ "$newer_commit" != "HEAD" ]]; then
    echo "Error: --newer-commit and --newer-time are mutually exclusive" >&2
    exit 1
  fi
  newer_commit="$(resolve_commit_by_time "$newer_time")"
  if [[ -z "$newer_commit" ]]; then
    echo "Error: no commit found before newer time: $newer_time" >&2
    exit 1
  fi
fi

older_commit_full="$(git -C "$base_dir" rev-parse "$older_commit")"
newer_commit_full="$(git -C "$base_dir" rev-parse "$newer_commit")"

if ! git -C "$base_dir" merge-base --is-ancestor "$older_commit_full" "$newer_commit_full"; then
  echo "Error: older commit is not an ancestor of newer commit" >&2
  exit 1
fi

older_commit_short="$(git -C "$base_dir" rev-parse --short "$older_commit_full")"
newer_commit_short="$(git -C "$base_dir" rev-parse --short "$newer_commit_full")"

export SCHEDULER_NAME="$scheduler"
export SCHEDULER_BASE_DIR="$base_dir"
export SCHEDULER_SCRIPT_DIR="$script_dir"
export SCHEDULER_UTIL_SCRIPT="$util_script"

export SCHEDULER_ARTIFACT_DIR="$artifact_dir"
export SCHEDULER_LOG_DIR="$log_dir"
export SCHEDULER_STATE_DIR="$status_dir"
export SCHEDULER_COMMIT_STATUS_DIR="$commit_status_dir"
export SCHEDULER_WORKTREE_DIR="$worktree_dir"
export SCHEDULER_BUILD_ROOT_DIR="$build_root_dir"
export SCHEDULER_ARTIFACT_ROOT_DIR="$artifact_root_dir"

export SCHEDULER_STATE_FILE="$state_file"
export SCHEDULER_SUMMARY_LOG="$summary_log"
export SCHEDULER_DRIVER_LOG="$scheduler_log"
export SCHEDULER_STEP_SCRIPT="$step_script"
export SCHEDULER_ARTIFACT_CHECK_SCRIPT="$artifact_check_script"
export SCHEDULER_BUILD_STEP_SCRIPT="$build_step_script"
export SCHEDULER_NEWER_COMMIT="$newer_commit_full"
export SCHEDULER_OLDER_COMMIT="$older_commit_full"
export SCHEDULER_NEWER_COMMIT_SHORT="$newer_commit_short"
export SCHEDULER_OLDER_COMMIT_SHORT="$older_commit_short"
export SCHEDULER_NEWER_COMMIT_INPUT="$newer_commit"
export SCHEDULER_OLDER_COMMIT_INPUT="$older_commit"

start_wall=$(date +%s)
start_human=$(date '+%F %T')

echo "========================================"
echo "Scheduler start: $start_human"
echo "Scheduler: $scheduler"
echo "Base dir: $base_dir"
echo "Artifact dir: $artifact_dir"
echo "Log dir: $log_dir"
echo "Status dir: $status_dir"
echo "Commit status dir: $commit_status_dir"
echo "Worktree dir: $worktree_dir"
echo "Build root dir: $build_root_dir"
echo "Artifact root dir: $artifact_root_dir"
echo "Step script: $step_script"
echo "Newer commit: $newer_commit ($newer_commit_full)"
echo "Older commit: $older_commit ($older_commit_full)"
if [[ "${#scheduler_args[@]}" -gt 0 ]]; then
  echo "Scheduler args: ${scheduler_args[*]}"
fi
echo "========================================"

{
  echo "========================================"
  echo "Scheduler start: $start_human"
  echo "Scheduler: $scheduler"
  echo "Base dir: $base_dir"
  echo "Artifact dir: $artifact_dir"
  echo "Log dir: $log_dir"
  echo "Status dir: $status_dir"
  echo "Commit status dir: $commit_status_dir"
  echo "Worktree dir: $worktree_dir"
  echo "Build root dir: $build_root_dir"
  echo "Artifact root dir: $artifact_root_dir"
  echo "Step script: $step_script"
  echo "Newer commit: $newer_commit ($newer_commit_full)"
  echo "Older commit: $older_commit ($older_commit_full)"
  if [[ "${#scheduler_args[@]}" -gt 0 ]]; then
    echo "Scheduler args: ${scheduler_args[*]}"
  fi
  echo "========================================"
} >> "$scheduler_log"

set +e
"$scheduler_script" "${scheduler_args[@]}"
scheduler_status=$?
set -e

end_wall=$(date +%s)
end_human=$(date '+%F %T')
total_wall=$((end_wall - start_wall))

echo "========================================"
echo "Scheduler end: $end_human"
echo "Scheduler: $scheduler"
echo "Total wall time: ${total_wall}s"
if [[ -f "$state_file" ]]; then
  # shellcheck disable=SC1090
  source "$state_file"
  echo "Total step runs: ${total_count:-0}"
  echo "Total step time: ${total_elapsed:-0}s"
fi
echo "Summary log: $summary_log"
echo "Driver log: $scheduler_log"
echo "========================================"

{
  echo "========================================"
  echo "Scheduler end: $end_human"
  echo "Scheduler: $scheduler"
  echo "Total wall time: ${total_wall}s"
  if [[ -f "$state_file" ]]; then
    # shellcheck disable=SC1090
    source "$state_file"
    echo "Total step runs: ${total_count:-0}"
    echo "Total step time: ${total_elapsed:-0}s"
  fi
  echo "Summary log: $summary_log"
  echo "Driver log: $scheduler_log"
  echo "========================================"
} >> "$scheduler_log"

exit "$scheduler_status"