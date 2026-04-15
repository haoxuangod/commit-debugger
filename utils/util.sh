#!/usr/bin/env bash
set -euo pipefail

scheduler_require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "Error: required environment variable is not set: $name" >&2
    exit 1
  fi
}

scheduler_now() {
  date '+%F %T'
}

scheduler_commit_full() {
  local commit="$1"
  scheduler_require_env SCHEDULER_BASE_DIR
  git -C "$SCHEDULER_BASE_DIR" rev-parse "$commit"
}

scheduler_commit_short() {
  local commit="$1"
  scheduler_require_env SCHEDULER_BASE_DIR
  git -C "$SCHEDULER_BASE_DIR" rev-parse --short "$commit"
}

scheduler_commit_status_file() {
  local commit="$1"
  local full_commit
  full_commit="$(scheduler_commit_full "$commit")"

  scheduler_require_env SCHEDULER_COMMIT_STATUS_DIR
  echo "$SCHEDULER_COMMIT_STATUS_DIR/${full_commit}.env"
}

scheduler_commit_worktree_dir() {
  local commit="$1"
  local full_commit
  full_commit="$(scheduler_commit_full "$commit")"

  scheduler_require_env SCHEDULER_WORKTREE_DIR
  echo "$SCHEDULER_WORKTREE_DIR/${full_commit}"
}

scheduler_commit_build_dir() {
  local commit="$1"
  local full_commit
  full_commit="$(scheduler_commit_full "$commit")"

  scheduler_require_env SCHEDULER_BUILD_ROOT_DIR
  echo "$SCHEDULER_BUILD_ROOT_DIR/${full_commit}"
}

scheduler_commit_artifact_dir() {
  local commit="$1"
  local full_commit
  full_commit="$(scheduler_commit_full "$commit")"

  scheduler_require_env SCHEDULER_ARTIFACT_ROOT_DIR
  echo "$SCHEDULER_ARTIFACT_ROOT_DIR/${full_commit}"
}

scheduler_commit_artifact_meta_file() {
  local commit="$1"
  local artifact_dir
  artifact_dir="$(scheduler_commit_artifact_dir "$commit")"
  echo "$artifact_dir/meta.env"
}

scheduler_status_default_log_file() {
  echo "${SCHEDULER_DRIVER_LOG:-}"
}

scheduler_write_kv_file() {
  local file="$1"
  shift

  mkdir -p "$(dirname "$file")"

  local tmp_file="${file}.tmp"
  : > "$tmp_file"

  local line
  for line in "$@"; do
    printf '%s\n' "$line" >> "$tmp_file"
  done

  mv "$tmp_file" "$file"
}

scheduler_init_commit_status() {
  local commit="$1"
  local full_commit short_commit status_file
  local log_file="${2:-$(scheduler_status_default_log_file)}"

  full_commit="$(scheduler_commit_full "$commit")"
  short_commit="$(scheduler_commit_short "$commit")"
  status_file="$(scheduler_commit_status_file "$commit")"

  scheduler_write_kv_file "$status_file" \
    "COMMIT=$full_commit" \
    "SHORT_COMMIT=$short_commit" \
    "STATE=pending" \
    "ARTIFACT_STATE=not_started" \
    "ARTIFACT_SOURCE=none" \
    "ARTIFACT_FAILURE_REASON=none" \
    "ARTIFACT_DIR=$(scheduler_commit_artifact_dir "$commit")" \
    "ARTIFACT_PATH=" \
    "BUILD_TYPE=none" \
    "BUILD_STATE=not_started" \
    "BUILD_ATTEMPT_COUNT=0" \
    "FINAL_STATUS=pending" \
    "LOG_FILE=$log_file" \
    "UPDATED_AT=$(scheduler_now)"
}

scheduler_status_file_exists() {
  local commit="$1"
  local status_file
  status_file="$(scheduler_commit_status_file "$commit")"
  [[ -f "$status_file" ]]
}

scheduler_ensure_commit_status() {
  local commit="$1"
  local log_file="${2:-$(scheduler_status_default_log_file)}"
  if ! scheduler_status_file_exists "$commit"; then
    scheduler_init_commit_status "$commit" "$log_file"
  fi
}

