#!/usr/bin/env bash
set -euo pipefail

# Resolve PR number, SHA, event type, and user comment from any trigger type.
# Inputs (env vars): EVENT_NAME, GITHUB_EVENT_PATH, GH_TOKEN, GITHUB_REPOSITORY
# Outputs (GITHUB_OUTPUT): pr_number, pr_sha, event_type
# Outputs (files): /tmp/user-comment.txt

# Read the event from the runner's file, not an env var — a big PR body/comment would exceed Linux's 128 KB per-env-var limit
EVENT=$(jq -r '.' "${GITHUB_EVENT_PATH:?}")

case "$EVENT_NAME" in
  pull_request)
    PR_NUMBER=$(echo "$EVENT" | jq -r '.pull_request.number')
    PR_SHA=$(echo "$EVENT" | jq -r '.pull_request.head.sha')
    USER_COMMENT=""
    ;;
  issue_comment)
    PR_NUMBER=$(echo "$EVENT" | jq -r '.issue.number')
    # issue_comment doesn't include head SHA — fetch it
    PR_SHA=$(gh pr view "$PR_NUMBER" --repo "$GITHUB_REPOSITORY" --json headRefOid --jq '.headRefOid')
    USER_COMMENT=$(echo "$EVENT" | jq -r '.comment.body // ""')
    ;;
  pull_request_review_comment)
    PR_NUMBER=$(echo "$EVENT" | jq -r '.pull_request.number')
    PR_SHA=$(echo "$EVENT" | jq -r '.pull_request.head.sha')
    USER_COMMENT=$(echo "$EVENT" | jq -r '.comment.body // ""')
    ;;
  *)
    echo "::error::Unsupported event type: $EVENT_NAME"
    exit 1
    ;;
esac

echo "pr_number=$PR_NUMBER" >> "$GITHUB_OUTPUT"
echo "pr_sha=$PR_SHA" >> "$GITHUB_OUTPUT"
echo "event_type=$EVENT_NAME" >> "$GITHUB_OUTPUT"

# File, not an output: an output would reach build-prompt as an env var, and a fixed heredoc delimiter is injectable
printf '%s\n' "$USER_COMMENT" > /tmp/user-comment.txt

echo "::notice::Resolved PR #$PR_NUMBER (SHA: ${PR_SHA:0:7}, event: $EVENT_NAME)"
