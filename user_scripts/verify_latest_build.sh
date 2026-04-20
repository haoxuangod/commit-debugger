#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
verify_dir="$script_dir/verify"
default_config_file="$verify_dir/verify.conf"
config_file="${VERIFY_CONFIG_FILE:-$default_config_file}"

local_runner="$verify_dir/run_local_verifiers.sh"
remote_runner="$verify_dir/run_remote_verifiers.sh"

local_cases_file="${VERIFY_LOCAL_CASES_FILE:-$verify_dir/local_cases.list}"
remote_cases_file="${VERIFY_REMOTE_CASES_FILE:-$verify_dir/remote_cases.list}"
enable_local_cases="${VERIFY_ENABLE_LOCAL_CASES:-true}"
enable_remote_cases="${VERIFY_ENABLE_REMOTE_CASES:-true}"

if [[ -f "$config_file" ]]; then
  # shellcheck disable=SC1090
  source "$config_file"
  local_cases_file="${VERIFY_LOCAL_CASES_FILE:-$local_cases_file}"
  remote_cases_file="${VERIFY_REMOTE_CASES_FILE:-$remote_cases_file}"
  enable_local_cases="${VERIFY_ENABLE_LOCAL_CASES:-$enable_local_cases}"
  enable_remote_cases="${VERIFY_ENABLE_REMOTE_CASES:-$enable_remote_cases}"
fi

is_true() {
  case "${1,,}" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

if [[ ! -x "$local_runner" ]]; then
  echo "local runner not found or not executable: $local_runner" >&2
  exit 125
fi

if [[ ! -x "$remote_runner" ]]; then
  echo "remote runner not found or not executable: $remote_runner" >&2
  exit 125
fi

if is_true "$enable_local_cases"; then
  if [[ ! -f "$local_cases_file" ]]; then
    echo "local cases file not found: $local_cases_file" >&2
    exit 125
  fi
fi

if is_true "$enable_remote_cases"; then
  if [[ ! -f "$remote_cases_file" ]]; then
    echo "remote cases file not found: $remote_cases_file" >&2
    exit 125
  fi
fi

if is_true "$enable_local_cases"; then
  echo "[verify] local cases: $local_cases_file"
  "$local_runner" "$local_cases_file"
else
  echo "[verify] local cases disabled by config"
fi

if is_true "$enable_remote_cases"; then
  echo "[verify] run remote cases: $remote_cases_file"
  "$remote_runner" "$remote_cases_file"
else
  echo "[verify] remote cases disabled by config"
fi

echo "Result: GOOD"
