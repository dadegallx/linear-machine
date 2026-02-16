#!/usr/bin/env bash
# linear-machine — webhook-first supervisor with durable queue + issue session state
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/.env"
source "$SCRIPT_DIR/lib/linear.sh"
source "$SCRIPT_DIR/lib/provider.sh"
source "$SCRIPT_DIR/lib/runner.sh"

PID_FILE="$STATE_DIR/machine.pid"
LISTENER_PID_FILE="$STATE_DIR/listener.pid"
LOG_FILE="$STATE_DIR/machine.log"

STATE_DB="${STATE_DB:-$STATE_DIR/state.db}"
WORKER_ID="${WORKER_ID:-$(hostname)-$$}"
WORKER_SLEEP_SECONDS="${WORKER_SLEEP_SECONDS:-2}"
WORKER_BATCH_SIZE="${WORKER_BATCH_SIZE:-10}"
LOCK_LEASE_SECONDS="${LOCK_LEASE_SECONDS:-900}"
MAX_RETRIES="${MAX_RETRIES:-5}"
RETRY_BACKOFF_SECONDS="${RETRY_BACKOFF_SECONDS:-60}"
RECONCILER_INTERVAL="${RECONCILER_INTERVAL:-300}"
ENABLE_RECONCILER="${ENABLE_RECONCILER:-1}"

WEBHOOK_HOST="${WEBHOOK_HOST:-0.0.0.0}"
WEBHOOK_PORT="${WEBHOOK_PORT:-8787}"
WEBHOOK_PATH="${WEBHOOK_PATH:-/webhooks/linear}"
WEBHOOK_MAX_AGE_SECONDS="${WEBHOOK_MAX_AGE_SECONDS:-300}"
WEBHOOK_SECRET="${LINEAR_WEBHOOK_SECRET:-${WEBHOOK_SECRET:-}}"

log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG_FILE"; }

log_event() {
  local issue_id="$1" event_id="$2" action="$3" result="$4" duration_ms="$5" message="$6"
  log "issue_id=${issue_id:-none} event_id=${event_id:-none} action=$action result=$result duration_ms=${duration_ms:-0} msg=${message:-none}"
  store timeline-add --event-id "${event_id:-}" --issue-id "${issue_id:-}" \
    --action "$action" --result "$result" --duration-ms "${duration_ms:-0}" --message "${message:-}" >/dev/null || true
}

store() {
  "$SCRIPT_DIR/bin/state-store" --db "$STATE_DB" "$@"
}

store_init() {
  mkdir -p "$STATE_DIR"
  store init >/dev/null
}

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

is_project_tracked() {
  local project_id="$1"
  local mapping="$SCRIPT_DIR/environments/mapping.conf"
  [ -z "$project_id" ] && return 1
  [ ! -f "$mapping" ] && return 0
  [ -n "$(read_config_var "$mapping" "$project_id")" ]
}

env_repo_path() {
  local env_dir="$1"
  [ -n "$env_dir" ] && [ -f "$env_dir/repo_path" ] && {
    head -1 "$env_dir/repo_path" | tr -d '[:space:]'
    return 0
  }
  echo "$REPOS_DIR"
}

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