scheduler_get_status_field() {
  local commit="$1"
  local field="$2"
  local status_file
  status_file="$(scheduler_commit_status_file "$commit")"

  if [[ ! -f "$status_file" ]]; then
    return 1
  fi

  grep -E "^${field}=" "$status_file" | tail -n1 | cut -d= -f2- || true
}

scheduler_set_status_fields() {
  local commit="$1"
  shift

  scheduler_ensure_commit_status "$commit"

  local status_file
  status_file="$(scheduler_commit_status_file "$commit")"

  local full_commit short_commit state artifact_state artifact_source artifact_failure_reason
  local artifact_dir artifact_path build_type build_state build_attempt_count
  local final_status log_file updated_at

  full_commit="$(scheduler_get_status_field "$commit" COMMIT || true)"
  short_commit="$(scheduler_get_status_field "$commit" SHORT_COMMIT || true)"
  state="$(scheduler_get_status_field "$commit" STATE || true)"
  artifact_state="$(scheduler_get_status_field "$commit" ARTIFACT_STATE || true)"
  artifact_source="$(scheduler_get_status_field "$commit" ARTIFACT_SOURCE || true)"
  artifact_failure_reason="$(scheduler_get_status_field "$commit" ARTIFACT_FAILURE_REASON || true)"
  artifact_dir="$(scheduler_get_status_field "$commit" ARTIFACT_DIR || true)"
  artifact_path="$(scheduler_get_status_field "$commit" ARTIFACT_PATH || true)"
  build_type="$(scheduler_get_status_field "$commit" BUILD_TYPE || true)"
  build_state="$(scheduler_get_status_field "$commit" BUILD_STATE || true)"
  build_attempt_count="$(scheduler_get_status_field "$commit" BUILD_ATTEMPT_COUNT || true)"
  build_failure_reason="$(scheduler_get_status_field "$commit" BUILD_FAILURE_REASON || true)"
  final_status="$(scheduler_get_status_field "$commit" FINAL_STATUS || true)"
  log_file="$(scheduler_get_status_field "$commit" LOG_FILE || true)"

  [[ -z "$full_commit" ]] && full_commit="$(scheduler_commit_full "$commit")"
  [[ -z "$short_commit" ]] && short_commit="$(scheduler_commit_short "$commit")"
  [[ -z "$state" ]] && state="pending"
  [[ -z "$artifact_state" ]] && artifact_state="not_started"
  [[ -z "$artifact_source" ]] && artifact_source="none"
  [[ -z "$artifact_failure_reason" ]] && artifact_failure_reason="none"
  [[ -z "$artifact_dir" ]] && artifact_dir="$(scheduler_commit_artifact_dir "$commit")"
  [[ -z "$artifact_path" ]] && artifact_path=""
  [[ -z "$build_type" ]] && build_type="none"
  [[ -z "$build_state" ]] && build_state="not_started"
  [[ -z "$build_attempt_count" ]] && build_attempt_count="0"
  [[ -z "$build_failure_reason" ]] && build_failure_reason="none"
  [[ -z "$final_status" ]] && final_status="pending"
  [[ -z "$log_file" ]] && log_file="$(scheduler_status_default_log_file)"

  local kv key value
  for kv in "$@"; do
    key="${kv%%=*}"
    value="${kv#*=}"
    case "$key" in
      COMMIT) full_commit="$value" ;;
      SHORT_COMMIT) short_commit="$value" ;;
      STATE) state="$value" ;;
      ARTIFACT_STATE) artifact_state="$value" ;;
      ARTIFACT_SOURCE) artifact_source="$value" ;;
      ARTIFACT_FAILURE_REASON) artifact_failure_reason="$value" ;;
      ARTIFACT_DIR) artifact_dir="$value" ;;
      ARTIFACT_PATH) artifact_path="$value" ;;
      BUILD_TYPE) build_type="$value" ;;
      BUILD_STATE) build_state="$value" ;;
      BUILD_ATTEMPT_COUNT) build_attempt_count="$value" ;;
      BUILD_FAILURE_REASON) build_failure_reason="$value" ;;
      FINAL_STATUS) final_status="$value" ;;
      LOG_FILE) log_file="$value" ;;
      *)
        echo "Error: unsupported status field: $key" >&2
        exit 1
        ;;
    esac
  done

  updated_at="$(scheduler_now)"

  scheduler_write_kv_file "$status_file" \
    "COMMIT=$full_commit" \
    "SHORT_COMMIT=$short_commit" \
    "STATE=$state" \
    "ARTIFACT_STATE=$artifact_state" \
    "ARTIFACT_SOURCE=$artifact_source" \
    "ARTIFACT_FAILURE_REASON=$artifact_failure_reason" \
    "ARTIFACT_DIR=$artifact_dir" \
    "ARTIFACT_PATH=$artifact_path" \
    "BUILD_TYPE=$build_type" \
    "BUILD_STATE=$build_state" \
    "BUILD_ATTEMPT_COUNT=$build_attempt_count" \
    "BUILD_FAILURE_REASON"=$build_failure_reason \
    "FINAL_STATUS=$final_status" \
    "LOG_FILE=$log_file" \
    "UPDATED_AT=$updated_at"
}

