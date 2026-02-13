#!/usr/bin/env bash
# linear-machine — polls Linear, dispatches coding agents, posts results
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/.env"
source "$SCRIPT_DIR/config.sh"       # legacy fallback for STATUS_* globals
source "$SCRIPT_DIR/lib/linear.sh"

PID_FILE="$STATE_DIR/machine.pid"
LOG_FILE="$STATE_DIR/machine.log"

log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG_FILE"; }

# ---------------------------------------------------------------------------
# Environment helpers
# ---------------------------------------------------------------------------

# Read value from config file: grep + cut pattern
read_config_var() {
  local file="$1" key="$2"
  grep "^${key}=" "$file" 2>/dev/null | cut -d= -f2 || true
}

# Collect all TODO + IN_REVIEW status IDs from every environment config.
# Falls back to global config.sh values if no environments/ dir exists.
collect_poll_states() {
  local states=()
  local found=false

  for env_dir in "$SCRIPT_DIR"/environments/*/; do
    [ -f "$env_dir/config.sh" ] || continue
    found=true
    local todo review
    todo=$(read_config_var "$env_dir/config.sh" STATUS_TODO)
    review=$(read_config_var "$env_dir/config.sh" STATUS_IN_REVIEW)
    [ -n "$todo" ] && states+=("$todo")
    [ -n "$review" ] && states+=("$review")
  done

  # Legacy fallback: no environments dir, use globals from config.sh
  if ! $found; then
    states+=("$STATUS_TODO" "$STATUS_IN_REVIEW")
  fi

  printf '%s\n' "${states[@]}" | sort -u
}

# Resolve project ID → environment directory path.
# Returns empty string if nothing resolves (caller uses legacy fallback).
resolve_environment() {
  local project_id="$1"
  local mapping="$SCRIPT_DIR/environments/mapping.conf"

  [ -z "$project_id" ] || [ ! -f "$mapping" ] && { echo ""; return; }

  local env_name
  env_name=$(read_config_var "$mapping" "$project_id")
  local env_dir="$SCRIPT_DIR/environments/${env_name:-default}"
  [ -d "$env_dir" ] && echo "$env_dir" || echo ""
}

# Read repo path from an environment directory.
# Falls back to the global REPOS_DIR.
env_repo_path() {
  local env_dir="$1"
  [ -n "$env_dir" ] && [ -f "$env_dir/repo_path" ] && {
    head -1 "$env_dir/repo_path" | tr -d '[:space:]'
    return
  }
  echo "$REPOS_DIR"
}

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------
main_loop() {
  log "Polling every ${POLL_INTERVAL}s for issues assigned to agent ($AGENT_USER_ID)"
  log "Agent type: $AGENT_TYPE"

  while true; do
    collect_results
    poll_and_dispatch
    sleep "$POLL_INTERVAL"
  done
}

# ---------------------------------------------------------------------------
# Phase 1: collect finished agents — post output, update status
# ---------------------------------------------------------------------------
collect_results() {
  for state_dir in "$STATE_DIR"/*/; do
    [ -d "$state_dir" ] || continue
    local id
    id=$(basename "$state_dir")
    local session="linear-${id}"

    # Skip if agent is still running
    tmux has-session -t "$session" 2>/dev/null && continue

    # Skip if not a tracked issue (no metadata)
    [ -f "$state_dir/issue_uuid" ] || continue

    # Skip if no pending output
    [ -f "$state_dir/output" ] || continue

    local output
    output=$(cat "$state_dir/output")

    # Skip empty output (agent produced nothing)
    [ -z "$output" ] && {
      log "WARN: empty output for $id"
      mv "$state_dir/output" "$state_dir/last_output"
      continue
    }

    local issue_uuid
    issue_uuid=$(cat "$state_dir/issue_uuid")

    # Resolve environment for per-env status ID
    local project_id=""
    [ -f "$state_dir/project_id" ] && project_id=$(cat "$state_dir/project_id")
    local env_dir
    env_dir=$(resolve_environment "$project_id")
    local status_in_review="$STATUS_IN_REVIEW"
    [ -n "$env_dir" ] && [ -f "$env_dir/config.sh" ] && \
      status_in_review=$(read_config_var "$env_dir/config.sh" STATUS_IN_REVIEW)

    log "Posting results for $id"
    linear_post_comment "$issue_uuid" "$output" > /dev/null
    linear_set_status "$issue_uuid" "$status_in_review" > /dev/null

    # Mark as processed
    mv "$state_dir/output" "$state_dir/last_output"
    date -u +%Y-%m-%dT%H:%M:%SZ > "$state_dir/posted_at"

    log "Posted comment for $id, moved to In Review"
  done
}

