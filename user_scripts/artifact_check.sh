#!/usr/bin/env bash
set -u

artifact_dir="${SCHEDULER_STEP_ARTIFACT_DIR:?SCHEDULER_STEP_ARTIFACT_DIR is not set}"
current_commit="${SCHEDULER_CURRENT_COMMIT:-}"
current_commit_short="${SCHEDULER_CURRENT_COMMIT_SHORT:-}"

if [[ -z "$artifact_dir" ]]; then
  echo "[artifact-check] SCHEDULER_VERIFY_ARTIFACT_DIR is not set" >&2
  exit 125
fi

artifact_path="$artifact_dir/bishengir-compile"

echo "[artifact-check] commit: ${current_commit_short:-unknown} (${current_commit:-unknown})"
echo "[artifact-check] artifact dir: $artifact_dir"
echo "[artifact-check] artifact path: $artifact_path"

# 1. 文件必须存在
if [[ ! -f "$artifact_path" ]]; then
  echo "[artifact-check] artifact missing"
  exit 1
fi

# 2. 必须可执行
if [[ ! -x "$artifact_path" ]]; then
  echo "[artifact-check] artifact exists but is not executable"
  exit 1
fi

# 3. 可以加一些轻量合法性校验
# 比如 --version 能跑通，或者 help 能返回 0
if ! "$artifact_path" --version >/dev/null 2>&1; then
  echo "[artifact-check] artifact exists but failed '--version' check"
  exit 1
fi

echo "[artifact-check] artifact is valid"
exit 0