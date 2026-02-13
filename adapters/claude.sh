#!/usr/bin/env bash
# Claude Code adapter — wraps claude -p / --resume
# Contract: writes session, output, exit_code to STATE_DIR
set -euo pipefail

cmd="${1:?Usage: claude.sh start|resume STATE_DIR [WORKDIR]}"
state_dir="${2:?Missing STATE_DIR}"

# Make linear-tool available to the agent
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$SCRIPT_DIR/bin:$PATH"

# Source Linear env vars (for linear-tool)
[ -f "$state_dir/env.sh" ] && source "$state_dir/env.sh"

case "$cmd" in
  start)
    workdir="${3:?Missing WORKDIR}"
    cd "$workdir"

    CLAUDECODE= claude -p --output-format json \
      --dangerously-skip-permissions \
      < "$state_dir/prompt" \
      > "$state_dir/raw.json" 2>"$state_dir/agent.err" || true

    jq -r '.session_id // empty' "$state_dir/raw.json" > "$state_dir/session"
    jq -r '.result // empty' "$state_dir/raw.json" > "$state_dir/output"

    # Save workdir for resume
    echo "$workdir" > "$state_dir/workdir"
    ;;

  resume)
    session_id=$(cat "$state_dir/session")

    CLAUDECODE= claude --resume "$session_id" -p \
      --output-format json \
      --dangerously-skip-permissions \
      < "$state_dir/prompt" \
      > "$state_dir/raw.json" 2>"$state_dir/agent.err" || true

    jq -r '.result // empty' "$state_dir/raw.json" > "$state_dir/output"
    ;;

  *)
    echo "Unknown command: $cmd" >&2
    exit 1
    ;;
esac

# Write default exit_code if agent didn't set one (via linear-tool status "Blocked")
[ -f "$state_dir/exit_code" ] || echo "0" > "$state_dir/exit_code"
