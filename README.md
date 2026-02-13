# linear-machine

Polls Linear for issues assigned to an agent user, dispatches coding agents (Codex or Claude Code), and posts results back as comments.

## How it works

```
Linear API  <───>  machine.sh (poll loop)  <───>  Coding Agent (tmux)
  issues             dispatch / collect            codex exec | claude -p
  comments           post results                  --resume for follow-ups
  status             In Progress / In Review
```

1. Assign an issue to the agent user → script picks it up, moves to **In Progress**, spawns agent
2. Agent finishes → script posts output as comment, moves to **In Review**
3. You reply with a comment → script detects it, resumes the **same session** (context preserved)
4. Repeat until done — you move to **Done** manually when satisfied

## Setup

1. Copy `.env.example` to `.env` and fill in:
   - `LINEAR_API_KEY` — API key for the **agent user** (so comments appear from the agent)
   - `AGENT_USER_ID` — Linear user ID of the agent account
   - `AGENT_TYPE` — `codex` or `claude`
   - `REPOS_DIR` — where your repos live (default: `~/Repos`)

2. Edit `config.sh` with your team's Linear workflow state IDs (find these in Linear Settings → Team → Workflow).

3. Dependencies: `curl`, `jq`, `tmux`, and your chosen agent CLI (`codex` or `claude`).

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

## Architecture

```
linear-machine/
├── machine.sh           # Main loop: poll → dispatch → collect → post
├── adapters/
│   ├── codex.sh         # codex exec / codex exec resume
│   └── claude.sh        # claude -p / claude --resume
├── lib/
│   └── linear.sh        # Linear GraphQL API (curl + jq)
├── config.sh            # Linear workflow state IDs (committable)
├── .env                 # Secrets (git-ignored)
└── README.md
```

State lives in `/tmp/linear-agent/<issue-id>/`:
- `prompt` — current prompt sent to agent
- `session` — agent session/thread ID (for resume)
- `output` — agent's response (pending post to Linear)
- `raw.jsonl` / `raw.json` — full agent output for debugging

## Notes

- The API key should belong to the **agent user**, not your personal account — otherwise comments appear from you and the script can't distinguish agent vs human comments.
- The script polls for issues in **Todo** (new work) and **In Review** (check for new human comments). It skips **In Progress** (agent is running).
- tmux session existence = lock. No separate lock files needed.
- Each `--resume` preserves the full prior context: file reads, tool calls, reasoning — the agent picks up where it left off.
