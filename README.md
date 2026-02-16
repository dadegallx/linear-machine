# Linear Machine

**Tag an issue. Your agent handles the rest.**

A self-hosted implementation of [Linear for Agents](https://linear.app/agents) — bring your own coding agent, bring your own infrastructure. No vendor lock-in, no third-party routing, no black boxes. Your code stays on your machines.

## Why

Linear's [agent ecosystem](https://linear.app/agents) lets you assign issues to AI agents like Devin or Codegen. But those agents run on someone else's infrastructure, with someone else's access to your repos.

Linear Machine gives you the same workflow — assign an issue, agent picks it up, works it, posts updates, asks for help when stuck — except:

- **Bring your own agent.** Claude Code, Codex, or anything with a CLI. Swap with one line.
- **Bring your own infra.** Local tmux, remote VMs via [exe.dev](https://exe.dev), or write your own runner.
- **Your data stays yours.** Your Linear API key, your repos, your machines. Nothing leaves your environment.

The whole thing is ~500 lines of bash. No framework, no runtime, no dependencies beyond `curl`, `jq`, `tmux`, and your agent CLI.

## How It Works

```
Linear  ←→  machine.sh  ←→  runner (where)  ←→  adapter (what)
assign       poll/dispatch    local tmux          claude -p
comment      crash recovery   exe.dev VM          codex exec
@mention                      your infra          your agent
```

1. **Trigger** by assigning to agent or mentioning `@<agent-name>` in comments
2. **Agent works** — self-assigns, moves to In Progress, posts updates
3. **Agent finishes** — posts summary, moves to In Review
4. **You reply** — machine resumes the same session with all new human comments since the latest agent comment
5. **Agent is stuck** — moves to Blocked and stops; resumes when you respond
6. **Repeat** until done

Every step is visible in Linear. The agent shows up as a teammate — comments, status changes, the full audit trail.

## Quick Start

1. Copy `.env.example` to `.env`:
   ```bash
   LINEAR_API_KEY=lin_api_...   # API key for the agent user account
   AGENT_USER_ID=...            # Linear user ID of the agent
   AGENT_TYPE=claude             # "claude" or "codex"
   REPOS_DIR=~/Repos            # where your repos live
   ```

2. Install dependencies: `curl`, `jq`, `tmux`, `python3`, and your agent CLI.

3. Run:
   ```bash
   ./machine.sh start    # start polling
   ./machine.sh status   # check agents
   ./machine.sh stop     # interactive warning: session memory is lost
   ./machine.sh stop --yes   # non-interactive stop
   ```

4. Assign to the agent user (or mention `@Francis`) in Linear. Watch it work:
   ```bash
   tmux attach -t linear-per-50       # live agent session
   tail -f /tmp/linear-agent/machine.log   # supervisor log
   ```

## Agents

Swap agents with one line in `.env`:

```bash
AGENT_TYPE=claude   # Claude Code (claude -p / --resume)
AGENT_TYPE=codex    # OpenAI Codex (codex exec / resume)
```

Both adapters expose the same interface: `start STATE_DIR WORKDIR` and `resume STATE_DIR`. Adding a new agent means writing one adapter script.

Provider auth sync is modular too: each provider script implements `provider_sync_credentials SSH_DEST`, and remote runners call it before start/resume.

## Runners

Runners control **where** agents execute. Adapters control **which** agent runs.

### Local (default)

Agents run in tmux sessions on this machine. No extra config.

```bash
RUNNER_TYPE=local    # or just omit — this is the default
```

### exe.dev

Agents run on managed VMs via [exe.dev](https://exe.dev). Each issue gets its own VM that persists across resume cycles.

```bash
RUNNER_TYPE=exe
EXE_REPOS_DIR=~/repos    # where repos land on VMs (default)

# Optional auth file overrides for remote auth injection:
CODEX_AUTH_FILE=~/.codex/auth.json
CODEX_REMOTE_AUTH_FILE=~/.codex/auth.json
CLAUDE_AUTH_FILE=~/.claude/.credentials.json
CLAUDE_REMOTE_AUTH_FILE=~/.claude/.credentials.json
```

Per-environment, add a `repo_url` file so the runner knows what to clone:
```
environments/my-project/
  repo_path   → /Users/you/Repos/my-project       (local runner)
  repo_url    → https://github.com/org/my-project  (remote runners clone this)
```

VM lifecycle: provision on dispatch, clone repo, sync state, run agent, sync results back, destroy on stop. VMs are reused on resume.
Managed VM names are standardized as `<repo>-<issue>` when possible (for example `psp-platform-vetta-365`).
Before each remote start/resume, the provider credential file is SCP-injected to the VM via `provider_sync_credentials`.

### Adding a runner

Create `runners/<name>.sh` implementing 5 functions:

```bash
runner_start ID STATE_DIR ENV_DIR AGENT_TYPE ACTION   # launch/resume
runner_is_running ID                                   # exit 0 if active
runner_stop ID                                         # kill agent
runner_stop_all                                        # stop only issue-attached VMs tracked in STATE_DIR
runner_list                                            # print only issue-attached managed VMs
```

Set `RUNNER_TYPE=<name>` in `.env`. No changes to machine.sh or adapters.

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
├── providers/
│   ├── base.sh          # shared credential sync helpers
│   ├── codex.sh         # codex auth file sync
│   └── claude.sh        # claude auth file sync
├── lib/
│   ├── linear.sh        # Linear GraphQL API (curl + jq)
│   ├── provider.sh      # Provider loader (auth sync contract)
│   └── runner.sh        # Runner loader + contract validation
├── environments/        # Per-project config (mapping, repo paths, env vars)
├── bin/
│   └── linear-tool      # Agent-callable CLI for Linear operations
└── .env                 # Secrets + config (git-ignored)
```

State lives in `/tmp/linear-agent/<issue-id>/`:
- `prompt` — current prompt sent to agent
- `session` — agent session/thread ID (for resume)
- `output` — agent's response
- `exit_code` — 0 success, 100 blocked, other crash
- `raw.json` / `raw.jsonl` — full agent output for debugging
- `vm_name`, `ssh_dest` — VM identity (remote runners only)

## Notes

- The API key must belong to the **agent user account**, not your personal account. This is how the system distinguishes agent comments from human comments.
- Workflow states (In Progress, Blocked, In Review) are resolved by name via the Linear API — no hardcoded UUIDs. Works with any team's workflow.
- Agents own their lifecycle: they call `linear-tool` to assign, update status, and post comments. The supervisor only intervenes on crash.
- Each resume preserves full prior context — file reads, tool calls, reasoning. The agent picks up exactly where it left off.
