#!/usr/bin/env bash
# exe.dev runner — agents run on managed VMs via exe.dev.
# Each issue gets its own VM. VMs persist between start/resume (same repo + session).
# Destroyed on runner_stop, runner_stop_all, or machine.sh stop.

EXE_REPOS_DIR="${EXE_REPOS_DIR:-~/repos}"
EXE_SSH_TIMEOUT="${EXE_SSH_TIMEOUT:-10}"

_exe_ssh() {
  ssh -o ConnectTimeout="$EXE_SSH_TIMEOUT" -o StrictHostKeyChecking=accept-new "$@"
}

_exe_scp() {
  scp -o ConnectTimeout="$EXE_SSH_TIMEOUT" "$@"
}

_exe_slug() {
  echo "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-+/-/g'
}

_exe_managed_vm_name() {
  local id="$1" state_dir="$2"
  local repo repo_slug id_slug name
  repo=$(basename "$(cat "$state_dir/workdir" 2>/dev/null || echo linear)")
  repo_slug=$(_exe_slug "$repo")
  id_slug=$(_exe_slug "$id")
  name="${repo_slug:-linear}-${id_slug:-issue}"
  echo "${name:0:56}"
}

_exe_each_managed_issue() {
  local state_dir id
  for state_dir in "$STATE_DIR"/*/; do
    [ -d "$state_dir" ] || continue
    [ -f "$state_dir/vm_name" ] || continue
    id=$(basename "$state_dir")
    echo "$id"
  done
}

# ---------------------------------------------------------------------------
# Background watcher: polls remote tmux, syncs results when done
# ---------------------------------------------------------------------------
_exe_spawn_watcher() {
  local id="$1" state_dir="$2" ssh_dest="$3"
  (
    while sleep 15; do
      if ! _exe_ssh "$ssh_dest" tmux has-session -t "linear-$id" 2>/dev/null; then
        # Agent finished — sync results back
        log "VM session ended for $id ($ssh_dest), syncing results"
        for f in output session raw.json raw.jsonl all_messages agent.err exit_code; do
          _exe_scp "$ssh_dest:~/state/$id/$f" "$state_dir/$f" 2>/dev/null || true
        done
        break
      fi
    done
  ) &
}

# ---------------------------------------------------------------------------
# runner_start ID STATE_DIR ENV_DIR AGENT_TYPE ACTION
# ---------------------------------------------------------------------------
runner_start() {
  local id="$1" state_dir="$2" env_dir="$3" agent_type="$4" action="$5"
  local remote_workdir="$EXE_REPOS_DIR/$(basename "$(cat "$state_dir/workdir")")"

  if [ "$action" = "start" ]; then
    # Spin up a new VM
    local vm_json vm_name ssh_dest requested_name
    requested_name=$(_exe_managed_vm_name "$id" "$state_dir")
    vm_json=$(_exe_ssh exe.dev new --json --name "$requested_name" 2>/dev/null || _exe_ssh exe.dev new --json)
    vm_name=$(echo "$vm_json" | jq -r '.vm_name')
    ssh_dest=$(echo "$vm_json" | jq -r '.ssh_dest')

    log "VM provisioned for $id: $vm_name ($ssh_dest)"

    # Save VM identity
    echo "$vm_name" > "$state_dir/vm_name"
    echo "$ssh_dest" > "$state_dir/ssh_dest"

    # Ensure remote repo exists when repo_url is configured.
    # Keep this idempotent so restarts don't crash on existing directories.
    if [ -n "$env_dir" ] && [ -f "$env_dir/repo_url" ]; then
      local repo_url remote_parent
      repo_url=$(tr -d '[:space:]' < "$env_dir/repo_url")
      remote_parent="${remote_workdir%/*}"
      if [ -n "$repo_url" ]; then
        _exe_ssh "$ssh_dest" "mkdir -p $remote_parent"
        _exe_ssh "$ssh_dest" "[ -d $remote_workdir/.git ] || git clone $repo_url $remote_workdir"
      fi
    else
      _exe_ssh "$ssh_dest" "mkdir -p $remote_workdir"
    fi

    # Create remote structure
    _exe_ssh "$ssh_dest" "mkdir -p ~/state/$id/env ~/adapters ~/bin"

    # Sync tooling
    _exe_scp "$SCRIPT_DIR/adapters/${agent_type}.sh" "$ssh_dest:~/adapters/"
    _exe_scp "$SCRIPT_DIR/bin/linear-tool" "$ssh_dest:~/bin/"

    # Sync state files + write remote workdir
    echo "$remote_workdir" > "$state_dir/remote_workdir"
    for f in prompt issue_uuid title team_id env.sh; do
      [ -f "$state_dir/$f" ] && _exe_scp "$state_dir/$f" "$ssh_dest:~/state/$id/" 2>/dev/null || true
    done
    _exe_ssh "$ssh_dest" "echo $remote_workdir > ~/state/$id/workdir"

    # Sync env dir files
    if [ -n "$env_dir" ]; then
      [ -f "$env_dir/env.sh" ] && _exe_scp "$env_dir/env.sh" "$ssh_dest:~/state/$id/env/"
      [ -x "$env_dir/setup.sh" ] && _exe_scp "$env_dir/setup.sh" "$ssh_dest:~/state/$id/env/"
    fi

    # Sync provider credentials (Codex/Claude/etc.) before starting agent.
    provider_sync_credentials "$ssh_dest"

    # Build remote command chain
    local cmd="export PATH=~/bin:\$PATH && source ~/state/$id/env.sh"
    [ -n "$env_dir" ] && [ -f "$env_dir/env.sh" ] && cmd="$cmd && source ~/state/$id/env/env.sh"
    [ -n "$env_dir" ] && [ -x "$env_dir/setup.sh" ] && cmd="$cmd && ~/state/$id/env/setup.sh"
    cmd="$cmd && ~/adapters/${agent_type}.sh start ~/state/$id $remote_workdir"

    local escaped_cmd
    escaped_cmd=$(printf "%q" "$cmd")
    _exe_ssh "$ssh_dest" "tmux new-session -d -s linear-$id bash -lc $escaped_cmd"
    _exe_spawn_watcher "$id" "$state_dir" "$ssh_dest"

  else
    # Resume — reuse existing VM
    local ssh_dest
    ssh_dest=$(cat "$state_dir/ssh_dest") || {
      echo "No ssh_dest for $id — cannot resume" >&2
      return 1
    }

    # Sync updated state
    _exe_scp "$state_dir/prompt" "$ssh_dest:~/state/$id/"
    [ -f "$state_dir/env.sh" ] && _exe_scp "$state_dir/env.sh" "$ssh_dest:~/state/$id/" 2>/dev/null || true

    # Clear previous exit markers
    _exe_ssh "$ssh_dest" "rm -f ~/state/$id/exit_code ~/state/$id/agent_state"

    # Refresh provider credentials before resuming agent session.
    provider_sync_credentials "$ssh_dest"

    # Build remote command (no setup.sh on resume)
    local cmd="export PATH=~/bin:\$PATH && source ~/state/$id/env.sh"
    [ -n "$env_dir" ] && [ -f "$env_dir/env.sh" ] && cmd="$cmd && source ~/state/$id/env/env.sh"
    cmd="$cmd && ~/adapters/${agent_type}.sh resume ~/state/$id"

    local escaped_cmd
    escaped_cmd=$(printf "%q" "$cmd")
    _exe_ssh "$ssh_dest" "tmux new-session -d -s linear-$id bash -lc $escaped_cmd"
    _exe_spawn_watcher "$id" "$state_dir" "$ssh_dest"
  fi
}

# ---------------------------------------------------------------------------
# runner_is_running ID
# ---------------------------------------------------------------------------
runner_is_running() {
  local ssh_dest
  ssh_dest=$(cat "$STATE_DIR/$1/ssh_dest" 2>/dev/null) || return 1
  _exe_ssh "$ssh_dest" tmux has-session -t "linear-$1" 2>/dev/null
}

# ---------------------------------------------------------------------------
# runner_stop ID
# ---------------------------------------------------------------------------
runner_stop() {
  local vm_name ssh_dest
  vm_name=$(cat "$STATE_DIR/$1/vm_name" 2>/dev/null) || return 0
  ssh_dest=$(cat "$STATE_DIR/$1/ssh_dest" 2>/dev/null) || true

  [ -n "$ssh_dest" ] && _exe_ssh "$ssh_dest" tmux kill-session -t "linear-$1" 2>/dev/null || true
  if [ -n "$vm_name" ]; then
    _exe_ssh exe.dev rm "$vm_name" 2>/dev/null || true
    log "VM destroyed for $1: $vm_name"
  fi
  rm -f "$STATE_DIR/$1/vm_name" "$STATE_DIR/$1/ssh_dest"
}

# ---------------------------------------------------------------------------
# runner_stop_all
# ---------------------------------------------------------------------------
runner_stop_all() {
  local id
  while read -r id; do
    [ -n "$id" ] || continue
    runner_stop "$id"
  done < <(_exe_each_managed_issue)
}

# ---------------------------------------------------------------------------
# runner_list
# ---------------------------------------------------------------------------
runner_list() {
  local vms_json id vm status
  vms_json=$(_exe_ssh exe.dev ls --json 2>/dev/null || true)
  while read -r id; do
    [ -n "$id" ] || continue
    vm=$(cat "$STATE_DIR/$id/vm_name" 2>/dev/null || true)
    [ -n "$vm" ] || continue
    status=$(echo "$vms_json" | jq -r --arg vm "$vm" '[.vms[] | select(.vm_name == $vm) | .status][0] // "stopped"' 2>/dev/null || echo "unknown")
    echo "$id: $vm ($status)"
  done < <(_exe_each_managed_issue)
}
