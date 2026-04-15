#!/usr/bin/env bash

set -euo pipefail

commit="${1:-}"

if [ -z "$commit" ]; then
  echo "Usage: $0 <commit>"
  exit 1
fi

score=0

# 基本元信息
meta=$(git show -s --format='%H|%h|%an|%ae|%ai|%cn|%ce|%ci|%s' "$commit")

commit_hash=$(echo "$meta" | cut -d'|' -f1)
short_commit=$(echo "$meta" | cut -d'|' -f2)
author_name=$(echo "$meta" | cut -d'|' -f3)
author_email=$(echo "$meta" | cut -d'|' -f4)
author_time=$(echo "$meta" | cut -d'|' -f5)
committer_name=$(echo "$meta" | cut -d'|' -f6)
committer_email=$(echo "$meta" | cut -d'|' -f7)
commit_time=$(echo "$meta" | cut -d'|' -f8)
title=$(echo "$meta" | cut -d'|' -f9-)

# 文件状态与增删统计
name_status=$(git diff-tree --no-commit-id --name-status -r "$commit")
numstat=$(git show --numstat --format= "$commit")

# 统计文件数和总增删
files_changed=$(echo "$numstat" | awk 'NF>=3 {count++} END {print count+0}')
insertions=$(echo "$numstat" | awk 'NF>=3 && $1 ~ /^[0-9]+$/ {add+=$1} END {print add+0}')
deletions=$(echo "$numstat" | awk 'NF>=3 && $2 ~ /^[0-9]+$/ {del+=$2} END {print del+0}')
total_lines=$((insertions + deletions))

# 提取所有路径，兼容 rename: R100 old new
all_paths=$(
  echo "$name_status" | awk '
    $1 ~ /^R[0-9]*$/ {
      print $2
      print $3
      next
    }
    NF >= 2 {
      print $2
    }
  ' | sed '/^$/d'
)

# 各类文件计数
cmakelists_count=$(echo "$all_paths" | grep -Ec '(^|/)CMakeLists\.txt$' || true)
top_level_cmakelists_count=$(echo "$all_paths" | grep -Ec '^CMakeLists\.txt$' || true)
cmake_module_file_count=$(echo "$all_paths" | grep -Ec '(^|/)[^/]+\.cmake$' || true)
cmake_dir_file_count=$(echo "$all_paths" | grep -Ec '^cmake/' || true)

header_file_count=$(echo "$all_paths" | grep -Ec '\.(h|hpp|hh|hxx)$' || true)
source_file_count=$(echo "$all_paths" | grep -Ec '\.(c|cc|cpp|cxx)$' || true)
test_file_count=$(echo "$all_paths" | grep -Ec '(^|/)(test|tests|unittest|unittests)/|(_test|_ut)\.(c|cc|cpp|cxx|h|hpp)$' || true)
doc_file_count=$(echo "$all_paths" | grep -Ec '(^|/)(doc|docs)/|\.md$|\.rst$|\.txt$' || true)

deleted_files=$(echo "$name_status" | awk '$1=="D"{count++} END{print count+0}')
renamed_files=$(echo "$name_status" | awk '$1 ~ /^R[0-9]*$/ {count++} END{print count+0}')

# 布尔特征
has_cmakelists=false
has_top_level_cmakelists=false
has_cmake_module_file=false
has_cmake_dir_change=false
has_build_system_change=false
has_header_change=false
has_source_change=false
has_test_change=false
has_doc_change=false

[ "$cmakelists_count" -gt 0 ] && has_cmakelists=true
[ "$top_level_cmakelists_count" -gt 0 ] && has_top_level_cmakelists=true
[ "$cmake_module_file_count" -gt 0 ] && has_cmake_module_file=true
[ "$cmake_dir_file_count" -gt 0 ] && has_cmake_dir_change=true
[ "$header_file_count" -gt 0 ] && has_header_change=true
[ "$source_file_count" -gt 0 ] && has_source_change=true
[ "$test_file_count" -gt 0 ] && has_test_change=true
[ "$doc_file_count" -gt 0 ] && has_doc_change=true

if [ "$has_cmakelists" = true ] || [ "$has_cmake_module_file" = true ] || [ "$has_cmake_dir_change" = true ]; then
  has_build_system_change=true
fi

# 风险打分
# 1. 规模
if [ "$files_changed" -gt 10 ]; then score=$((score + 2)); fi
if [ "$files_changed" -gt 30 ]; then score=$((score + 2)); fi
if [ "$total_lines" -gt 200 ]; then score=$((score + 2)); fi
if [ "$total_lines" -gt 1000 ]; then score=$((score + 5)); fi

# 2. 构建系统相关
if [ "$has_cmakelists" = true ]; then
  score=$((score + 5))
fi

if [ "$has_top_level_cmakelists" = true ]; then
  score=$((score + 2))
fi

if [ "$has_cmake_module_file" = true ]; then
  score=$((score + 4))
fi

if [ "$has_cmake_dir_change" = true ]; then
  score=$((score + 3))
fi

# 3. 头文件 / 删除 / 重命名
if [ "$has_header_change" = true ]; then
  score=$((score + 2))
fi

score=$((score + deleted_files * 3))
score=$((score + renamed_files * 2))

# 4. commit 标题关键词
if echo "$title" | grep -qiE 'build|cmake|toolchain|link|compiler|refactor|dependency|rename|remove'; then
  score=$((score + 2))
fi

# 输出 key=value，便于后续脚本解析
cat <<EOF
commit=$commit_hash
short_commit=$short_commit
title=$title

author_name=$author_name
author_email=$author_email
author_time=$author_time

committer_name=$committer_name
committer_email=$committer_email
commit_time=$commit_time

files_changed=$files_changed
insertions=$insertions
deletions=$deletions
total_lines_changed=$total_lines

has_build_system_change=$has_build_system_change

has_cmakelists=$has_cmakelists
cmakelists_count=$cmakelists_count

has_top_level_cmakelists=$has_top_level_cmakelists
top_level_cmakelists_count=$top_level_cmakelists_count

has_cmake_module_file=$has_cmake_module_file
cmake_module_file_count=$cmake_module_file_count

has_cmake_dir_change=$has_cmake_dir_change
cmake_dir_file_count=$cmake_dir_file_count

has_header_change=$has_header_change
header_file_count=$header_file_count

has_source_change=$has_source_change
source_file_count=$source_file_count

has_test_change=$has_test_change
test_file_count=$test_file_count

has_doc_change=$has_doc_change
doc_file_count=$doc_file_count

deleted_files=$deleted_files
renamed_files=$renamed_files

risk_score=$score
EOF