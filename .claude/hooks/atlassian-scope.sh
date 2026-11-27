#!/usr/bin/env bash
# PreToolUse(Atlassian writes): Jira/Confluence writes arrive either as dedicated tools (transitionJiraIssue, …)
# or through the generic executeWrite tool with the operation in tool_input.name. The server changes which tools
# it exposes, so one per-agent policy covers both routes. Fails closed (exit 2).
set -Eeuo pipefail
trap 'echo "BLOCKED: atlassian scope hook error at line $LINENO (failing closed)" >&2; exit 2' ERR

INPUT=$(cat)
TOOL=$(jq -r '.tool_name // empty' <<<"$INPUT")
AGENT=$(jq -r '.agent_type // "main"' <<<"$INPUT")
OP="${TOOL##*__}"

# Reads are free; anything not recognisably read-only is a write and must be on the allowlist below.
case "$OP" in
  get* | search* | list* | lookup* | fetch | discover | executeRead | atlassianUserInfo | atlassianHome) exit 0 ;;
esac
[ "$OP" = executeWrite ] && OP=$(jq -r '.tool_input.name // empty' <<<"$INPUT")

case "$AGENT:$OP" in
  factory-builder:transitionJiraIssue) ;;                                              # To Do -> In Progress
  # Comment tool is addCommentToJiraIssue on the v1 endpoint, addOrEditJiraIssueComment on v2.
  release-ops:transitionJiraIssue | release-ops:addCommentToJiraIssue | release-ops:addOrEditJiraIssueComment) ;;  # PR comment, -> Code Review
  main:transitionJiraIssue | main:addCommentToJiraIssue | main:addOrEditJiraIssueComment | main:editJiraIssue) ;;  # orchestrator: factory-blocked label + comment
  *)
    echo "BLOCKED: Atlassian write '$OP' is not allowed for agent '$AGENT' in the factory." >&2
    exit 2
    ;;
esac
exit 0
