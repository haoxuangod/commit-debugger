#!/usr/bin/env bash
set -euo pipefail

# 测试状态机模块

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# 加载util模块（状态机模块依赖它）
if [[ -f "./utils/util.sh" ]]; then
    source ./utils/util.sh
else
    echo "警告: util.sh 未找到，状态机函数可能受限"
fi

# 加载状态机模块
source ./state_machine.sh

# 模拟必要的环境变量
export SCHEDULER_BASE_DIR="/tmp/test_scheduler"
export SCHEDULER_COMMIT_STATUS_DIR="/tmp/test_scheduler/status"
export SCHEDULER_BUILD_ROOT_DIR="/tmp/test_scheduler/build"
export SCHEDULER_ARTIFACT_ROOT_DIR="/tmp/test_scheduler/artifact"
export SCHEDULER_WORKTREE_DIR="/tmp/test_scheduler/worktree"

# 创建测试目录
mkdir -p "$SCHEDULER_BASE_DIR" "$SCHEDULER_COMMIT_STATUS_DIR" \
         "$SCHEDULER_BUILD_ROOT_DIR" "$SCHEDULER_ARTIFACT_ROOT_DIR" \
         "$SCHEDULER_WORKTREE_DIR"

# 初始化git仓库用于测试
cd "$SCHEDULER_BASE_DIR"
git init --quiet
git config user.email "test@example.com"
git config user.name "Test User"
echo "test file" > test.txt
git add test.txt
git commit -m "Initial commit" --quiet

# 获取当前commit
TEST_COMMIT="$(git rev-parse HEAD)"

echo "测试commit: $TEST_COMMIT"

# 测试1: 基本状态获取
echo "=== 测试1: 基本状态获取 ==="
get_current_state "$TEST_COMMIT" || echo "初始状态: pending"

# 测试2: 状态快照
echo "=== 测试2: 状态快照 ==="
eval $(get_build_state_snapshot "$TEST_COMMIT")
echo "BUILD_STATE: $BUILD_STATE"
echo "ARTIFACT_FAILURE_REASON: $ARTIFACT_FAILURE_REASON"
echo "BUILD_ATTEMPT_COUNT: $BUILD_ATTEMPT_COUNT"
echo "BUILD_TYPE: $BUILD_TYPE"

# 测试3: 构建决策
echo "=== 测试3: 构建决策 ==="
mapfile -t plan < <(
  determine_build_plan \
    5 \
    "/tmp/test_build_dir" \
    0 \
    "false" \
    "$STATE_BUILD_NOT_STARTED" \
    "none" \
    "$STATE_BUILD_TYPE_INCREMENTAL"
)
echo "构建类型: ${plan[0]}"
echo "开始新构建: ${plan[1]}"
echo "继续之前构建: ${plan[2]}"
echo "回退原因: ${plan[3]}"
echo "停止循环: ${plan[4]}"

# 测试4: 状态转换函数
echo "=== 测试4: 状态转换函数 ==="
if state_machine_validate_transition "pending" "running"; then
  echo "状态转换验证: pending -> running (有效)"
else
  echo "状态转换验证: pending -> running (无效)"
fi

# 清理
cd "$SCRIPT_DIR"
rm -rf "/tmp/test_scheduler"

echo "=== 所有测试完成 ==="