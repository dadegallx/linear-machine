#!/usr/bin/env bash
set -euo pipefail

# Real E2E acceptance test:
# 1) create issue
# 2) human comment "@francis are you there?"
# 3) assert Francis replies

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SCRIPT_DIR/.env"

: "${LINEAR_API_KEY:?LINEAR_API_KEY is required}"
: "${AGENT_USER_ID:?AGENT_USER_ID is required}"
: "${LINEAR_E2E_TEAM_ID:?LINEAR_E2E_TEAM_ID is required}"

E2E_PROJECT_ID="${LINEAR_E2E_PROJECT_ID:-}"
E2E_TIMEOUT_SECONDS="${E2E_TIMEOUT_SECONDS:-600}"
E2E_POLL_SECONDS="${E2E_POLL_SECONDS:-10}"
AGENT_HANDLE="${AGENT_DISPLAY_NAME:-francis}"

linear_gql() {
  local payload="$1"
  curl -s -X POST https://api.linear.app/graphql \
    -H "Authorization: $LINEAR_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$payload"
}

issue_payload=$(python3 -c '
import json, os
team_id = os.environ["LINEAR_E2E_TEAM_ID"]
project_id = os.environ.get("LINEAR_E2E_PROJECT_ID", "")
input_obj = {
  "teamId": team_id,
  "title": "E2E mention trigger test",
  "description": "Created by linear-machine E2E test."
}
if project_id:
  input_obj["projectId"] = project_id
q = "mutation($input: IssueCreateInput!) { issueCreate(input: $input) { success issue { id identifier } } }"
print(json.dumps({"query": q, "variables": {"input": input_obj}}))
')

issue_resp=$(linear_gql "$issue_payload")
issue_id=$(echo "$issue_resp" | jq -r '.data.issueCreate.issue.id // empty')
issue_identifier=$(echo "$issue_resp" | jq -r '.data.issueCreate.issue.identifier // empty')

if [ -z "$issue_id" ]; then
  echo "Failed to create E2E issue"
  echo "$issue_resp" | jq .
  exit 1
fi

echo "Created issue: $issue_identifier ($issue_id)"

comment_payload=$(python3 -c '
import json, os, sys
issue_id = sys.argv[1]
body = "@francis are you there?"
q = "mutation($input: CommentCreateInput!) { commentCreate(input: $input) { success comment { id createdAt } } }"
print(json.dumps({"query": q, "variables": {"input": {"issueId": issue_id, "body": body}}}))
' "$issue_id")

comment_resp=$(linear_gql "$comment_payload")
mention_comment_id=$(echo "$comment_resp" | jq -r '.data.commentCreate.comment.id // empty')
mention_ts=$(echo "$comment_resp" | jq -r '.data.commentCreate.comment.createdAt // empty')

if [ -z "$mention_comment_id" ]; then
  echo "Failed to post mention comment"
  echo "$comment_resp" | jq .
  exit 1
fi

echo "Posted mention comment: $mention_comment_id at $mention_ts"

deadline=$(( $(date +%s) + E2E_TIMEOUT_SECONDS ))
agent_reply_id=""
agent_reply_ts=""

while [ "$(date +%s)" -lt "$deadline" ]; do
  query_payload=$(python3 -c '
import json, sys
q = "query($id: String!) { issue(id: $id) { comments(last: 50) { nodes { id body createdAt user { id displayName } } } } }"
print(json.dumps({"query": q, "variables": {"id": sys.argv[1]}}))
' "$issue_id")

  resp=$(linear_gql "$query_payload")
  match=$(echo "$resp" | jq -r --arg aid "$AGENT_USER_ID" --arg mts "$mention_ts" '
    (.data.issue.comments.nodes // [])
    | map(select(.user.id == $aid and .createdAt > $mts))
    | sort_by(.createdAt)
    | .[0] // empty
  ')

  if [ -n "$match" ] && [ "$match" != "null" ]; then
    agent_reply_id=$(echo "$match" | jq -r '.id')
    agent_reply_ts=$(echo "$match" | jq -r '.createdAt')
    break
  fi

  sleep "$E2E_POLL_SECONDS"
done

if [ -z "$agent_reply_id" ]; then
  echo "E2E FAILED: no agent reply received within ${E2E_TIMEOUT_SECONDS}s"
  echo "Issue: $issue_identifier"
  exit 1
fi

echo "E2E PASSED"
echo "Issue: $issue_identifier"
echo "Mention Comment: $mention_comment_id"
echo "Agent Reply: $agent_reply_id at $agent_reply_ts"
