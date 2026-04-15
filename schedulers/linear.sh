#!/usr/bin/env bash
set -euo pipefail

base_dir="${SCHEDULER_BASE_DIR:?SCHEDULER_BASE_DIR is not set}"
driver_log="${SCHEDULER_DRIVER_LOG:?SCHEDULER_DRIVER_LOG is not set}"
step_script="${SCHEDULER_STEP_SCRIPT:?SCHEDULER_STEP_SCRIPT is not set}"
newer_commit="${SCHEDULER_NEWER_COMMIT:?SCHEDULER_NEWER_COMMIT is not set}"
older_commit="${SCHEDULER_OLDER_COMMIT:-}"

direction="forward"
history_mode="first-parent"
target="first-bad"

usage() {
  cat <<'EOF'
Usage:
  linear.sh [options]

Options:
  --direction <forward|backward>
      forward : scan from older commit to newer commit
      backward: scan from newer commit to older commit
      Default: forward

  --history-mode <first-parent|topo|full>
      first-parent : only traverse the first-parent chain
      topo         : traverse full history in topological order
      full         : traverse full history in default rev-list order
      Default: first-parent

  --target <first-good|first-bad|all>
      first-good : return the first commit whose step result is GOOD
      first-bad  : return the first commit whose step result is BAD
      all        : scan the full range and report all GOOD/BAD/SKIP results
      Default: first-bad

  -h, --help
      Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --direction)
      direction="$2"
      shift 2
      ;;
    --history-mode)
      history_mode="$2"
      shift 2
      ;;
    --target)
      target="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown linear scheduler option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "$older_commit" ]]; then
  echo "Error: linear scheduler requires SCHEDULER_OLDER_COMMIT" >&2
  exit 1
fi

case "$direction" in
  forward|backward)
    ;;
  *)
    echo "Error: --direction must be 'forward' or 'backward'" >&2
    exit 1
    ;;
esac

case "$history_mode" in
  first-parent|topo|full)
    ;;
  *)
    echo "Error: --history-mode must be 'first-parent', 'topo', or 'full'" >&2
    exit 1
    ;;
esac

case "$target" in
  first-good|first-bad|all)
    ;;
  *)
    echo "Error: --target must be 'first-good', 'first-bad', or 'all'" >&2
    exit 1
    ;;
esac

original_commit="$(git -C "$base_dir" rev-parse HEAD)"
original_branch="$(git -C "$base_dir" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"

restore_original_state() {
  echo "[linear] restoring original repository state" | tee -a "$driver_log"

  if [[ -n "$original_branch" ]]; then
    git -C "$base_dir" checkout -f "$original_branch" >/dev/null 2>&1 || true
    echo "[linear] restored branch: $original_branch" | tee -a "$driver_log"
  else
    git -C "$base_dir" checkout -f "$original_commit" >/dev/null 2>&1 || true
    echo "[linear] restored detached HEAD: $original_commit" | tee -a "$driver_log"
  fi
}

trap restore_original_state EXIT

newer_short="$(git -C "$base_dir" rev-parse --short "$newer_commit")"
older_short="$(git -C "$base_dir" rev-parse --short "$older_commit")"

echo "[linear] start" | tee -a "$driver_log"
echo "[linear] older: $older_commit ($older_short)" | tee -a "$driver_log"
echo "[linear] newer: $newer_commit ($newer_short)" | tee -a "$driver_log"
echo "[linear] direction: $direction" | tee -a "$driver_log"
echo "[linear] history mode: $history_mode" | tee -a "$driver_log"
echo "[linear] target: $target" | tee -a "$driver_log"

if [[ -n "$original_branch" ]]; then
  echo "[linear] original branch: $original_branch" | tee -a "$driver_log"
else
  echo "[linear] original detached HEAD: $original_commit" | tee -a "$driver_log"
fi

if ! git -C "$base_dir" merge-base --is-ancestor "$older_commit" "$newer_commit"; then
  echo "Error: older commit is not an ancestor of newer commit" | tee -a "$driver_log" >&2
  exit 1
