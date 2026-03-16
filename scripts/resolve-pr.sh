#!/usr/bin/env bash
set -euo pipefail

# Resolve PR number, SHA, event type, and user comment from any trigger type.
# Inputs (env vars): EVENT_NAME, EVENT_JSON, GH_TOKEN, GITHUB_REPOSITORY
# Outputs (GITHUB_OUTPUT): pr_number, pr_sha, event_type, user_comment

EVENT=$(echo "$EVENT_JSON" | jq -r '.')

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

# User comment may be multiline — use heredoc delimiter
{
  echo 'user_comment<<__GHA_COMMENT_EOF__'
  echo "$USER_COMMENT"
  echo '__GHA_COMMENT_EOF__'
} >> "$GITHUB_OUTPUT"

echo "::notice::Resolved PR #$PR_NUMBER (SHA: ${PR_SHA:0:7}, event: $EVENT_NAME)"

# --- Detect deep review label ---
if [ "$EVENT_NAME" = "pull_request" ]; then
  TRIGGER_LABEL=$(echo "$EVENT_JSON" | jq -r '.label.name // ""')
  if [ "$TRIGGER_LABEL" = "$DEEP_REVIEW_LABEL" ]; then
    echo "is_deep_label=true" >> "$GITHUB_OUTPUT"
  else
    echo "is_deep_label=false" >> "$GITHUB_OUTPUT"
  fi
else
  echo "is_deep_label=false" >> "$GITHUB_OUTPUT"
fi
