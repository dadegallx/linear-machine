#!/usr/bin/env bash
# Claude Code adapter — wraps claude -p / --resume
# Contract: writes session, output, exit_code to STATE_DIR
set -euo pipefail

cmd="${1:?Usage: claude.sh start|resume STATE_DIR [WORKDIR]}"
state_dir="${2:?Missing STATE_DIR}"

case "$cmd" in
  start)
    workdir="${3:?Missing WORKDIR}"
    prompt=$(cat "$state_dir/prompt")

    CLAUDECODE= claude -p --output-format json \
      --dangerously-skip-permissions \
      --add-dir "$workdir" \
      "$prompt" \
      > "$state_dir/raw.json" 2>/dev/null || true

    jq -r '.session_id // empty' "$state_dir/raw.json" > "$state_dir/session"
    jq -r '.result // empty' "$state_dir/raw.json" > "$state_dir/output"

    # Save workdir for resume
    echo "$workdir" > "$state_dir/workdir"
    ;;

  resume)
    prompt=$(cat "$state_dir/prompt")
    session_id=$(cat "$state_dir/session")

    CLAUDECODE= claude --resume "$session_id" -p \
      --output-format json \
      --dangerously-skip-permissions \
      "$prompt" \
      > "$state_dir/raw.json" 2>/dev/null || true

    jq -r '.result // empty' "$state_dir/raw.json" > "$state_dir/output"
    ;;

  *)
    echo "Unknown command: $cmd" >&2
    exit 1
    ;;
esac
