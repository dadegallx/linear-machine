#!/usr/bin/env bash
# Local runner — agents run in tmux sessions on this machine.
# Extracted from machine.sh; this is the default runner.

runner_start() {
  local id="$1" state_dir="$2" env_dir="$3" agent_type="$4" action="$5"
  local workdir
  workdir=$(cat "$state_dir/workdir")

  # Build command chain: [env.sh &&] [setup.sh &&] adapter
  local cmd="$SCRIPT_DIR/adapters/${agent_type}.sh"
  if [ "$action" = "start" ]; then
    cmd="$cmd start $state_dir $workdir"
  else
    cmd="$cmd resume $state_dir"
  fi

  if [ -n "$env_dir" ]; then
    if [ "$action" = "start" ] && [ -x "$env_dir/setup.sh" ]; then
      cmd="$env_dir/setup.sh && $cmd"
    fi
    if [ -f "$env_dir/env.sh" ]; then
      cmd="source $env_dir/env.sh && $cmd"
    fi
  fi

  tmux new-session -d -s "linear-$id" "$cmd"
}

runner_is_running() {
  tmux has-session -t "linear-$1" 2>/dev/null
}

runner_stop() {
  tmux kill-session -t "linear-$1" 2>/dev/null || true
}

runner_stop_all() {
  tmux ls 2>/dev/null | grep "^linear-" | cut -d: -f1 | while read -r s; do
    tmux kill-session -t "$s" 2>/dev/null
  done
}

runner_list() {
  tmux ls 2>/dev/null | grep "^linear-" || true
}