build_tool_docs() {
  cat <<'TOOLDOCS'
## Linear Tools

You have the `linear-tool` command to manage this issue:

  linear-tool assign                # assign this issue to yourself
  linear-tool status "In Progress"   # update issue status
  linear-tool status "In Review"     # mark ready for review
  linear-tool status "Blocked"       # signal you need input (stops agent)
  linear-tool comment "message"      # post a comment
  linear-tool get-comments           # read recent comments

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
    local identifier title description state_name comments
    identifier=$(echo "$issue" | jq -r '.identifier')
    title=$(echo "$issue" | jq -r '.title')
    description=$(echo "$issue" | jq -r '.description // "No description provided."')
    state_name=$(echo "$issue" | jq -r '.state.name')
    comments=$(echo "$issue" | jq -r '
      [.comments.nodes[] | "\(.user.displayName) (\(.createdAt)): \(.body)"] | .[-10:] | .[]
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
  else
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
        latest_agent_update: (
          if $last_agent_ts == "" then ""
          else ($agent_name + " (" + $last_agent_ts + "): " + $agent_body)
          end
        ),
        latest_human_ts: (($new_humans | last | .createdAt) // ""),
        latest_human_comment_id: (($new_humans | last | .id) // ""),
        new_human_comments: (
          if ($new_humans | length) == 0 then ""
          else ($new_humans | map(.user.displayName + " (" + .createdAt + "): " + .body) | join("\n\n"))
          end
        )
      }
  '
}

id_from_identifier() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-+/-/g'
}

safe_delete_dir() {
  local dir="$1"
  [ -d "$dir" ] || return 0
  if command -v trash >/dev/null 2>&1; then
    trash "$dir"
  else
    rm -rf "$dir"
  fi
}

start_listener() {
  [ -n "$WEBHOOK_SECRET" ] || {
    echo "Missing LINEAR_WEBHOOK_SECRET/WEBHOOK_SECRET for webhook listener" >&2
    exit 1
  }
  if [ -f "$LISTENER_PID_FILE" ] && kill -0 "$(cat "$LISTENER_PID_FILE")" 2>/dev/null; then
    return 0
  fi

  nohup "$SCRIPT_DIR/bin/linear-webhook-listener" \
    --host "$WEBHOOK_HOST" \
    --port "$WEBHOOK_PORT" \
    --path "$WEBHOOK_PATH" \
    --db "$STATE_DB" \
    --webhook-secret "$WEBHOOK_SECRET" \
    --agent-name "${AGENT_DISPLAY_NAME:-francis}" \
    --max-age-seconds "$WEBHOOK_MAX_AGE_SECONDS" \
    >> "$LOG_FILE" 2>&1 &
  echo "$!" > "$LISTENER_PID_FILE"
  log "Listener started pid=$(cat "$LISTENER_PID_FILE") path=$WEBHOOK_PATH"
}

stop_listener() {
  if [ -f "$LISTENER_PID_FILE" ]; then
    local lpid
    lpid=$(cat "$LISTENER_PID_FILE")
    if kill -0 "$lpid" 2>/dev/null; then
      kill "$lpid" 2>/dev/null || true
    fi
    rm -f "$LISTENER_PID_FILE"
  fi
}

sync_session_runtime_cache() {
  local issue_id="$1" state_dir="$2"
  local fields
  fields=$(jq -nc \
    --arg sid "$(cat "$state_dir/session" 2>/dev/null || true)" \
    --arg vm "$(cat "$state_dir/vm_name" 2>/dev/null || true)" \
    --arg ssh "$(cat "$state_dir/ssh_dest" 2>/dev/null || true)" \
    --arg st "$state_dir" \
    '{active_session_id:$sid,vm_name:$vm,ssh_dest:$ssh,state_dir:$st}')
  store upsert-session --issue-id "$issue_id" --fields "$fields" >/dev/null
}

handle_finished_agents() {
  local state_dir
  for state_dir in "$STATE_DIR"/*/; do
    [ -d "$state_dir" ] || continue
    [ -f "$state_dir/issue_uuid" ] || continue
    local id issue_uuid
    id=$(basename "$state_dir")
    issue_uuid=$(cat "$state_dir/issue_uuid")

    if runner_is_running "$id"; then
      sync_session_runtime_cache "$issue_uuid" "$state_dir"
      continue
    fi

    [ -f "$state_dir/session" ] || continue
    [ -f "$state_dir/agent_state" ] && continue

    local exit_code="0"
    [ -f "$state_dir/exit_code" ] && exit_code=$(cat "$state_dir/exit_code")

    if [ "$exit_code" = "0" ]; then
      echo "done" > "$state_dir/agent_state"
      store upsert-session --issue-id "$issue_uuid" \
        --fields '{"status":"done"}' >/dev/null
      log "Agent finished for $id"
    elif [ "$exit_code" = "100" ]; then
      echo "blocked" > "$state_dir/agent_state"
      store upsert-session --issue-id "$issue_uuid" \
        --fields '{"status":"blocked"}' >/dev/null
      log "Agent blocked for $id"
    else
      echo "crashed" > "$state_dir/agent_state"
      local err_snippet=""
      [ -f "$state_dir/agent.err" ] && err_snippet=$(tail -20 "$state_dir/agent.err")
      linear_post_comment "$issue_uuid" "Agent crashed (exit code: $exit_code). Error output:
\`\`\`
${err_snippet:-no error output captured}
\`\`\`" > /dev/null || true

      local team_id=""
      [ -f "$state_dir/team_id" ] && team_id=$(cat "$state_dir/team_id")
      if [ -n "$team_id" ]; then
        local blocked_id
        blocked_id=$(resolve_state_id "$team_id" "Blocked" "$state_dir")
        [ -n "$blocked_id" ] && linear_set_status "$issue_uuid" "$blocked_id" > /dev/null || true
      fi
      store upsert-session --issue-id "$issue_uuid" \
        --fields "$(jq -nc --arg err "exit code $exit_code" '{status:"blocked",last_error:$err}')" >/dev/null
      log "CRASH: agent for $id exited with code $exit_code"
    fi

    sync_session_runtime_cache "$issue_uuid" "$state_dir"
  done
}

fetch_issue_context() {
  local issue_id="$1"
  linear_get_issue_context "$issue_id" | jq -c '.data.issue // empty'
}

should_trigger_for_event() {
  local event_json="$1" issue_json="$2"
  local event_type actor_id assignee_id mention issue_assignee state_type state_name
  event_type=$(echo "$event_json" | jq -r '.event_type // ""' | tr '[:upper:]' '[:lower:]')
  actor_id=$(echo "$event_json" | jq -r '.actor_id // ""')
  assignee_id=$(echo "$event_json" | jq -r '.assignee_id // ""')
  mention=$(echo "$event_json" | jq -r '
    if .contains_mention == true or .contains_mention == 1 or .contains_mention == "1" or .contains_mention == "true"
    then "true"
    else "false"
    end
  ')
  issue_assignee=$(echo "$issue_json" | jq -r '.assignee.id // ""')
  state_type=$(echo "$issue_json" | jq -r '.state.type // ""' | tr '[:upper:]' '[:lower:]')
  state_name=$(echo "$issue_json" | jq -r '.state.name // ""' | tr '[:upper:]' '[:lower:]')

  case "$state_type" in completed|canceled) return 1 ;; esac
  case "$state_name" in done|canceled|cancelled) return 1 ;; esac
  [ "$actor_id" = "$AGENT_USER_ID" ] && return 1

  if [[ "$event_type" == "comment.create" ]] && [ "$mention" = "true" ]; then
    return 0
  fi
  if [[ "$event_type" == "issue.update" ]] && [ "$assignee_id" = "$AGENT_USER_ID" ]; then
    return 0
  fi
  if [[ "$event_type" == "issue.assignment.synthetic" ]] && [ "$issue_assignee" = "$AGENT_USER_ID" ]; then
    return 0
  fi

  return 1
}

dispatch_new() {
  local issue="$1" id="$2" state_dir="$3" issue_id="$4" event_id="$5"
  local issue_uuid title project_id team_id assignee_id env_dir workdir
  issue_uuid=$(echo "$issue" | jq -r '.id')
  title=$(echo "$issue" | jq -r '.title')
  project_id=$(echo "$issue" | jq -r '.project.id // empty')
  team_id=$(echo "$issue" | jq -r '.team.id // empty')
  assignee_id=$(echo "$issue" | jq -r '.assignee.id // empty')

  env_dir=$(resolve_environment "$project_id")
  workdir=$(env_repo_path "$env_dir")

  mkdir -p "$state_dir"
  write_agent_env "$issue" "$state_dir"
  build_prompt "$issue" "$state_dir" "new"
  echo "$issue_uuid" > "$state_dir/issue_uuid"
  echo "$title" > "$state_dir/title"
  echo "$team_id" > "$state_dir/team_id"
  echo "$project_id" > "$state_dir/project_id"
  echo "$workdir" > "$state_dir/workdir"
  echo "$assignee_id" > "$state_dir/last_assignee"

  local fields
  fields=$(jq -nc \
    --arg ident "$(echo "$issue" | jq -r '.identifier')" \
    --arg status "running" \
    --arg aid "$assignee_id" \
    --arg pid "$project_id" \
    --arg tid "$team_id" \
    --arg st "$state_dir" \
    --arg ev "$event_id" \
    '{issue_identifier:$ident,status:$status,last_assignee_id:$aid,project_id:$pid,team_id:$tid,state_dir:$st,last_event_id:$ev}')
  store upsert-session --issue-id "$issue_id" --fields "$fields" >/dev/null

  rm -f "$state_dir/exit_code" "$state_dir/agent_state"

  local rc=0
  set +e
  runner_start "$id" "$state_dir" "$env_dir" "$AGENT_TYPE" "start"
  rc=$?
  set -e

  if [ "$rc" -eq 0 ]; then
    sync_session_runtime_cache "$issue_id" "$state_dir"
    return 0
  fi
  return 1
}

resume_issue() {
  local issue="$1" id="$2" state_dir="$3" issue_id="$4" event_id="$5" forced_comment_id="$6"
  local project_id current_assignee env_dir bundle latest_agent_update new_human_comments latest_human_ts latest_human_comment_id

  project_id=$(echo "$issue" | jq -r '.project.id // empty')
  current_assignee=$(echo "$issue" | jq -r '.assignee.id // empty')
  env_dir=$(resolve_environment "$project_id")

  bundle=$(resume_comment_bundle "$issue")
  latest_agent_update=$(echo "$bundle" | jq -r '.latest_agent_update // empty')
  new_human_comments=$(echo "$bundle" | jq -r '.new_human_comments // empty')
  latest_human_ts=$(echo "$bundle" | jq -r '.latest_human_ts // empty')
  latest_human_comment_id=$(echo "$bundle" | jq -r '.latest_human_comment_id // empty')

  if [ -z "$new_human_comments" ] && [ -n "$forced_comment_id" ]; then
    # Session exists but no incremental bundle (cold cache). Fall back to full recent context.
    build_prompt "$issue" "$state_dir" "new"
  else
    build_prompt "$issue" "$state_dir" "resume" "$latest_agent_update" "$new_human_comments"
  fi

  write_agent_env "$issue" "$state_dir"
  echo "$current_assignee" > "$state_dir/last_assignee"
  [ -n "$latest_human_ts" ] && echo "$latest_human_ts" > "$state_dir/posted_at"
  rm -f "$state_dir/exit_code" "$state_dir/agent_state"

  local fields
  fields=$(jq -nc \
    --arg status "running" \
    --arg aid "$current_assignee" \
    --arg pid "$project_id" \
    --arg ev "$event_id" \
    --arg cid "${latest_human_comment_id:-$forced_comment_id}" \
    --arg hts "$latest_human_ts" \
    '{status:$status,last_assignee_id:$aid,project_id:$pid,last_event_id:$ev,last_processed_comment_id:$cid,last_human_comment_ts:$hts}')
  store upsert-session --issue-id "$issue_id" --fields "$fields" >/dev/null

  local rc=0
  set +e
  runner_start "$id" "$state_dir" "$env_dir" "$AGENT_TYPE" "resume"
  rc=$?
  set -e

  if [ "$rc" -eq 0 ]; then
    sync_session_runtime_cache "$issue_id" "$state_dir"
    return 0
  fi
  return 1
}

process_single_event() {
  local event_json="$1"
  local started_ms now_ms duration_ms
  started_ms=$(python3 -c 'import time; print(int(time.time()*1000))')

  local event_id issue_id
  event_id=$(echo "$event_json" | jq -r '.event_id')
  issue_id=$(echo "$event_json" | jq -r '.issue_id // empty')
  [ -n "$issue_id" ] || {
    store mark-done --event-id "$event_id" >/dev/null
    return 0
  }

  local lock
  lock=$(store acquire-lock --issue-id "$issue_id" --owner "$WORKER_ID" --lease-sec "$LOCK_LEASE_SECONDS")
  if [ "$(echo "$lock" | jq -r '.acquired')" != "true" ]; then
    store mark-failed --event-id "$event_id" --error "issue lock busy" --retry --backoff-sec 20 >/dev/null
    return 0
  fi

  local rc=0 err="" done_now=0
  local issue
  issue=$(fetch_issue_context "$issue_id")
  if [ -z "$issue" ]; then
    rc=1
    err="issue_not_found"
  fi

  if [ "$rc" -eq 0 ]; then
    local project_id
    project_id=$(echo "$issue" | jq -r '.project.id // empty')
    if ! is_project_tracked "$project_id"; then
      log_event "$issue_id" "$event_id" "skip" "untracked_project" 0 "project not in mapping"
      store mark-done --event-id "$event_id" >/dev/null
      done_now=1
    fi
  fi

  if [ "$rc" -eq 0 ] && [ "$done_now" -eq 0 ]; then
    if ! should_trigger_for_event "$event_json" "$issue"; then
      log_event "$issue_id" "$event_id" "skip" "not_triggered" 0 "event did not meet deterministic trigger rules"
      store mark-done --event-id "$event_id" >/dev/null
      done_now=1
    fi
  fi

  if [ "$rc" -eq 0 ] && [ "$done_now" -eq 0 ]; then
    local identifier id state_dir
    identifier=$(echo "$issue" | jq -r '.identifier')
    id=$(id_from_identifier "$identifier")
    state_dir="$STATE_DIR/$id"

    if runner_is_running "$id"; then
      log_event "$issue_id" "$event_id" "skip" "already_running" 0 "runner already active for issue"
      store mark-done --event-id "$event_id" >/dev/null
      done_now=1
    else
      local active_session
      active_session=$(store get-session --issue-id "$issue_id" | jq -r '.active_session_id // empty')
      if [ -n "$active_session" ] || [ -f "$state_dir/session" ]; then
        local forced_comment_id
        forced_comment_id=$(echo "$event_json" | jq -r '.comment_id // empty')
        if ! resume_issue "$issue" "$id" "$state_dir" "$issue_id" "$event_id" "$forced_comment_id"; then
          rc=1
          err="resume_failed"
        else
          log_event "$issue_id" "$event_id" "resume" "ok" 0 "agent resumed"
        fi
      else
        if ! dispatch_new "$issue" "$id" "$state_dir" "$issue_id" "$event_id"; then
          rc=1
          err="dispatch_failed"
        else
          log_event "$issue_id" "$event_id" "dispatch" "ok" 0 "agent dispatched"
        fi
      fi
    fi
  fi

  if [ "$rc" -eq 0 ] && [ "$done_now" -eq 0 ]; then
    store mark-done --event-id "$event_id" >/dev/null
  fi

  if [ "$rc" -ne 0 ]; then
    local retries
    retries=$(echo "$event_json" | jq -r '.retry_count // 0')
    if [ "$retries" -lt "$MAX_RETRIES" ]; then
      store mark-failed --event-id "$event_id" --error "${err:-worker_error}" --retry --backoff-sec "$RETRY_BACKOFF_SECONDS" >/dev/null
      log_event "$issue_id" "$event_id" "process" "retry" 0 "${err:-worker_error}"
    else
      store mark-failed --event-id "$event_id" --error "${err:-worker_error}" >/dev/null
      log_event "$issue_id" "$event_id" "process" "failed" 0 "${err:-worker_error}"
    fi
  fi

  store release-lock --issue-id "$issue_id" --owner "$WORKER_ID" >/dev/null || true
  now_ms=$(python3 -c 'import time; print(int(time.time()*1000))')
  duration_ms=$((now_ms - started_ms))
  log_event "$issue_id" "$event_id" "process" "done" "$duration_ms" "worker cycle complete"
}

process_event_queue() {
  local n=0
  while [ "$n" -lt "$WORKER_BATCH_SIZE" ]; do
    local claimed
    claimed=$(store claim-next --worker-id "$WORKER_ID")
    if [ "$(echo "$claimed" | jq -r '.claimed')" != "true" ]; then
      break
    fi
    process_single_event "$claimed"
    n=$((n + 1))
  done
}

enqueue_synthetic_assignment() {
  local issue="$1"
  local issue_id identifier assignee_id event_json event_id
  issue_id=$(echo "$issue" | jq -r '.id')
  identifier=$(echo "$issue" | jq -r '.identifier // ""')
  assignee_id=$(echo "$issue" | jq -r '.assignee.id // ""')
  event_id="reconcile-assign-${issue_id}-$(date -u +%Y%m%d%H%M)"
  event_json=$(jq -nc \
    --arg event_id "$event_id" \
    --arg issue_id "$issue_id" \
    --arg ident "$identifier" \
    --arg assignee "$assignee_id" \
    '{event_id:$event_id,source:"reconciler",event_type:"issue.assignment.synthetic",issue_id:$issue_id,issue_identifier:$ident,assignee_id:$assignee,contains_mention:false,payload:{}}')
  local res
  res=$(store enqueue --event "$event_json")
  if [ "$(echo "$res" | jq -r '.duplicate // false')" = "true" ]; then
    log_event "$issue_id" "$event_id" "enqueue" "duplicate" 0 "reconciler assignment dedupe"
  fi
}

enqueue_synthetic_mentions() {
  local issue="$1"
  local issue_id identifier
  issue_id=$(echo "$issue" | jq -r '.id')
  identifier=$(echo "$issue" | jq -r '.identifier // ""')

  while IFS= read -r c; do
    [ -n "$c" ] || continue
    local comment_id actor_id body
    comment_id=$(echo "$c" | jq -r '.id // ""')
    actor_id=$(echo "$c" | jq -r '.user.id // ""')
    body=$(echo "$c" | jq -r '.body // ""')
    [ "$actor_id" = "$AGENT_USER_ID" ] && continue
    echo "$body" | jq -Rr --arg name "${AGENT_DISPLAY_NAME:-francis}" 'ascii_downcase | contains("@" + ($name | ascii_downcase))' | grep -q true || continue

    local event_json event_id res
    event_id="reconcile-comment-${comment_id}"
    event_json=$(jq -nc \
      --arg event_id "$event_id" \
      --arg issue_id "$issue_id" \
      --arg ident "$identifier" \
      --arg comment_id "$comment_id" \
      --arg actor_id "$actor_id" \
      --arg body "$body" \
      '{event_id:$event_id,source:"reconciler",event_type:"comment.create",issue_id:$issue_id,issue_identifier:$ident,comment_id:$comment_id,actor_id:$actor_id,contains_mention:true,mention_text:$body,payload:{}}')
    res=$(store enqueue --event "$event_json")
    if [ "$(echo "$res" | jq -r '.duplicate // false')" = "true" ]; then
      log_event "$issue_id" "$event_id" "enqueue" "duplicate" 0 "reconciler mention dedupe"
    fi
  done < <(echo "$issue" | jq -c '.comments.nodes[]?')
}

run_reconciler_once() {
  local poll_file="$STATE_DIR/reconciler-assigned.json"
  linear_poll_issues > "$poll_file" 2>/dev/null || return 0

  while IFS= read -r issue; do
    local state_type state_name project_id assignee_id
    state_type=$(echo "$issue" | jq -r '.state.type // ""' | tr '[:upper:]' '[:lower:]')
    state_name=$(echo "$issue" | jq -r '.state.name // ""' | tr '[:upper:]' '[:lower:]')
    project_id=$(echo "$issue" | jq -r '.project.id // ""')
    assignee_id=$(echo "$issue" | jq -r '.assignee.id // ""')
    case "$state_type" in completed|canceled) continue ;; esac
    case "$state_name" in done|canceled|cancelled) continue ;; esac
    is_project_tracked "$project_id" || continue
    [ "$assignee_id" = "$AGENT_USER_ID" ] && enqueue_synthetic_assignment "$issue"
  done < <(jq -c '.data.issues.nodes // [] | .[]' "$poll_file" 2>/dev/null || true)

  if [ -n "${AGENT_DISPLAY_NAME:-}" ]; then
    local mentions_file="$STATE_DIR/reconciler-mentions.json"
    linear_poll_mentions "$(echo "$AGENT_DISPLAY_NAME" | tr '[:upper:]' '[:lower:]')" > "$mentions_file" 2>/dev/null || true
    while IFS= read -r issue; do
      local project_id
      project_id=$(echo "$issue" | jq -r '.project.id // ""')
      is_project_tracked "$project_id" || continue
      enqueue_synthetic_mentions "$issue"
    done < <(jq -c '(.data.searchIssues.nodes // .data.issueSearch.nodes // []) | .[]' "$mentions_file" 2>/dev/null || true)
  fi
}

run_reconciler_if_due() {
  [ "$ENABLE_RECONCILER" = "1" ] || return 0
  local marker="$STATE_DIR/reconciler.last"
  local now last
  now=$(date +%s)
  last=0
  [ -f "$marker" ] && last=$(cat "$marker")
  if [ $((now - last)) -lt "$RECONCILER_INTERVAL" ]; then
    return 0
  fi
  echo "$now" > "$marker"
  run_reconciler_once
}

main_loop() {
  log "Machine loop start: webhook-first + durable queue"
  start_listener

  trap 'stop_listener' EXIT INT TERM

  while true; do
    handle_finished_agents
    process_event_queue
    run_reconciler_if_due
    sleep "$WORKER_SLEEP_SECONDS"
  done
}

cmd_start() {
  store_init

  if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    echo "Already running (PID: $(cat "$PID_FILE"))"
    exit 1
  fi

  nohup "$SCRIPT_DIR/machine.sh" run-loop > /dev/null 2>&1 &
  local pid=$!
  echo "$pid" > "$PID_FILE"
  echo "Started (PID: $pid). Log: $LOG_FILE"
  echo "Webhook endpoint: http://$WEBHOOK_HOST:$WEBHOOK_PORT$WEBHOOK_PATH"
}

cmd_stop() {
  if [ -f "$PID_FILE" ]; then
    local pid
    pid=$(cat "$PID_FILE")
    if kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      echo "Stopped machine worker (PID: $pid)"
    fi
    rm -f "$PID_FILE"
  else
    echo "Not running"
  fi

  stop_listener
}

cmd_cleanup_issues() {
  store_init
  while IFS= read -r sess; do
    [ -n "$sess" ] || continue
    local issue_id state_dir id
    issue_id=$(echo "$sess" | jq -r '.issue_id')
    state_dir=$(echo "$sess" | jq -r '.state_dir // ""')
    [ -n "$state_dir" ] || continue
    id=$(basename "$state_dir")
    runner_stop "$id" || true
    safe_delete_dir "$state_dir"
    store upsert-session --issue-id "$issue_id" --fields '{"status":"idle","active_session_id":"","vm_name":"","ssh_dest":""}' >/dev/null
  done < <(store list-sessions | jq -c '.sessions[]?')
  echo "Issue cleanup complete."
}

cmd_status() {
  store_init

  echo "=== Linear Machine ==="
  if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    echo "Worker: running (PID: $(cat "$PID_FILE"))"
  else
    echo "Worker: stopped"
  fi

  if [ -f "$LISTENER_PID_FILE" ] && kill -0 "$(cat "$LISTENER_PID_FILE")" 2>/dev/null; then
    echo "Listener: running (PID: $(cat "$LISTENER_PID_FILE")) http://$WEBHOOK_HOST:$WEBHOOK_PORT$WEBHOOK_PATH"
  else
    echo "Listener: stopped"
  fi

  echo ""
  echo "=== Queue ==="
  store queue-stats | jq -r '
    "pending=\(.pending) processing=\(.processing) done=\(.done) failed=\(.failed) depth=\(.pending + .processing) dedupe_drops=\(.dedupe_drops) total=\(.total)",
    "events_received_per_sec=\(.events_received_per_sec) dispatch_success=\(.dispatch_success) dispatch_fail=\(.dispatch_fail) comment_to_dispatch_latency_ms_avg=\(.comment_to_dispatch_latency_ms_avg // "n/a")"
  '

  echo ""
  echo "=== Per-Issue Sessions ==="
  local sessions
  sessions=$(store list-sessions)
  echo "$sessions" | jq -r '.sessions[]? | "\(.issue_identifier // .issue_id) issue_id=\(.issue_id) status=\(.status) session=\(.active_session_id // "") vm=\(.vm_name // "")"'

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
  echo "=== Orphaned Issue VMs ==="
  local tracked_ids orphaned=0
  tracked_ids=$(echo "$sessions" | jq -r '.sessions[]?.state_dir // empty | split("/") | last')
  if [ -n "$agents" ]; then
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      local id
      id=$(echo "$line" | cut -d: -f1)
      case $'\n'"$tracked_ids"$'\n' in
        *$'\n'"$id"$'\n'*) ;;
        *)
        echo "  $line"
        orphaned=1
        ;;
      esac
    done <<< "$agents"
  fi
  if [ "$orphaned" -eq 0 ]; then
    echo "  (none)"
  fi
}

cmd_debug_issue() {
  local issue_ref="${1:-}"
  [ -n "$issue_ref" ] || { echo "Usage: $0 debug issue <issue-id-or-identifier>"; return 1; }

  local issue_id="$issue_ref"
  if [[ "$issue_ref" =~ [A-Za-z] ]]; then
    local matched
    matched=$(store list-sessions | jq -r --arg ref "$issue_ref" '
      .sessions[] | select((.issue_identifier // "") == $ref) | .issue_id
    ' | head -1)
    [ -n "$matched" ] && issue_id="$matched"
  fi

  echo "=== Session ==="
  store get-session --issue-id "$issue_id" | jq .
  echo ""
  echo "=== Timeline ==="
  store timeline-issue --issue-id "$issue_id" --limit 100 | jq .
}

case "${1:-status}" in
  start) cmd_start ;;
  stop) cmd_stop ;;
  run-loop) main_loop ;;
  status) cmd_status ;;
  cleanup)
    if [ "${2:-}" = "--issues" ]; then
      cmd_cleanup_issues
    else
      echo "Usage: $0 cleanup --issues"
      exit 1
    fi
    ;;
  debug)
    if [ "${2:-}" = "issue" ]; then
      cmd_debug_issue "${3:-}"
    else
      echo "Usage: $0 debug issue <issue-id-or-identifier>"
      exit 1
    fi
    ;;
  run-reconciler) run_reconciler_once ;;
  *) echo "Usage: $0 {start|stop|status|cleanup --issues|debug issue <id>|run-reconciler}" ;;
esac
