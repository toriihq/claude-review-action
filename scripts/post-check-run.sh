#!/bin/bash
# post-check-run.sh — called by Claude after completing a security review
# Usage: bash post-check-run.sh <conclusion> <title>
#   conclusion: "success" or "failure" (or "neutral" if BLOCKING=false)
#   title: short summary string
# Required env vars: REPO, HEAD_SHA, GH_TOKEN, BLOCKING (set by action)
set -e

RAW_CONCLUSION="${1:?First arg required: conclusion (success|failure)}"
TITLE="${2:?Second arg required: title string}"
REPORT_FILE="/tmp/security-report.md"

if [ ! -f "$REPORT_FILE" ]; then
  echo "Warning: $REPORT_FILE not found, using placeholder" >&2
  echo "_No report file was written._" > "$REPORT_FILE"
fi

# In advisory mode (BLOCKING=false), downgrade "failure" to "neutral"
# so the check shows as informational rather than blocking
CONCLUSION="$RAW_CONCLUSION"
if [ "${BLOCKING:-false}" = "false" ] && [ "$RAW_CONCLUSION" = "failure" ]; then
  CONCLUSION="neutral"
fi

# Build summary text
if [ "$RAW_CONCLUSION" = "failure" ]; then
  SUMMARY_TEXT="Security issues found — review the findings below before merging."
else
  SUMMARY_TEXT="No security issues found."
fi

# Use jq --arg for ALL values to prevent JSON injection
# jq -Rs reads stdin as a raw string and outputs a quoted JSON string
jq -n \
  --arg name "Security Review" \
  --arg sha "${HEAD_SHA:?HEAD_SHA env var required}" \
  --arg conclusion "$CONCLUSION" \
  --arg title "$TITLE" \
  --arg summary "$SUMMARY_TEXT" \
  --rawfile text "$REPORT_FILE" \
  '{
    "name": $name,
    "head_sha": $sha,
    "status": "completed",
    "conclusion": $conclusion,
    "output": {
      "title": $title,
      "summary": $summary,
      "text": $text
    }
  }' > /tmp/check-run-payload.json

GH_TOKEN="${SECURITY_GH_TOKEN:?SECURITY_GH_TOKEN env var required}" \
  gh api "repos/${REPO:?REPO env var required}/check-runs" \
  --method POST \
  --input /tmp/check-run-payload.json > /dev/null

echo "::notice::Security check run posted: ${CONCLUSION} (raw: ${RAW_CONCLUSION}) — ${TITLE}"
