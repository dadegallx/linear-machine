#!/usr/bin/env bash
# Linear API functions — pure curl + jq, no dependencies

linear_gql() {
  local query="$1"
  curl -s -X POST https://api.linear.app/graphql \
    -H "Authorization: $LINEAR_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$query" \
    | python3 -c "import sys,json; json.dump(json.load(sys.stdin),sys.stdout,ensure_ascii=False)"
}

linear_poll_issues() {
  # Fetch issues assigned to agent in Todo or In Review states
  # Todo = new work to dispatch
  # In Review = check for new human comments to resume
  linear_gql "{
    \"query\": \"{ issues(filter: { assignee: { id: { eq: \\\"$AGENT_USER_ID\\\" } }, state: { id: { in: [\\\"$STATUS_TODO\\\", \\\"$STATUS_IN_REVIEW\\\"] } } }) { nodes { id identifier title description state { id name } comments(last: 20) { nodes { id body createdAt user { id displayName } } } } } }\"
  }"
}

linear_post_comment() {
  local issue_id="$1"
  local body="$2"
  local escaped_body
  escaped_body=$(printf '%s' "$body" | jq -Rs .)
  linear_gql "{
    \"query\": \"mutation { commentCreate(input: { issueId: \\\"$issue_id\\\", body: $escaped_body }) { success comment { id } } }\"
  }"
}

linear_set_status() {
  local issue_id="$1"
  local status_id="$2"
  linear_gql "{
    \"query\": \"mutation { issueUpdate(id: \\\"$issue_id\\\", input: { stateId: \\\"$status_id\\\" }) { success } }\"
  }"
}