scheduler_print_commit_status() {
  local commit="$1"
  local status_file
  status_file="$(scheduler_commit_status_file "$commit")"

  if [[ ! -f "$status_file" ]]; then
    echo "No status file for commit: $commit" >&2
    return 1
  fi

  cat "$status_file"
}

scheduler_prepare_commit_dirs() {
  local commit="$1"
  mkdir -p \
    "$(scheduler_commit_worktree_dir "$commit")" \
    "$(scheduler_commit_build_dir "$commit")" \
    "$(scheduler_commit_artifact_dir "$commit")"
}

scheduler_write_artifact_meta() {
  local commit="$1"
  local artifact_path="${2:-}"
  local artifact_source="${3:-none}"

  local full_commit short_commit artifact_dir meta_file
  full_commit="$(scheduler_commit_full "$commit")"
  short_commit="$(scheduler_commit_short "$commit")"
  artifact_dir="$(scheduler_commit_artifact_dir "$commit")"
  meta_file="$(scheduler_commit_artifact_meta_file "$commit")"

  mkdir -p "$artifact_dir"

  scheduler_write_kv_file "$meta_file" \
    "COMMIT=$full_commit" \
    "SHORT_COMMIT=$short_commit" \
    "ARTIFACT_SOURCE=$artifact_source" \
    "ARTIFACT_DIR=$artifact_dir" \
    "ARTIFACT_PATH=$artifact_path" \
    "UPDATED_AT=$(scheduler_now)"
}

scheduler_mark_running() {
  local commit="$1"
  scheduler_set_status_fields "$commit" \
    "STATE=running"
}

scheduler_mark_building() {
  local commit="$1"
  local build_type="$2"
  scheduler_set_status_fields "$commit" \
    "STATE=running" \
    "ARTIFACT_STATE=acquiring" \
    "ARTIFACT_SOURCE=build" \
    "ARTIFACT_FAILURE_REASON=none" \
    "BUILD_TYPE=$build_type" \
    "BUILD_STATE=building" \
    "BUILD_FAILURE_REASON=none" \
    "FINAL_STATUS=pending"
}
scheduler_mark_build_succeeded() {
    local commit="$1"
    scheduler_set_status_fields "$commit" \
    "ARTIFACT_FAILURE_REASON=none" \
    "BUILD_STATE=succeeded" \
    "BUILD_FAILURE_REASON=none"
}

scheduler_mark_downloading() {
  local commit="$1"
  scheduler_set_status_fields "$commit" \
    "STATE=running" \
    "ARTIFACT_STATE=acquiring" \
    "ARTIFACT_SOURCE=download" \
    "ARTIFACT_FAILURE_REASON=none" \
    "BUILD_STATE=not_started" \
    "BUILD_FAILURE_REASON=none" \
    "FINAL_STATUS=pending"
}


scheduler_mark_artifact_ready() {
  local commit="$1"
  local artifact_path="$2"
  local artifact_source="$3"

  scheduler_set_status_fields "$commit" \
    "STATE=running" \
    "ARTIFACT_STATE=ready" \
    "ARTIFACT_SOURCE=$artifact_source" \
    "ARTIFACT_FAILURE_REASON=none" \
    "ARTIFACT_PATH=$artifact_path"

  scheduler_write_artifact_meta "$commit" "$artifact_path" "$artifact_source"
}

