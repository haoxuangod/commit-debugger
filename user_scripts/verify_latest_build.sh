#!/usr/bin/env bash
set -euo pipefail

base_dir="${SCHEDULER_BASE_DIR:?SCHEDULER_BASE_DIR is not set}"
echo "verify_PATH:$PATH"
echo "bishengir-compile-path:$(which bishengir-compile)"
if pytest /home/c00956950/test_op/test_swizzle2d_new.py::test_swizzle2d[int64-shape7]; then
  echo "Result: GOOD"
  exit 0
else
  echo "Result: BAD"
  exit 1
fi