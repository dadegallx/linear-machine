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

The system has three layers connected by filesystem state:

1. **`machine.sh`** — Main poll loop. Runs two phases each cycle:
   - `collect_results`: scans `/tmp/linear-agent/*/output` for finished agents (tmux session gone = done), posts output as Linear comment, moves issue to In Review.
   - `poll_and_dispatch`: queries Linear GraphQL for issues in Todo (new) or In Review (check for human comments), dispatches or resumes agents.

2. **`adapters/{codex,claude}.sh`** — Agent adapters with a uniform interface: `start STATE_DIR WORKDIR` and `resume STATE_DIR`. Each writes `session`, `output`, and debug files (`raw.json`/`raw.jsonl`, `agent.err`) to STATE_DIR. Adding a new agent means writing a new adapter following this contract.

3. **`lib/linear.sh`** — Linear GraphQL API layer. Uses `curl` for HTTP + `python3 -c` with `json.dumps` to safely escape query variables (avoids shell escaping issues with user content). Three functions: `linear_poll_issues`, `linear_post_comment`, `linear_set_status`.

**State directory** (`/tmp/linear-agent/<issue-id>/`): `prompt`, `session`, `output`, `issue_uuid`, `title`, `workdir`, `posted_at`. tmux session existence serves as the lock mechanism — no separate lock files.

## Key Design Decisions

- The Linear API key must belong to the **agent user account**, not a personal account. This is how the script distinguishes agent comments from human comments when deciding whether to resume.
- GraphQL payloads are built via `python3 -c "import json; ..."` rather than string interpolation, because issue descriptions and comments contain arbitrary text that would break JSON if shell-escaped.
- `POLL_INTERVAL`, `STATE_DIR`, `REPOS_DIR`, and `AGENT_TYPE` are configured in `.env`. Workflow state IDs (Todo, In Progress, In Review) are in `config.sh` — these are team-specific Linear UUIDs.

## Dependencies

`curl`, `jq`, `tmux`, `python3`, and the chosen agent CLI (`codex` or `claude`).

## Maintaining This File

Keep this CLAUDE.md up to date. Whenever you add new scripts, change the architecture, modify the adapter contract, add new Linear API functions, or alter the state directory layout, update the relevant sections above in the same commit.