scheduler_mark_artifact_failed() {
  local commit="$1"
  local reason="$2"

  scheduler_set_status_fields "$commit" \
    "STATE=finished" \
    "ARTIFACT_STATE=failed" \
    "ARTIFACT_FAILURE_REASON=$reason" \
    "FINAL_STATUS=artifact_failed"
}

scheduler_mark_artifact_failure_reason() {
  local commit="$1"
  local reason="$2"

  scheduler_set_status_fields "$commit" \
    "ARTIFACT_FAILURE_REASON=$reason"
}

scheduler_mark_build_timeout() {
  local commit="$1"
  local reason="$2"

  scheduler_set_status_fields "$commit" \
    "BUILD_STATE=timeout" \
    "BUILD_FAILURE_REASON=$reason"
}

scheduler_mark_build_interrupted() {
  local commit="$1"
  local reason="$2"

  scheduler_set_status_fields "$commit" \
    "BUILD_STATE=interrupted" \
    "BUILD_FAILURE_REASON=$reason"
}

scheduler_mark_build_attempt_start() {
  local commit="$1"
  local build_type="$2"
  local increment_count="${3:-true}"

  local count
  count="$(scheduler_get_status_field "$commit" BUILD_ATTEMPT_COUNT || true)"
  [[ -z "$count" ]] && count=0

  case "$increment_count" in
    true)
      count=$((count + 1))
      ;;
    false)
      ;;
    *)
      echo "Error: increment_count must be 'true' or 'false', got: $increment_count" >&2
      return 1
      ;;
  esac

  scheduler_set_status_fields "$commit" \
    "BUILD_ATTEMPT_COUNT=$count" \
    "BUILD_TYPE=$build_type" \
    "ARTIFACT_FAILURE_REASON=none"
}

scheduler_mark_build_final_failed() {
  local commit="$1"
  local reason="$2"

  scheduler_set_status_fields "$commit" \
    "STATE=finished" \
    "ARTIFACT_STATE=failed" \
    "ARTIFACT_SOURCE=build" \
    "ARTIFACT_FAILURE_REASON=$reason" \
    "BUILD_FAILURE_REASON=$reason" \
    "BUILD_STATE=failed" \
    "FINAL_STATUS=artifact_failed"
}

scheduler_mark_build_failed() {
  local commit="$1"
  local reason="$2"

  scheduler_set_status_fields "$commit" \
    "BUILD_STATE=failed" \
    "BUILD_FAILURE_REASON=$reason"
}

scheduler_mark_testing_ready() {
  local commit="$1"
  scheduler_set_status_fields "$commit" \
    "STATE=running"
}

scheduler_mark_good() {
  local commit="$1"
  scheduler_set_status_fields "$commit" \
    "STATE=finished" \
    "FINAL_STATUS=good"
}

scheduler_mark_bad() {
  local commit="$1"
  scheduler_set_status_fields "$commit" \
    "STATE=finished" \
    "FINAL_STATUS=bad"
}

scheduler_mark_skip() {
  local commit="$1"
  scheduler_set_status_fields "$commit" \
    "STATE=finished" \
    "FINAL_STATUS=skip"
}

scheduler_mark_test_failed() {
  local commit="$1"
  scheduler_set_status_fields "$commit" \
    "STATE=finished" \
    "FINAL_STATUS=test_failed"
}

scheduler_is_commit_finished() {
  local commit="$1"
  local final_status
  final_status="$(scheduler_get_status_field "$commit" FINAL_STATUS || true)"

  case "$final_status" in
    good|bad|skip|artifact_failed|test_failed|timeout)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

scheduler_is_artifact_ready() {
  local commit="$1"
  local artifact_state
  artifact_state="$(scheduler_get_status_field "$commit" ARTIFACT_STATE || true)"
  [[ "$artifact_state" == "ready" ]]
}

scheduler_commit_artifact_path() {
  local commit="$1"
  scheduler_get_status_field "$commit" ARTIFACT_PATH || true
}