fi

case "$history_mode" in
  first-parent)
    mapfile -t commits < <(
      git -C "$base_dir" rev-list --reverse --first-parent "${older_commit}..${newer_commit}"
    )
    ;;
  topo)
    mapfile -t commits < <(
      git -C "$base_dir" rev-list --reverse --topo-order "${older_commit}..${newer_commit}"
    )
    ;;
  full)
    mapfile -t commits < <(
      git -C "$base_dir" rev-list --reverse "${older_commit}..${newer_commit}"
    )
    ;;
esac

commits=("$older_commit" "${commits[@]}")

total="${#commits[@]}"
echo "[linear] total commits in range: $total" | tee -a "$driver_log"

if [[ "$total" -eq 0 ]]; then
  echo "[linear] empty commit range" | tee -a "$driver_log" >&2
  exit 1
fi

good_commits=()
bad_commits=()
skip_commits=()
found_commit=""
found_result=""

if [[ "$direction" == "forward" ]]; then
  start=0
  end=$((total - 1))
  step=1
else
  start=$((total - 1))
  end=0
  step=-1
fi

i="$start"
while :; do
  commit="${commits[$i]}"
  short="$(git -C "$base_dir" rev-parse --short "$commit")"

  echo "[linear] testing index=$i: $short ($commit)" | tee -a "$driver_log"

  git -C "$base_dir" checkout -f "$commit" >/dev/null 2>&1

  set +e
  "$step_script"
  status=$?
  set -e

  case "$status" in
    0)
      echo "[linear] result: GOOD" | tee -a "$driver_log"
      good_commits+=("$commit")

      if [[ "$target" == "first-good" ]]; then
        found_commit="$commit"
        found_result="GOOD"
        break
      fi
      ;;
    1)
      echo "[linear] result: BAD" | tee -a "$driver_log"
      bad_commits+=("$commit")

      if [[ "$target" == "first-bad" ]]; then
        found_commit="$commit"
        found_result="BAD"
        break
      fi
      ;;
    125)
      echo "[linear] result: SKIP" | tee -a "$driver_log"
      skip_commits+=("$commit")
      ;;
    *)
      echo "[linear] unexpected step status: $status" | tee -a "$driver_log" >&2
      exit "$status"
      ;;
  esac

  if [[ "$i" -eq "$end" ]]; then
    break
  fi

  i=$((i + step))
done

echo "[linear] finished" | tee -a "$driver_log"

print_commit_list() {
  local label="$1"
  shift
  local commits_to_print=("$@")

  echo "[linear] $label (${#commits_to_print[@]}):" | tee -a "$driver_log"
  for c in "${commits_to_print[@]}"; do
    local s
    s="$(git -C "$base_dir" rev-parse --short "$c")"
    echo "[linear] $label: $s ($c)" | tee -a "$driver_log"
    git -C "$base_dir" log -1 --oneline "$c" | tee -a "$driver_log"
  done
}

if [[ "$target" == "first-good" || "$target" == "first-bad" ]]; then
  if [[ -n "$found_commit" ]]; then
    echo "[linear] first matching commit ($found_result): $(git -C "$base_dir" rev-parse --short "$found_commit") ($found_commit)" | tee -a "$driver_log"
    git -C "$base_dir" log -1 --oneline "$found_commit" | tee -a "$driver_log"
    exit 0
  fi

  echo "[linear] no matching commit found for target=$target" | tee -a "$driver_log"
  exit 1
fi

# target == all
print_commit_list "good" "${good_commits[@]}"
print_commit_list "bad" "${bad_commits[@]}"
print_commit_list "skip" "${skip_commits[@]}"

if [[ "${#good_commits[@]}" -eq 0 && "${#bad_commits[@]}" -eq 0 && "${#skip_commits[@]}" -eq 0 ]]; then
  echo "[linear] no commits were classified in range" | tee -a "$driver_log"
  exit 1
fi

exit 0