# ---------------------------------------------------------------------------
# Phase 2: poll Linear, dispatch or resume agents
# ---------------------------------------------------------------------------
poll_and_dispatch() {
  local poll_file="$STATE_DIR/poll.json"
  local poll_states=()
  while IFS= read -r s; do
    poll_states+=("$s")
  done < <(collect_poll_states)
  linear_poll_issues "${poll_states[@]}" > "$poll_file" 2>/dev/null || return

  jq -c '.data.issues.nodes // [] | .[]' "$poll_file" 2>/dev/null | while IFS= read -r issue; do
    local issue_uuid id title issue_status
    issue_uuid=$(echo "$issue" | jq -r '.id')
    id=$(echo "$issue" | jq -r '.identifier' | tr '[:upper:]' '[:lower:]')
    title=$(echo "$issue" | jq -r '.title')
    issue_status=$(echo "$issue" | jq -r '.state.name')
    local session="linear-${id}"

    # Skip if agent already running for this issue
    tmux has-session -t "$session" 2>/dev/null && continue

    local state_dir="$STATE_DIR/$id"
    mkdir -p "$state_dir"

    if [ "$issue_status" = "Todo" ]; then
      dispatch_new "$issue" "$id" "$state_dir"
    elif [ "$issue_status" = "In Review" ]; then
      check_and_resume "$issue" "$id" "$state_dir"
    fi
  done
}

# ---------------------------------------------------------------------------
# Dispatch: new issue
# ---------------------------------------------------------------------------
dispatch_new() {
  local issue="$1" id="$2" state_dir="$3"
  local issue_uuid title description project_id
  issue_uuid=$(echo "$issue" | jq -r '.id')
  title=$(echo "$issue" | jq -r '.title')
  description=$(echo "$issue" | jq -r '.description // "No description provided."')
  project_id=$(echo "$issue" | jq -r '.project.id // empty')

  # Resolve environment
  local env_dir
  env_dir=$(resolve_environment "$project_id")
  local workdir
  workdir=$(env_repo_path "$env_dir")
  local status_in_progress="$STATUS_IN_PROGRESS"
  [ -n "$env_dir" ] && [ -f "$env_dir/config.sh" ] && \
    status_in_progress=$(read_config_var "$env_dir/config.sh" STATUS_IN_PROGRESS)

  # Write prompt
  cat > "$state_dir/prompt" <<PROMPT
You are working on the following task:

Title: $title

Description:
$description

Work in this repository directory. Complete the task as described.
If you need clarification or input from the team, clearly state your question.
When finished, provide a summary of what you did and what changed.
PROMPT

  # Save issue metadata
  echo "$issue_uuid" > "$state_dir/issue_uuid"
  echo "$title" > "$state_dir/title"
  [ -n "$project_id" ] && echo "$project_id" > "$state_dir/project_id"

  # Update Linear status
  linear_set_status "$issue_uuid" "$status_in_progress" > /dev/null

  # Dispatch agent in tmux
  local session="linear-${id}"
  local adapter_cmd="'$SCRIPT_DIR/adapters/${AGENT_TYPE}.sh' start '$state_dir' '$workdir'"

  # Build tmux command with optional env sourcing and setup
  local tmux_cmd="$adapter_cmd"
  if [ -n "$env_dir" ]; then
    [ -f "$env_dir/env.sh" ] && tmux_cmd="source '$env_dir/env.sh' && $tmux_cmd"
    [ -x "$env_dir/setup.sh" ] && tmux_cmd="'$env_dir/setup.sh' && $tmux_cmd"
  fi

  tmux new-session -d -s "$session" "$tmux_cmd"

  log "Dispatched $AGENT_TYPE for $id: $title (env: ${env_dir:-legacy})"
}

