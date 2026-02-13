# linear-machine

Polls Linear for issues assigned to an agent user, dispatches coding agents (Codex or Claude Code), and posts results back as comments.

## How it works

```
Linear API  <──>  machine.sh  <──>  runner (where)  <──>  adapter (what)
  issues           poll/dispatch     local tmux           codex exec
  comments         crash recovery    exe.dev VM           claude -p
  status                             (future: ...)        --resume
```

1. Assign an issue to the agent user → machine dispatches via runner → agent self-assigns, moves to **In Progress**
2. Agent finishes → posts comment + moves to **In Review**
3. You reply with a comment → machine resumes the **same session** (context preserved)
4. If stuck → agent moves to **Blocked** and stops; machine resumes when you reply
5. Repeat until done — you move to **Done** manually when satisfied

## Setup

1. Copy `.env.example` to `.env` and fill in:
   - `LINEAR_API_KEY` — API key for the **agent user** (so comments appear from the agent)
   - `AGENT_USER_ID` — Linear user ID of the agent account
   - `AGENT_TYPE` — `codex` or `claude`
   - `REPOS_DIR` — where your repos live (default: `~/Repos`)
   - `RUNNER_TYPE` — `local` (default) or `exe` (see [Runners](#runners))

2. Dependencies: `curl`, `jq`, `tmux`, `python3`, and your chosen agent CLI (`codex` or `claude`).

## Usage

```bash
./machine.sh start    # Start polling loop (background)
./machine.sh status   # Show running agents and tracked issues
./machine.sh stop     # Stop loop + kill all agent sessions
```

Watch an agent work live:
```bash
tmux attach -t linear-per-50
```

Check the log:
```bash
tail -f /tmp/linear-agent/machine.log
```

## Swap agents

Change `AGENT_TYPE` in `.env`:
```bash
AGENT_TYPE=codex    # default
AGENT_TYPE=claude   # swap to Claude Code
```

Both adapters expose the same interface: `start STATE_DIR WORKDIR` and `resume STATE_DIR`.

## Runners

Runners control **where** agents execute. Adapters control **which** agent runs.

### Local (default)

Agents run in tmux sessions on this machine. No extra config needed.

```bash
RUNNER_TYPE=local    # or just omit — this is the default
```

### exe.dev

Agents run on managed VMs via [exe.dev](https://exe.dev). Each issue gets its own VM that persists across resume cycles.

```bash
RUNNER_TYPE=exe
EXE_REPOS_DIR=~/repos    # where repos land on VMs (default)
```

**Per-environment:** add a `repo_url` file so the runner knows what to clone:
```
environments/my-project/
  repo_path   → /Users/you/Repos/my-project     (local runner)
  repo_url    → https://github.com/org/my-project (remote runners clone this)
```

**VM lifecycle:** provision on dispatch → clone repo → sync state → run agent → sync results back → destroy on stop. VMs are reused on resume (same repo + session state).

### Adding a new runner

Create `runners/<name>.sh` implementing 5 functions:

```bash
runner_start ID STATE_DIR ENV_DIR AGENT_TYPE ACTION   # launch/resume agent
runner_is_running ID                                   # exit 0 if active
runner_stop ID                                         # kill agent
runner_stop_all                                        # kill all agents
runner_list                                            # print running agents
```

Set `RUNNER_TYPE=<name>` in `.env`. No changes to machine.sh or adapters needed.

## Architecture

```
linear-machine/
├── machine.sh           # Supervisor: poll → dispatch → crash recovery
├── runners/
│   ├── local.sh         # Local tmux sessions (default)
│   └── exe.sh           # exe.dev managed VMs
├── adapters/
│   ├── codex.sh         # codex exec / codex exec resume
│   └── claude.sh        # claude -p / claude --resume
├── lib/
│   ├── linear.sh        # Linear GraphQL API (curl + jq)
│   └── runner.sh        # Runner loader + contract validation
├── environments/        # Per-project config (mapping.conf, repo_path, repo_url)
├── bin/
│   └── linear-tool      # Agent-callable CLI for Linear operations
├── .env                 # Secrets + config (git-ignored)
└── README.md
```

State lives in `/tmp/linear-agent/<issue-id>/`:
- `prompt` — current prompt sent to agent
- `session` — agent session/thread ID (for resume)
- `output` — agent's response
- `exit_code` — 0 = success, 100 = blocked, other = crash
- `raw.jsonl` / `raw.json` — full agent output for debugging
- `vm_name`, `ssh_dest` — remote runner VM identity (exe runner only)

## Notes

- The API key should belong to the **agent user**, not your personal account — otherwise comments appear from you and the script can't distinguish agent vs human comments.
- Workflow states (In Progress, Blocked, etc.) are resolved dynamically by name via the Linear API — no hardcoded UUIDs.
- Agents own their workflow: they call `linear-tool` to assign, update status, and post comments. Machine.sh only intervenes on crash.
- Each `--resume` preserves the full prior context: file reads, tool calls, reasoning — the agent picks up where it left off.
