#!/usr/bin/env bash
set -euo pipefail

# Post a neutral check run when the review could not complete.
# Inputs (env vars): GH_TOKEN, REPO, HEAD_SHA, CHECK_NAME, RUN_URL
# Arg $1: reason — "too-large" | "action-error" (default)

REASON="${1:-action-error}"
case "$REASON" in
  too-large)
    TITLE="PR too large to review"
    SUMMARY="This PR exceeds the size limit for automated review." ;;
  *)
    TITLE="Review could not complete"
    SUMMARY="The code review encountered an error. See the workflow run for details." ;;
esac

jq -n \
  --arg name "${CHECK_NAME:-Claude Code Review}" \
  --arg sha "${HEAD_SHA:?HEAD_SHA env var required}" \
  --arg title "$TITLE" \
  --arg summary "$SUMMARY" \
  --arg run_url "${RUN_URL:-}" \
  '{
    "name": $name,
    "head_sha": $sha,
    "status": "completed",
    "conclusion": "neutral",
    "output": {
      "title": $title,
      "summary": ($summary + (if $run_url != "" then "\n\n[View workflow run](\($run_url))" else "" end)),
      "text": "The review could not complete. This does not indicate the code is good or bad."
    }
  }' > /tmp/check-run-failure-payload.json

gh api "repos/${REPO:?REPO env var required}/check-runs" \
  --method POST --input /tmp/check-run-failure-payload.json > /dev/null \
  || echo "::warning::Failed to post neutral check run (${REASON}) — consumer may lack checks:write"

echo "::warning::Review could not complete — posted neutral check run (${REASON})"