# ---------------------------------------------------------------------------
# Resume: existing issue with new human comment
# ---------------------------------------------------------------------------
check_and_resume() {
  local issue="$1" id="$2" state_dir="$3"
  local issue_uuid
  issue_uuid=$(echo "$issue" | jq -r '.id')

  # Need a saved session to resume
  [ -f "$state_dir/session" ] || return 0
  local session_id
  session_id=$(cat "$state_dir/session")
  [ -n "$session_id" ] || return 0

  # Find latest comment NOT from the agent
  local latest_human_comment
  latest_human_comment=$(echo "$issue" | jq -c "
    [.comments.nodes[] | select(.user.id != \"$AGENT_USER_ID\")]
    | sort_by(.createdAt) | last // empty
  ")
  [ -z "$latest_human_comment" ] || [ "$latest_human_comment" = "null" ] && return 0

  local comment_ts
  comment_ts=$(echo "$latest_human_comment" | jq -r '.createdAt // empty')
  [ -n "$comment_ts" ] || return 0

  # Skip if we already processed this comment
  local saved_ts=""
  [ -f "$state_dir/posted_at" ] && saved_ts=$(cat "$state_dir/posted_at")
  if [ -n "$saved_ts" ] && [[ ! "$comment_ts" > "$saved_ts" ]]; then
    return 0
  fi

  local comment_body comment_author
  comment_body=$(echo "$latest_human_comment" | jq -r '.body')
  comment_author=$(echo "$latest_human_comment" | jq -r '.user.displayName')

  # Resolve environment from saved project_id
  local project_id=""
  [ -f "$state_dir/project_id" ] && project_id=$(cat "$state_dir/project_id")
  local env_dir
  env_dir=$(resolve_environment "$project_id")
  local status_in_progress="$STATUS_IN_PROGRESS"
  [ -n "$env_dir" ] && [ -f "$env_dir/config.sh" ] && \
    status_in_progress=$(read_config_var "$env_dir/config.sh" STATUS_IN_PROGRESS)

  # Write resume prompt
  cat > "$state_dir/prompt" <<PROMPT
The team has responded to your work on this task:

New comment from $comment_author:
$comment_body

Continue your work, taking this feedback into account.
If you need more input, clearly state your question.
When finished, provide a summary of what you did.
PROMPT

  # Save issue UUID (might already exist)
  echo "$issue_uuid" > "$state_dir/issue_uuid"

  # Update Linear status
  linear_set_status "$issue_uuid" "$status_in_progress" > /dev/null

  # Resume agent in tmux (no setup.sh on resume, only env.sh)
  local session="linear-${id}"
  local adapter_cmd="'$SCRIPT_DIR/adapters/${AGENT_TYPE}.sh' resume '$state_dir'"

  # Build tmux command with optional env sourcing (no setup on resume)
  local tmux_cmd="$adapter_cmd"
  [ -n "$env_dir" ] && [ -f "$env_dir/env.sh" ] && tmux_cmd="source '$env_dir/env.sh' && $tmux_cmd"

  tmux new-session -d -s "$session" "$tmux_cmd"

  log "Resumed $AGENT_TYPE for $id (new comment from $comment_author)"
}

# ---------------------------------------------------------------------------
# Commands: start, stop, status
# ---------------------------------------------------------------------------
cmd_start() {
  mkdir -p "$STATE_DIR"

  if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    echo "Already running (PID: $(cat "$PID_FILE"))"
    exit 1
  fi

  main_loop &
  local pid=$!
  echo "$pid" > "$PID_FILE"
  echo "Started (PID: $pid). Log: $LOG_FILE"
  echo "Use '$0 stop' to stop, '$0 status' to check agents."
}

cmd_stop() {
  # Kill main loop
  if [ -f "$PID_FILE" ]; then
    local pid
    pid=$(cat "$PID_FILE")
    if kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null
      echo "Stopped main loop (PID: $pid)"
    fi
    rm -f "$PID_FILE"
  else
    echo "Not running"
  fi

  # Kill all agent tmux sessions
  tmux ls 2>/dev/null | grep "^linear-" | cut -d: -f1 | while read -r s; do
    tmux kill-session -t "$s" 2>/dev/null
  done
  echo "Cleaned up tmux sessions"
}

cmd_status() {
  echo "=== Linear Machine ==="
  if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    echo "Loop: running (PID: $(cat "$PID_FILE"))"
  else
    echo "Loop: stopped"
  fi

  echo ""
  echo "=== Environments ==="
  for env_dir in "$SCRIPT_DIR"/environments/*/; do
    [ -f "$env_dir/config.sh" ] || continue
    local name repo
    name=$(basename "$env_dir")
    repo=$(head -1 "$env_dir/repo_path" 2>/dev/null | tr -d '[:space:]' || echo "(no repo_path)")
    echo "  $name → $repo"
  done

  echo ""
  echo "=== Active Agents ==="
  local found=false
  tmux ls 2>/dev/null | grep "^linear-" | while read -r line; do
    found=true
    echo "  $line"
  done
  $found || echo "  (none)"

  echo ""
  echo "=== Tracked Issues ==="
  for state_dir in "$STATE_DIR"/*/; do
    [ -d "$state_dir" ] || continue
    local id
    id=$(basename "$state_dir")
    local title=""
    [ -f "$state_dir/title" ] && title=$(cat "$state_dir/title")
    local has_session=""
    [ -f "$state_dir/session" ] && has_session="(session)"
    local env_info=""
    if [ -f "$state_dir/project_id" ]; then
      local pid env_dir
      pid=$(cat "$state_dir/project_id")
      env_dir=$(resolve_environment "$pid")
      [ -n "$env_dir" ] && env_info="[$(basename "$env_dir")]"
    fi
    echo "  $id: $title $env_info $has_session"
  done
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
case "${1:-status}" in
  start)  cmd_start ;;
  stop)   cmd_stop ;;
  status) cmd_status ;;
  *)      echo "Usage: $0 {start|stop|status}" ;;
esac
