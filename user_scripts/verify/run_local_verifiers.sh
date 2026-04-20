#!/usr/bin/env bash
set -euo pipefail

cases_file="${1:?cases file is required}"

if [[ ! -f "$cases_file" ]]; then
  echo "local cases file not found: $cases_file" >&2
  exit 125
fi

case_count=0
while IFS= read -r line || [[ -n "$line" ]]; do
  cmd="$(printf '%s' "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [[ -z "$cmd" || "${cmd:0:1}" == "#" ]] && continue

  case_count=$((case_count + 1))
  echo "[verify][local][$case_count] $cmd"
  if ! bash -lc "$cmd"; then
    echo "[verify][local][$case_count] failed, stop verify pipeline"
    echo "Result: BAD"
    exit 1
  fi
done < "$cases_file"

echo "[verify][local] all passed (count=$case_count)"
