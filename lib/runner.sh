#!/usr/bin/env bash
# Runner loader — sources the active runner and validates its contract.
# Runners implement WHERE agents run (local tmux, remote VM, etc.).

RUNNER_TYPE="${RUNNER_TYPE:-local}"

_runner_file="$SCRIPT_DIR/runners/${RUNNER_TYPE}.sh"
if [ ! -f "$_runner_file" ]; then
  echo "Unknown RUNNER_TYPE=$RUNNER_TYPE (no file: $_runner_file)" >&2
  exit 1
fi

source "$_runner_file"

for _fn in runner_start runner_is_running runner_stop runner_stop_all runner_list; do
  if ! declare -f "$_fn" > /dev/null 2>&1; then
    echo "Runner '$RUNNER_TYPE' missing required function: $_fn" >&2
    exit 1
  fi
done
unset _runner_file _fn
