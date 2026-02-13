# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

A shell-based bridge that polls Linear for issues assigned to an agent user, dispatches coding agents (Codex or Claude Code) in tmux sessions, and posts results back as Linear comments. The full lifecycle: **Todo** → agent picks up → **In Progress** → agent finishes → posts comment → **In Review** → human replies → agent resumes same session → repeat.

## Commands

```bash
./machine.sh start    # Start polling loop (background)
./machine.sh stop     # Stop loop + kill all agent tmux sessions
./machine.sh status   # Show running agents and tracked issues
```

Watch a live agent session: `tmux attach -t linear-<issue-id>`
Logs: `tail -f /tmp/linear-agent/machine.log`

There are no build, lint, or test commands — the project is pure bash.

## Architecture

The system has four layers connected by filesystem state:

1. **`machine.sh`** — Main poll loop. Runs two phases each cycle:
   - `collect_results`: scans `/tmp/linear-agent/*/output` for finished agents (tmux session gone = done), posts output as Linear comment, moves issue to In Review.
   - `poll_and_dispatch`: queries Linear GraphQL for issues in Todo (new) or In Review (check for human comments), dispatches or resumes agents.
   - Environment helpers: `collect_poll_states`, `resolve_environment`, `env_status`, `env_repo_path`, `build_tmux_cmd`.

2. **`environments/`** — Per-project configuration. Each Linear project maps to an environment directory via `mapping.conf`. Each environment contains:
   - `repo_path` — single line with the target repository path
   - `config.sh` — team-specific workflow status IDs (STATUS_TODO, STATUS_IN_PROGRESS, STATUS_IN_REVIEW)
   - `env.sh` — optional, git-ignored: environment variables sourced before agent runs
   - `setup.sh` — optional, executable: runs on first dispatch only (not resume)
   - `environments/default/` is the fallback for unmapped projects.

3. **`adapters/{codex,claude}.sh`** — Agent adapters with a uniform interface: `start STATE_DIR WORKDIR` and `resume STATE_DIR`. Each writes `session`, `output`, and debug files (`raw.json`/`raw.jsonl`, `agent.err`) to STATE_DIR. Adding a new agent means writing a new adapter following this contract.

4. **`lib/linear.sh`** — Linear GraphQL API layer. Uses `curl` for HTTP + `python3 -c` with `json.dumps` to safely escape query variables (avoids shell escaping issues with user content). `linear_poll_issues` accepts state IDs as arguments and includes `project { id name }` in the query.

**State directory** (`/tmp/linear-agent/<issue-id>/`): `prompt`, `session`, `output`, `issue_uuid`, `title`, `project_id`, `workdir`, `posted_at`. tmux session existence serves as the lock mechanism — no separate lock files.

## Key Design Decisions

- The Linear API key must belong to the **agent user account**, not a personal account. This is how the script distinguishes agent comments from human comments when deciding whether to resume.
- GraphQL payloads are built via `python3 -c "import json; ..."` rather than string interpolation, because issue descriptions and comments contain arbitrary text that would break JSON if shell-escaped.
- `POLL_INTERVAL`, `STATE_DIR`, `REPOS_DIR`, and `AGENT_TYPE` are configured in `.env`. Workflow state IDs are per-environment in `environments/*/config.sh`. The global `config.sh` serves as legacy fallback only.
- **Environment resolution**: issue project ID → `mapping.conf` lookup → environment dir. No match → `environments/default/`. No `default/` → legacy `$REPOS_DIR` + global `config.sh`. Full backward compat if `environments/` is never created.
- **Setup vs resume**: `setup.sh` runs only on first dispatch; `env.sh` is sourced on both start and resume.

## Dependencies

`curl`, `jq`, `tmux`, `python3`, and the chosen agent CLI (`codex` or `claude`).

## Maintaining This File

Keep this CLAUDE.md up to date. Whenever you add new scripts, change the architecture, modify the adapter contract, add new Linear API functions, or alter the state directory layout, update the relevant sections above in the same commit.
