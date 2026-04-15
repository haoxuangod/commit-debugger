#!/usr/bin/env bash
set -euo pipefail

base_dir="${SCHEDULER_BASE_DIR:?SCHEDULER_BASE_DIR is not set}"
unity_build="${SCHEDULER_UNITY_BUILD:-true}"
script_dir="${SCHEDULER_SCRIPT_DIR:?SCHEDULER_SCRIPT_DIR is not set}"
build_dir="${SCHEDULER_STEP_BUILD_DIR:?SCHEDULER_STEP_BUILD_DIR is not set}"
artifact_dir="${SCHEDULER_STEP_ARTIFACT_DIR:?SCHEDULER_STEP_ARTIFACT_DIR is not set}"
current_commit_short="${SCHEDULER_CURRENT_COMMIT_SHORT:?SCHEDULER_CURRENT_COMMIT_COMMIT_SHORT is not set}"
build_mode="${SCHEDULER_BUILD_MODE:-incremental}"
echo "BASE_DIR:$base_dir"

restore_files=()

backup_file() {
  local file="${1:?file path is required}"
  local backup="${file}.scheduler.bak"
  cp -f -- "$file" "$backup"
  restore_files+=("$file")
}

restore_all() {
  local file
  for file in "${restore_files[@]:-}"; do
    local backup="${file}.scheduler.bak"
    if [[ -f "$backup" ]]; then
      mv -f -- "$backup" "$file"
    fi
  done
}

trap restore_all EXIT

patch_unity_off_in_cmakelists() {
  local cmakelists="${1:?cmakelists path is required}"

  python3 - "$cmakelists" <<'PY'
from pathlib import Path
import re
import sys

p = Path(sys.argv[1])
text = p.read_text(encoding="utf-8")

marker = "set(CMAKE_UNITY_BUILD OFF)"
batch_marker = "set(CMAKE_UNITY_BUILD_BATCH_SIZE 8)"

text = re.sub(r'(?m)^[ \t]*set\s*\(\s*CMAKE_UNITY_BUILD\s+(ON|OFF)\s*\)\s*\n?', '', text)
text = re.sub(r'(?m)^[ \t]*set\s*\(\s*CMAKE_UNITY_BUILD_BATCH_SIZE\s+\d+\s*\)\s*\n?', '', text)

inject = marker + "\n" + batch_marker + "\n"

m = re.search(r'(?mi)^cmake_minimum_required\s*\([^\n]*\)\s*$', text, re.MULTILINE)
if m:
    pos = m.end()
    text = text[:pos] + "\n" + inject + text[pos:]
else:
    text = inject + "\n" + text

p.write_text(text, encoding="utf-8")
PY
}

if [[ "$unity_build" == "true" ]]; then
  backup_file "$base_dir/bishengir/CMakeLists.txt"
  backup_file "$base_dir/triton/CMakeLists.txt"

  patch_unity_off_in_cmakelists "$base_dir/bishengir/CMakeLists.txt"
  patch_unity_off_in_cmakelists "$base_dir/triton/CMakeLists.txt"
fi

export DISTCC_HOSTS="localhost:13632/72 localhost:33632/72"

if ! lsof -i :13632 > /dev/null 2>&1; then
    ssh -fN -L 13632:127.0.0.1:3632 worker1
fi

export DISTCC_HOSTS="localhost:13632/72"


unity_build_opt=""
if [[ "$unity_build" == "true" ]]; then
  unity_build_opt="--unity-build"
fi
clean_build_opt=""
if [[ "$build_mode" == "clean" ]]; then
  clean_build_opt="--rebuild"
fi
mkdir -p "$build_dir"

(
  cd "$base_dir" || exit 1

  PATCH_MARK_FILE="$base_dir/.patches_applied"
  apply_patches_args=()

  if [[ -f "$PATCH_MARK_FILE" ]]; then
    echo "patch mark found, run clean-up and enable --apply-patches"
    "$base_dir/build-tools/apply_patches.sh" --clean-up || exit 1
    apply_patches_args+=(--apply-patches)
  else
    echo "patch mark not found, skip clean-up and --apply-patches"
  fi

  chmod +x "$base_dir/build-tools/build1.sh"
  #--disable-ccache
  "$base_dir/build-tools/build1.sh" \
    --c-compiler clang \
    --cxx-compiler clang++ \
    --build-type Release \
    --use-linker mold \
    --enable-assertion \
    --disable-werror \
    --disable-bishengir-werror \
    --build-triton \
    --build "$build_dir" \
    --fast-build \
    --enable-distcc \
    $unity_build_opt \
    $clean_build_opt \
    "${apply_patches_args[@]}" \
    -j 72
)

mkdir -p "$artifact_dir" &&
cp "$build_dir/bin/bishengir-compile" "$artifact_dir"


