#!/usr/bin/env bash
# =============================================================================
# run_remote_verifiers.sh
#
# 远程验证执行脚本:将本地构建出的 bishengir-compile 产物以及本地 pytest
# 测试文件同步到远端机器,进入指定 Docker 容器里执行 pytest,用于在
# commit-debugger(git bisect 风格)流程中判断某次提交是否破坏了测试。
#
# 退出码约定(与 `git bisect run` 语义对齐):
#   0     -> 所有用例通过  (good)
#   125   -> 前置条件缺失,跳过此提交 (skip)
#   其它  -> 测试失败     (bad)
# =============================================================================
set -euo pipefail

# ---- 入参与配置加载 ---------------------------------------------------------

# 第 1 个参数:用例清单文件,每行一个 pytest 节点(支持 path::test_name 语法)
cases_file="${1:?cases file is required}"

# 脚本自身所在目录,用于定位默认配置文件
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
default_config_file="$script_dir/verify.conf"
# 允许通过环境变量 VERIFY_CONFIG_FILE 覆盖默认配置路径
config_file="${VERIFY_CONFIG_FILE:-$default_config_file}"

# 若配置文件存在则 source 进来(内含 SSH 目标、容器名等变量)
if [[ -f "$config_file" ]]; then
  # shellcheck disable=SC1090
  echo "use config_file:$config_file"
  source "$config_file"

fi

# 用例清单文件不存在 -> 退出码 125(跳过,而非测试失败)
if [[ ! -f "$cases_file" ]]; then
  echo "remote cases file not found: $cases_file" >&2
  exit 125
fi

# ---- 读取 SSH / 容器 / 产物相关配置 -----------------------------------------

ssh_target="${VERIFY_SSH_TARGET:?VERIFY_SSH_TARGET is not set}"   # 必填:ssh 目标 user@host 或 ~/.ssh/config 里的 Host 别名
# ssh 端口:不设置时不传 -p,完全由 ~/.ssh/config 决定
# (例如 worker_203 通过 ProxyJump 中转,强行 -p 22 会直连中转机)
ssh_port="${VERIFY_SSH_PORT:-}"
ssh_opts_raw="${VERIFY_SSH_OPTS:-}"                                # 额外 ssh 选项(字符串,按空格拆分)
verify_container="${VERIFY_DOCKER_CONTAINER:-c00956950}"           # 远端 Docker 容器名
verify_shared_root="${VERIFY_SHARED_ROOT:-/home/c00956950}"        # 远端共享根目录(容器内外可见)

# 待验证的产物路径:优先使用 VERIFY_ARTIFACT_PATH;
# 否则使用调度器提供的 SCHEDULER_STEP_ARTIFACT_DIR/bishengir-compile
artifact_path="${VERIFY_ARTIFACT_PATH:-}"
if [[ -z "$artifact_path" ]]; then
  artifact_dir="${SCHEDULER_STEP_ARTIFACT_DIR:-}"
  if [[ -n "$artifact_dir" ]]; then
    artifact_path="$artifact_dir/bishengir-compile"
  fi
fi
artifact_path="${artifact_path:?VERIFY_ARTIFACT_PATH is not set and SCHEDULER_STEP_ARTIFACT_DIR is unavailable}"

# 产物文件缺失同样视为"跳过"
if [[ ! -f "$artifact_path" ]]; then
  echo "verify artifact not found: $artifact_path" >&2
  exit 125
fi

# ---- 计算远端工作目录 -------------------------------------------------------
# 以 run_id(默认当前时间戳)隔离,避免多次运行互相干扰
verify_run_id="${VERIFY_RUN_ID:-$(date +%s)}"
shared_root="${VERIFY_REMOTE_ROOT:-$verify_shared_root/commit_debugger_verify_${verify_run_id}}"
shared_artifact="$shared_root/bishengir-compile"          # 远端产物落位路径
shared_verify_script="$shared_root/run_remote_pytests.sh" # 远端执行脚本落位路径

# ---- 解析用例清单 -----------------------------------------------------------
# 去掉首尾空白、忽略空行与 # 注释行
remote_test_nodes=()
while IFS= read -r line || [[ -n "$line" ]]; do
  node="$(printf '%s' "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [[ -z "$node" || "${node:0:1}" == "#" ]] && continue
  remote_test_nodes+=("$node")
