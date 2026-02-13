#!/usr/bin/env bash
# Linear API functions — pure curl + jq, no dependencies

linear_gql() {
  local payload="$1"
  curl -s -X POST https://api.linear.app/graphql \
    -H "Authorization: $LINEAR_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$payload"
}

linear_poll_issues() {
  # Fetch issues assigned to agent in the given workflow states
  # $@ = state IDs to filter on (Todo + In Review from all environments)
  local payload
  payload=$(python3 -c "
import json, sys
q = 'query(\$uid: ID!, \$states: [ID!]!) { issues(filter: { assignee: { id: { eq: \$uid } }, state: { id: { in: \$states } } }) { nodes { id identifier title description state { id name } project { id name } comments(last: 20) { nodes { id body createdAt user { id displayName } } } } } }'
print(json.dumps({'query': q, 'variables': {'uid': sys.argv[1], 'states': list(sys.argv[2:])}}))" "$AGENT_USER_ID" "$@")
  linear_gql "$payload"
}

linear_post_comment() {
  local issue_id="$1"
  local body="$2"
  local payload
  payload=$(python3 -c "
import json, sys
q = 'mutation(\$input: CommentCreateInput!) { commentCreate(input: \$input) { success comment { id } } }'
print(json.dumps({'query': q, 'variables': {'input': {'issueId': sys.argv[1], 'body': sys.argv[2]}}}))" "$issue_id" "$body")
  linear_gql "$payload"
}

linear_set_status() {
  local issue_id="$1"
  local status_id="$2"
  local payload
  payload=$(python3 -c "
import json, sys
q = 'mutation(\$id: String!, \$input: IssueUpdateInput!) { issueUpdate(id: \$id, input: \$input) { success } }'
print(json.dumps({'query': q, 'variables': {'id': sys.argv[1], 'input': {'stateId': sys.argv[2]}}}))" "$issue_id" "$status_id")
  linear_gql "$payload"
}
