#!/usr/bin/env bash
# linear-machine — polls Linear, dispatches self-managing agents
# Machine.sh is a lightweight supervisor: dispatch + crash recovery + resume on human reply.
# Agents manage their own Linear workflow via bin/linear-tool.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/.env"
source "$SCRIPT_DIR/lib/linear.sh"
source "$SCRIPT_DIR/lib/provider.sh"
source "$SCRIPT_DIR/lib/runner.sh"

PID_FILE="$STATE_DIR/machine.pid"
LOG_FILE="$STATE_DIR/machine.log"

log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG_FILE"; }

# ---------------------------------------------------------------------------
# Environment helpers
# ---------------------------------------------------------------------------

read_config_var() {
  local file="$1" key="$2"
  grep "^${key}=" "$file" 2>/dev/null | cut -d= -f2 || true
}

resolve_environment() {
  local project_id="$1"
  local mapping="$SCRIPT_DIR/environments/mapping.conf"
  [ -z "$project_id" ] || [ ! -f "$mapping" ] && { echo ""; return 0; }
  local env_name
  env_name=$(read_config_var "$mapping" "$project_id")
  local env_dir="$SCRIPT_DIR/environments/${env_name:-default}"
  [ -d "$env_dir" ] && echo "$env_dir" || echo ""
}

env_repo_path() {
  local env_dir="$1"
  [ -n "$env_dir" ] && [ -f "$env_dir/repo_path" ] && {
    head -1 "$env_dir/repo_path" | tr -d '[:space:]'
    return 0
  }
  echo "$REPOS_DIR"
}

# ---------------------------------------------------------------------------
# Workflow state resolution (for crash recovery)
# ---------------------------------------------------------------------------
resolve_state_id() {
  local team_id="$1" target_name="$2" state_dir="$3"
  local cache="$state_dir/workflow_states.json"

  if [ ! -f "$cache" ]; then
    linear_get_workflow_states "$team_id" | jq '.data.workflowStates.nodes' > "$cache"
  fi

  jq -r --arg name "$target_name" \
    '[.[] | select(.name | ascii_downcase == ($name | ascii_downcase))] | .[0].id // empty' \
    "$cache"
}

# ---------------------------------------------------------------------------
# Prompt building
# ---------------------------------------------------------------------------
build_tool_docs() {
  cat <<'TOOLDOCS'
## Linear Tools

You have the `linear-tool` command to manage this issue:

  linear-tool assign              # assign this issue to yourself
  linear-tool status "In Progress"  # update issue status
  linear-tool status "In Review"    # mark ready for review
  linear-tool status "Blocked"      # signal you need input (stops agent)
  linear-tool comment "message"     # post a comment
  linear-tool get-comments          # read recent comments

## Workflow

1. Read the latest human comments and context.
2. Always post a Linear comment reply before implementing any changes.
3. If you start execution, set `linear-tool status "In Progress"`.
4. Keep posting progress updates with `linear-tool comment "..."`
5. When done: `linear-tool comment "summary of changes"` then `linear-tool status "In Review"`
6. If blocked: `linear-tool comment "your question"` then `linear-tool status "Blocked"` and stop.

After setting "Blocked", finish your response immediately. You will be resumed when a human replies.
TOOLDOCS
}

