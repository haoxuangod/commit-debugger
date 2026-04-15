#!/usr/bin/env bash
set -euo pipefail

bisect_mode="find_first_bad"
use_first_parent=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --find-first-bad)
      bisect_mode="find_first_bad"
      shift
      ;;
    --find-first-good)
      bisect_mode="find_first_good"
      shift
      ;;
    --first-parent)
      use_first_parent=1
      shift
      ;;
    -h|--help)
      cat <<'EOF'
Usage:
  bisect_scheduler.sh [--find-first-bad | --find-first-good] [--first-parent]

Modes:
  --find-first-bad   Pattern 0001111 left new right old
                     older commit = good, newer commit = bad
  --find-first-good  Pattern 1110000 left new right old
                     older commit = old/ broken, newer commit = new/fixed

Options:
  --first-parent     Restrict bisect to first-parent history only
EOF
      exit 0
      ;;
    *)
      echo "Error: unknown option: $1" >&2
      exit 1
      ;;
  esac
done

base_dir="${SCHEDULER_BASE_DIR:?SCHEDULER_BASE_DIR is not set}"
log_dir="${SCHEDULER_LOG_DIR:?SCHEDULER_LOG_DIR is not set}"
driver_log="${SCHEDULER_DRIVER_LOG:?SCHEDULER_DRIVER_LOG is not set}"
step_script="${SCHEDULER_STEP_SCRIPT:?SCHEDULER_STEP_SCRIPT is not set}"

newer_commit="${SCHEDULER_NEWER_COMMIT:?SCHEDULER_NEWER_COMMIT is not set}"
older_commit="${SCHEDULER_OLDER_COMMIT:?SCHEDULER_OLDER_COMMIT is not set}"

cleanup() {
  git -C "$base_dir" bisect reset >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "[bisect] start" | tee -a "$driver_log"
echo "[bisect] mode: $bisect_mode" | tee -a "$driver_log"
echo "[bisect] first-parent: $use_first_parent" | tee -a "$driver_log"
echo "[bisect] older commit: $older_commit" | tee -a "$driver_log"
echo "[bisect] newer commit: $newer_commit" | tee -a "$driver_log"

bisect_start_args=()
if [[ "$use_first_parent" -eq 1 ]]; then
  bisect_start_args+=(--first-parent)
fi

case "$bisect_mode" in
  find_first_bad)
    git -C "$base_dir" bisect start "${bisect_start_args[@]}"
    git -C "$base_dir" bisect bad "$newer_commit"
    git -C "$base_dir" bisect good "$older_commit"
    ;;
  find_first_good)
    git -C "$base_dir" bisect start "${bisect_start_args[@]}" --term-old broken --term-new fixed
    git -C "$base_dir" bisect broken "$older_commit"
    git -C "$base_dir" bisect fixed "$newer_commit"
    ;;
esac

set +e
case "$bisect_mode" in
  find_first_bad)
    git -C "$base_dir" bisect run "$step_script"
    bisect_status=$?
    ;;
  find_first_good)
    git -C "$base_dir" bisect run "$step_script" --reverse-exit
    bisect_status=$?
    ;;
  *)
    echo "Error: unsupported mode: $bisect_mode" | tee -a "$driver_log" >&2
    bisect_status=1
    ;;
esac
set -e

echo "[bisect] end, status=$bisect_status" | tee -a "$driver_log"
exit "$bisect_status"