done < "$cases_file"

# 没有任何有效用例:直接判为 good
if (( ${#remote_test_nodes[@]} == 0 )); then
  echo "no remote cases configured: $cases_file"
  exit 0
fi

# ---- 本地路径 → 远端路径映射 -------------------------------------------------
# local_to_remote_dir: 本地目录 -> 远端目录 的映射表
# local_test_dirs:    需要同步到远端的本地目录列表(去重)
# remote_nodes_mapped: 替换过路径、供远端 pytest 使用的节点列表
declare -A local_to_remote_dir=()
declare -a local_test_dirs=()
declare -a remote_nodes_mapped=()

for node in "${remote_test_nodes[@]}"; do
  # 拆分 "文件路径" 与 "::test_xxx" 后缀
  raw_file="${node%%::*}"
  suffix=""
  if [[ "$node" == *"::"* ]]; then
    suffix="${node#"$raw_file"}"
  fi

  # 归一化为绝对路径(相对路径按 $PWD 解析)
  if [[ "$raw_file" = /* ]]; then
    local_file="$raw_file"
  else
    local_file="$PWD/$raw_file"
  fi
  local_file="$(cd "$(dirname "$local_file")" && pwd)/$(basename "$local_file")"

  if [[ ! -f "$local_file" ]]; then
    echo "verify test file not found: $local_file" >&2
    exit 125
  fi

  # 每个本地目录首次出现时,记录其对应的远端目录
  # 远端保留完整本地路径层级,避免不同目录下同名文件冲突
  local_dir="$(dirname "$local_file")"
  if [[ -z "${local_to_remote_dir[$local_dir]+x}" ]]; then
    local_to_remote_dir["$local_dir"]="$shared_root/tests$local_dir"
    local_test_dirs+=("$local_dir")
  fi

  # 构造远端节点:远端文件路径 + 原始 ::test 后缀
  remote_file="${local_to_remote_dir[$local_dir]}/$(basename "$local_file")"
  remote_nodes_mapped+=("${remote_file}${suffix}")
done

# ---- 打印运行摘要 -----------------------------------------------------------
echo "[verify][remote] ssh target: $ssh_target"
echo "[verify][remote] container: $verify_container"
echo "[verify][remote] shared root: $shared_root"
echo "[verify][remote] artifact: $artifact_path"
echo "[verify][remote] case count: ${#remote_nodes_mapped[@]}"

# ---- 构造 ssh 命令 ----------------------------------------------------------
# 只在显式指定了端口时才追加 -p,以兼容 ~/.ssh/config 里的 ProxyJump/自定义端口等配置
ssh_cmd=(ssh)
if [[ -n "$ssh_port" ]]; then
  ssh_cmd+=(-p "$ssh_port")
fi
if [[ -n "$ssh_opts_raw" ]]; then
  # 将 VERIFY_SSH_OPTS 按空白拆成独立参数
  # shellcheck disable=SC2206
  extra_ssh_opts=($ssh_opts_raw)
  ssh_cmd+=("${extra_ssh_opts[@]}")
fi

# ---- 在远端准备目录 ---------------------------------------------------------
# 一次性 mkdir -p 共享根目录与所有测试目录,printf %q 做 shell 转义
mkdirs_cmd="mkdir -p $(printf "%q" "$shared_root")"
for local_dir in "${local_test_dirs[@]}"; do
  mkdirs_cmd+=" $(printf "%q" "${local_to_remote_dir[$local_dir]}")"
done
# 先打印即将执行的远端命令,便于排查
echo "[verify][remote] >>> ssh ${ssh_target} -- ${mkdirs_cmd}"
"${ssh_cmd[@]}" "$ssh_target" "$mkdirs_cmd"

# 若存在 pv 则用它显示传输进度(速率/已传字节/预估百分比),否则退化为直接 tar/cat
have_pv=0
if command -v pv >/dev/null 2>&1; then
  have_pv=1
fi

# ---- 同步测试文件到远端 -----------------------------------------------------
# 使用 tar over ssh 流式传输(无需 rsync 依赖)
for local_dir in "${local_test_dirs[@]}"; do
  remote_dir="${local_to_remote_dir[$local_dir]}"
  # 先统计本次要传输的字节数,用于进度百分比
  dir_bytes="$(du -sb "$local_dir" 2>/dev/null | awk '{print $1}')"
  dir_human="$(du -sh "$local_dir" 2>/dev/null | awk '{print $1}')"
  echo "[verify][remote] sync $local_dir -> $remote_dir (size: ${dir_human:-unknown})"
  echo "[verify][remote] >>> tar -C $local_dir -cf - . | ssh ${ssh_target} tar -C ${remote_dir} -xf -"
  if (( have_pv )) && [[ -n "$dir_bytes" ]]; then
    tar -C "$local_dir" -cf - . \
      | pv -s "$dir_bytes" -N "sync:$(basename "$local_dir")" \
      | "${ssh_cmd[@]}" "$ssh_target" \
        "tar -C $(printf "%q" "$remote_dir") -xf -"
  else
    tar -C "$local_dir" -cf - . | "${ssh_cmd[@]}" "$ssh_target" \
      "tar -C $(printf "%q" "$remote_dir") -xf -"
  fi
done

# ---- 传输待验证产物(bishengir-compile) ------------------------------------
artifact_bytes="$(stat -c %s "$artifact_path" 2>/dev/null || wc -c <"$artifact_path")"
artifact_human="$(du -h "$artifact_path" 2>/dev/null | awk '{print $1}')"
echo "[verify][remote] upload artifact $artifact_path -> $shared_artifact (size: ${artifact_human:-unknown})"
echo "[verify][remote] >>> cat $artifact_path | ssh ${ssh_target} cat > ${shared_artifact}"
if (( have_pv )) && [[ -n "$artifact_bytes" ]]; then
  pv -s "$artifact_bytes" -N "artifact" "$artifact_path" \
    | "${ssh_cmd[@]}" "$ssh_target" \
      "cat > $(printf "%q" "$shared_artifact") && chmod +x $(printf "%q" "$shared_artifact")"
else
  cat "$artifact_path" | "${ssh_cmd[@]}" "$ssh_target" \
    "cat > $(printf "%q" "$shared_artifact") && chmod +x $(printf "%q" "$shared_artifact")"
fi

# ---- 生成远端执行脚本 -------------------------------------------------------
# 把 $shared_root 插到 PATH 最前,使被测代码里 subprocess 调用的
# bishengir-compile 命中刚同步上去的产物
remote_script=$(
  cat <<EOF
set -euo pipefail
chmod +x $(printf "%q" "$shared_artifact")
export PATH=$(printf "%q" "$shared_root"):\$PATH
export PATH=$(printf "%q" "$shared_root/bin"):\$PATH
echo "verify_PATH:\$PATH"
echo "bishengir-compile-path:\$(which bishengir-compile || true)"
echo "hivmc-a5-path:\$(which hivmc-a5 || true)"
run_pytest_case() {
  local node="\$1"
  echo "[verify][remote] pytest \$node"
  pytest "\$node"
}
EOF
)

# 为每个用例追加一行调用。因 set -e,任一用例失败会立即非零退出
for node in "${remote_nodes_mapped[@]}"; do
  remote_script+="
run_pytest_case $(printf "%q" "$node")"
done

# 将上面拼好的脚本写到远端文件(heredoc 用 'EOF' 加引号,避免远端再次展开)
"${ssh_cmd[@]}" "$ssh_target" \
  "cat > $(printf "%q" "$shared_verify_script") <<'EOF'
$remote_script
EOF
chmod +x $(printf "%q" "$shared_verify_script")"

# ---- 在远端容器内执行 -------------------------------------------------------
# -tt   : 强制分配 TTY,配合 docker exec -it 获取实时输出
# bash -lc: 走登录 shell,确保容器内的 PATH / 环境初始化生效
"${ssh_cmd[@]}" -tt "$ssh_target" \
  "docker exec -it $(printf "%q" "$verify_container") bash -lc $(printf "%q" "bash '$shared_verify_script'")"

echo "[verify][remote] all passed"
