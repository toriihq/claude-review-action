#!/bin/bash
# post-security-failure.sh — posts a neutral check run when the security scan fails
# Required env vars: REPO, HEAD_SHA, GH_TOKEN, RUN_URL
set -e

FAILURE_REASON="${1:-action-error}"

case "$FAILURE_REASON" in
  too-large)
    TITLE="PR too large to scan"
    SUMMARY="This PR exceeds the file limit for automated security scanning."
    ;;
  *)
    TITLE="Security scan could not complete"
    SUMMARY="The security review encountered an error. See the workflow run for details."
    ;;
esac

jq -n \
  --arg name "Security Review" \
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
      "text": "The security scan could not complete. This does not indicate the code is secure or insecure."
    }
  }' > /tmp/check-run-failure-payload.json

GH_TOKEN="${SECURITY_GH_TOKEN:?SECURITY_GH_TOKEN env var required}" \
  gh api "repos/${REPO:?REPO env var required}/check-runs" \
  --method POST \
  --input /tmp/check-run-failure-payload.json > /dev/null \
  || echo "::warning::Failed to post neutral check run (${FAILURE_REASON})"

echo "::warning::Security scan failed — posted neutral check run (${FAILURE_REASON})"