build_prompt() {
  local issue="$1" state_dir="$2" mode="$3"

  if [ "$mode" = "new" ]; then
    local identifier title description state_name
    identifier=$(echo "$issue" | jq -r '.identifier')
    title=$(echo "$issue" | jq -r '.title')
    description=$(echo "$issue" | jq -r '.description // "No description provided."')
    state_name=$(echo "$issue" | jq -r '.state.name')

    # Format recent comments
    local comments=""
    comments=$(echo "$issue" | jq -r '
      [.comments.nodes[] | "\(.user.displayName) (\(.createdAt)): \(.body)"]
      | .[-5:] | .[]
    ' 2>/dev/null || true)

    cat > "$state_dir/prompt" <<PROMPT
# Linear Issue: $identifier
Current Status: $state_name

## Task
Title: $title

Description:
$description

## Recent Comments
${comments:-"(none)"}

---

$(build_tool_docs)
PROMPT

  elif [ "$mode" = "resume" ]; then
    local identifier latest_agent_update new_human_comments
    identifier=$(echo "$issue" | jq -r '.identifier')
    latest_agent_update="$4"
    new_human_comments="$5"

    cat > "$state_dir/prompt" <<PROMPT
# Linear Issue: $identifier (resumed)

## Latest Agent Comment
${latest_agent_update:-"(none found)"}

## New Human Comments (since latest agent comment)
${new_human_comments:-"(none)"}

---

$(build_tool_docs)

Continue working on this issue. The tools above are still available.
PROMPT
  fi
}

# ---------------------------------------------------------------------------
# Agent env file (Linear-specific vars for linear-tool)
# ---------------------------------------------------------------------------
write_agent_env() {
  local issue="$1" state_dir="$2"
  local issue_uuid team_id identifier
  issue_uuid=$(echo "$issue" | jq -r '.id')
  team_id=$(echo "$issue" | jq -r '.team.id')
  identifier=$(echo "$issue" | jq -r '.identifier')

  cat > "$state_dir/env.sh" <<ENV
export LINEAR_API_KEY="$LINEAR_API_KEY"
export LINEAR_ISSUE_ID="$issue_uuid"
export LINEAR_ISSUE_IDENTIFIER="$identifier"
export LINEAR_TEAM_ID="$team_id"
export AGENT_USER_ID="$AGENT_USER_ID"
export LINEAR_STATE_DIR="$state_dir"
ENV
}

resume_comment_bundle() {
  local issue="$1"
  echo "$issue" | jq -r --arg aid "$AGENT_USER_ID" '
    (.comments.nodes // [] | sort_by(.createdAt)) as $all
    | ($all | map(select(.user.id == $aid)) | last) as $last_agent
    | ($last_agent.createdAt // "") as $last_agent_ts
    | ($last_agent.user.displayName // "Agent") as $agent_name
    | ($last_agent.body // "") as $agent_body
    | ($all | map(select(.user.id != $aid and ($last_agent_ts == "" or .createdAt > $last_agent_ts)))) as $new_humans
    | {
        last_agent_ts: $last_agent_ts,
        latest_agent_update: (
          if $last_agent_ts == "" then ""
          else ($agent_name + " (" + $last_agent_ts + "): " + $agent_body)
          end
        ),
        latest_human_ts: (($new_humans | last | .createdAt) // ""),
        new_human_comments: (
          if ($new_humans | length) == 0 then ""
          else ($new_humans | map(.user.displayName + " (" + .createdAt + "): " + .body) | join("\n\n"))
          end
        )
      }
  '
}

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------
main_loop() {
  log "Polling every ${POLL_INTERVAL}s for issues assigned to agent ($AGENT_USER_ID)"
  log "Agent type: $AGENT_TYPE"

  while true; do
    handle_finished_agents
    poll_and_dispatch
    sleep "$POLL_INTERVAL"
  done
}

# ---------------------------------------------------------------------------
# Phase 1: handle finished agents — crash recovery only
# ---------------------------------------------------------------------------
handle_finished_agents() {
  for state_dir in "$STATE_DIR"/*/; do
    [ -d "$state_dir" ] || continue
    local id
    id=$(basename "$state_dir")
    # Skip if agent is still running
    runner_is_running "$id" && continue

    # Skip if not a tracked issue
    [ -f "$state_dir/issue_uuid" ] || continue

    # Skip if already handled (agent_state set)
    [ -f "$state_dir/agent_state" ] && continue

    # Skip if agent never started (no session recorded yet)
    [ -f "$state_dir/session" ] || continue

    local exit_code="0"
    [ -f "$state_dir/exit_code" ] && exit_code=$(cat "$state_dir/exit_code")

    if [ "$exit_code" = "0" ]; then
      # Success — agent handled everything via linear-tool
      echo "done" > "$state_dir/agent_state"
      log "Agent finished for $id (success)"

    elif [ "$exit_code" = "100" ]; then
      # Blocked — agent signaled via linear-tool status "Blocked"
      echo "blocked" > "$state_dir/agent_state"
      log "Agent blocked for $id (waiting for human reply)"

    else
      # Crash — unexpected exit, post error comment
      echo "crashed" > "$state_dir/agent_state"
      local issue_uuid
      issue_uuid=$(cat "$state_dir/issue_uuid")

      local err_snippet=""
      [ -f "$state_dir/agent.err" ] && err_snippet=$(tail -20 "$state_dir/agent.err")

      linear_post_comment "$issue_uuid" \
        "Agent crashed (exit code: $exit_code). Error output:
\`\`\`
${err_snippet:-no error output captured}
\`\`\`" > /dev/null

      # Try to move to Blocked state
      local team_id=""
      [ -f "$state_dir/team_id" ] && team_id=$(cat "$state_dir/team_id")
      if [ -n "$team_id" ]; then
        local blocked_id
        blocked_id=$(resolve_state_id "$team_id" "Blocked" "$state_dir")
        if [ -n "$blocked_id" ]; then
          linear_set_status "$issue_uuid" "$blocked_id" > /dev/null
        fi
      fi

      log "CRASH: agent for $id exited with code $exit_code"
    fi
  done
}

# ---------------------------------------------------------------------------
# Phase 2: poll Linear, dispatch or resume agents
# ---------------------------------------------------------------------------
poll_and_dispatch() {
  local poll_file="$STATE_DIR/poll.json"
  linear_poll_issues > "$poll_file" 2>/dev/null || return 0

  # Also poll @mentions if AGENT_DISPLAY_NAME is set
  local mentions_file="$STATE_DIR/mentions.json"
  if [ -n "${AGENT_DISPLAY_NAME:-}" ]; then
    linear_poll_mentions "$AGENT_DISPLAY_NAME" > "$mentions_file" 2>/dev/null || true
  fi

  # Process assigned issues + mentions, dedup by issue UUID.
  # Dispatch if no session exists. Resume if session exists.
  local seen=""
  while IFS= read -r issue; do
    local issue_uuid id
    issue_uuid=$(echo "$issue" | jq -r '.id')
    id=$(echo "$issue" | jq -r '.identifier' | tr '[:upper:]' '[:lower:]')
    # Dedup: skip if already seen this UUID in this cycle
    case "$seen" in
      *"$issue_uuid"*) continue ;;
    esac
    seen="$seen $issue_uuid"

    # Skip if agent already running
    runner_is_running "$id" && continue

    local state_dir="$STATE_DIR/$id"
    mkdir -p "$state_dir"

    if [ -f "$state_dir/session" ]; then
      check_and_resume "$issue" "$id" "$state_dir"
    else
      dispatch_new "$issue" "$id" "$state_dir"
    fi
  done < <({
    jq -c '.data.issues.nodes // [] | .[]' "$poll_file" 2>/dev/null || true
    if [ -n "${AGENT_DISPLAY_NAME:-}" ] && [ -f "$mentions_file" ]; then
      jq -c '(.data.searchIssues.nodes // .data.issueSearch.nodes // []) | .[]' "$mentions_file" 2>/dev/null || true
    fi
  })
}

# ---------------------------------------------------------------------------
# Dispatch: new issue
# ---------------------------------------------------------------------------
dispatch_new() {
  local issue="$1" id="$2" state_dir="$3"
  local issue_uuid title project_id team_id assignee_id
  issue_uuid=$(echo "$issue" | jq -r '.id')
  title=$(echo "$issue" | jq -r '.title')
  project_id=$(echo "$issue" | jq -r '.project.id // empty')
  team_id=$(echo "$issue" | jq -r '.team.id')
  assignee_id=$(echo "$issue" | jq -r '.assignee.id // empty')

  # Resolve environment
  local env_dir
  env_dir=$(resolve_environment "$project_id")
  local workdir
  workdir=$(env_repo_path "$env_dir")

  # Build prompt + agent env
  write_agent_env "$issue" "$state_dir"
  build_prompt "$issue" "$state_dir" "new"

  # Save issue metadata + workdir (runner reads workdir from state dir)
  echo "$issue_uuid" > "$state_dir/issue_uuid"
  echo "$title" > "$state_dir/title"
  echo "$team_id" > "$state_dir/team_id"
  echo "$workdir" > "$state_dir/workdir"
  echo "$assignee_id" > "$state_dir/last_assignee"
  [ -n "$project_id" ] && echo "$project_id" > "$state_dir/project_id"

  runner_start "$id" "$state_dir" "$env_dir" "$AGENT_TYPE" "start"

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

  # Collect all new human comments after the latest agent comment.
  local bundle latest_human_ts latest_agent_update new_human_comments
  bundle=$(resume_comment_bundle "$issue")
  latest_human_ts=$(echo "$bundle" | jq -r '.latest_human_ts // empty')
  latest_agent_update=$(echo "$bundle" | jq -r '.latest_agent_update // empty')
  new_human_comments=$(echo "$bundle" | jq -r '.new_human_comments // empty')

  # Re-assignment can also trigger resume even with no new comments.
  local current_assignee last_assignee assigned_trigger=0
  current_assignee=$(echo "$issue" | jq -r '.assignee.id // empty')
  [ -f "$state_dir/last_assignee" ] && last_assignee=$(cat "$state_dir/last_assignee") || last_assignee=""
  if [ "$current_assignee" = "$AGENT_USER_ID" ] && [ "$last_assignee" != "$AGENT_USER_ID" ]; then
    assigned_trigger=1
  fi

  [ -n "$latest_human_ts" ] || [ "$assigned_trigger" -eq 1 ] || return 0

  # Skip if we already processed this comment
  local saved_ts=""
  [ -f "$state_dir/posted_at" ] && saved_ts=$(cat "$state_dir/posted_at")
  if [ "$assigned_trigger" -eq 0 ] && [ -n "$saved_ts" ] && ! [ "$latest_human_ts" \> "$saved_ts" ]; then
    return 0
  fi

  # Resolve environment from saved project_id
  local project_id=""
  [ -f "$state_dir/project_id" ] && project_id=$(cat "$state_dir/project_id")
  local env_dir
  env_dir=$(resolve_environment "$project_id")

  # Refresh agent env + build resume prompt
  write_agent_env "$issue" "$state_dir"
  build_prompt "$issue" "$state_dir" "resume" "$latest_agent_update" "$new_human_comments"

  # Save issue UUID (might already exist)
  echo "$issue_uuid" > "$state_dir/issue_uuid"
  echo "$current_assignee" > "$state_dir/last_assignee"

  # Record latest human comment timestamp so we don't re-process.
  if [ -n "$latest_human_ts" ]; then
    echo "$latest_human_ts" > "$state_dir/posted_at"
  fi

  # Clear previous agent state for fresh resume
  rm -f "$state_dir/exit_code" "$state_dir/agent_state"

  runner_start "$id" "$state_dir" "$env_dir" "$AGENT_TYPE" "resume"

  log "Resumed $AGENT_TYPE for $id (new human comments detected)"
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

  # Launch detached so loop survives shell/session exits.
  nohup "$SCRIPT_DIR/machine.sh" run-loop > /dev/null 2>&1 &
  local pid=$!
  echo "$pid" > "$PID_FILE"
  echo "Started (PID: $pid). Log: $LOG_FILE"
  echo "Use '$0 stop' to stop, '$0 status' to check agents."
}

cmd_stop() {
  local confirm_flag="${1:-}"
  if [ "$confirm_flag" != "--yes" ]; then
    echo "WARNING: Stopping linear-machine ends all active agent sessions."
    echo "If resumed later, agents get Linear comment history but lose prior session memory/context."
    if [ -t 0 ]; then
      local ans
      read -r -p "Type 'stop' to confirm, anything else to cancel: " ans
      if [ "$ans" != "stop" ]; then
        echo "Stop cancelled."
        return 1
      fi
    else
      echo "Non-interactive shell: re-run with '$0 stop --yes' to confirm."
      return 1
    fi
  fi

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

  runner_stop_all
  echo "Cleaned up agent sessions"
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
    [ -d "$env_dir" ] || continue
    local name repo
    name=$(basename "$env_dir")
    repo=$(head -1 "$env_dir/repo_path" 2>/dev/null | tr -d '[:space:]' || echo "(no repo_path)")
    echo "  $name → $repo"
  done

  echo ""
  echo "=== Active Agents ($RUNNER_TYPE) ==="
  local agents
  agents=$(runner_list)
  if [ -n "$agents" ]; then
    echo "$agents" | while read -r line; do echo "  $line"; done
  else
    echo "  (none)"
  fi

  echo ""
  echo "=== Tracked Issues ==="
  for state_dir in "$STATE_DIR"/*/; do
    [ -d "$state_dir" ] || continue
    local id
    id=$(basename "$state_dir")
    local title=""
    [ -f "$state_dir/title" ] && title=$(cat "$state_dir/title")
    local agent_state=""
    [ -f "$state_dir/agent_state" ] && agent_state="[$(cat "$state_dir/agent_state")]"
    local env_info=""
    if [ -f "$state_dir/project_id" ]; then
      local pid env_dir
      pid=$(cat "$state_dir/project_id")
      env_dir=$(resolve_environment "$pid")
      [ -n "$env_dir" ] && env_info="[$(basename "$env_dir")]"
    fi
    echo "  $id: $title $env_info $agent_state"
  done
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
case "${1:-status}" in
  start)   cmd_start ;;
  stop)    cmd_stop "${2:-}" ;;
  run-loop) main_loop ;;
  status) cmd_status ;;
  *)       echo "Usage: $0 {start|stop [--yes]|status}" ;;
esac
