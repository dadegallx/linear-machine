#!/usr/bin/env bash
# Codex adapter — wraps codex exec / codex exec resume
# Contract: writes session, output, exit_code to STATE_DIR
set -euo pipefail

cmd="${1:?Usage: codex.sh start|resume STATE_DIR [WORKDIR]}"
state_dir="${2:?Missing STATE_DIR}"

# Make linear-tool available to the agent
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$SCRIPT_DIR/bin:$PATH"

# Source Linear env vars (for linear-tool)
[ -f "$state_dir/env.sh" ] && source "$state_dir/env.sh"

case "$cmd" in
  start)
    workdir="${3:?Missing WORKDIR}"
    prompt=$(cat "$state_dir/prompt")

    codex exec --json --skip-git-repo-check \
      --dangerously-bypass-approvals-and-sandbox \
      -C "$workdir" \
      "$prompt" \
      > "$state_dir/raw.jsonl" 2>"$state_dir/agent.err" || true

    # Extract thread ID (session)
    jq -r 'select(.type=="thread.started") | .thread_id' "$state_dir/raw.jsonl" \
      | head -1 > "$state_dir/session"

    # Extract last agent message as the output
    jq -r 'select(.type=="item.completed" and .item.type=="agent_message") | .item.text' \
      "$state_dir/raw.jsonl" | awk 'NF' > "$state_dir/all_messages"
    # Take the last substantial message
    tail -1 "$state_dir/all_messages" > "$state_dir/output"

    # Save workdir for resume
    echo "$workdir" > "$state_dir/workdir"
    ;;

  resume)
    prompt=$(cat "$state_dir/prompt")
    session_id=$(cat "$state_dir/session")
    workdir=$(cat "$state_dir/workdir")

    cd "$workdir"
    codex exec resume --json --skip-git-repo-check \
      --dangerously-bypass-approvals-and-sandbox \
      "$session_id" \
      "$prompt" \
      > "$state_dir/raw.jsonl" 2>"$state_dir/agent.err" || true

    jq -r 'select(.type=="item.completed" and .item.type=="agent_message") | .item.text' \
      "$state_dir/raw.jsonl" | awk 'NF' > "$state_dir/all_messages"
    tail -1 "$state_dir/all_messages" > "$state_dir/output"
    ;;

  *)
    echo "Unknown command: $cmd" >&2
    exit 1
    ;;
esac

# Write default exit_code if agent didn't set one (via linear-tool status "Blocked")
[ -f "$state_dir/exit_code" ] || echo "0" > "$state_dir/exit_code"
