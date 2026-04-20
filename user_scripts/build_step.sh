#!/usr/bin/env bash
set -euo pipefail

base_dir="${SCHEDULER_BASE_DIR:?SCHEDULER_BASE_DIR is not set}"
unity_build="${SCHEDULER_UNITY_BUILD:-true}"
script_dir="${SCHEDULER_SCRIPT_DIR:?SCHEDULER_SCRIPT_DIR is not set}"
build_dir="${SCHEDULER_STEP_BUILD_DIR:?SCHEDULER_STEP_BUILD_DIR is not set}"
artifact_dir="${SCHEDULER_STEP_ARTIFACT_DIR:?SCHEDULER_STEP_ARTIFACT_DIR is not set}"
current_commit_short="${SCHEDULER_CURRENT_COMMIT_SHORT:?SCHEDULER_CURRENT_COMMIT_SHORT is not set}"
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

workers=(
  "worker_182:13632/72"
)

#active_distcc_hosts=()
#for worker_entry in "${workers[@]}"; do
#  worker="${worker_entry%%:*}"
#  worker_config="${worker_entry#*:}"
#  local_port="${worker_config%%/*}"
#  worker_jobs="${worker_config##*/}"

#  if lsof -i :"$local_port" > /dev/null 2>&1; then
#    active_distcc_hosts+=("localhost:${local_port}/${worker_jobs}")
#    continue
#  fi

#  if ssh -o BatchMode=yes -o ConnectTimeout=10 "$worker" "echo ok" > /dev/null 2>&1; then
#    ssh -fN -L "${local_port}:127.0.0.1:3632" "$worker"
#    active_distcc_hosts+=("127.0.0.1:${local_port}/${worker_jobs}")
#  fi
#done

#enable_distcc_opt=""
#if (( ${#active_distcc_hosts[@]} > 0 )); then
#  DISTCC_HOSTS="${active_distcc_hosts[*]}"
#  export DISTCC_HOSTS
#  enable_distcc_opt="--enable-distcc"
#  echo "DISTCC enabled with hosts: $DISTCC_HOSTS"
#else
#  echo "No reachable distcc workers, build without distcc"
#fi


#export DISTCC_HOSTS="47.93.126.217:13632"
#DISTCC_HOSTS='47.93.126.217:13632' distcc clang++ -c test.cpp -o test.o
#enable_distcc_opt="--enable-distcc"
enable_distcc_opt=""
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
    echo "patch mark found, patches already applied, skip --apply-patches"
  else
    echo "patch mark not found, apply patches and create mark"
    "$base_dir/build-tools/apply_patches.sh" || exit 1
    apply_patches_args+=(--apply-patches)
    # 创建补丁标记文件
    touch "$PATCH_MARK_FILE"
    echo "Created patch mark file: $PATCH_MARK_FILE"
  fi

  chmod +x "$base_dir/build-tools/build1.sh"
  #--disable-ccache
  #-j 需要与远程与自身核数量进行匹配
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
    $enable_distcc_opt \
    $unity_build_opt \
    $clean_build_opt \
    "${apply_patches_args[@]}" \
    -j 18
)

mkdir -p "$artifact_dir" &&
cp "$build_dir/bin/bishengir-compile" "$artifact_dir"

