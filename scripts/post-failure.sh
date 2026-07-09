#!/usr/bin/env bash
set -euo pipefail

# Post a failure comment on the PR with typed error messages.
# Inputs (env vars): GH_TOKEN, REPO, PR_NUMBER, RUN_URL, MAX_TURNS, TIMEOUT_MINUTES

OUTPUT_FILE="/home/runner/work/_temp/claude-execution-output.json"

if [ -f "$OUTPUT_FILE" ]; then
  # Output may be a JSON array or object — normalize to object
  ERROR_TYPE=$(jq -r '(if type == "array" then last else . end) | .subtype // empty' "$OUTPUT_FILE")

  case "$ERROR_TYPE" in
    error_max_turns)
      BODY="⚠️ Review incomplete — Claude hit the ${MAX_TURNS} turn limit. The PR may be too large or complex for automated review. [Action logs](${RUN_URL})"
      ;;
    *)
      BODY="⚠️ Claude review failed. Check the [action logs](${RUN_URL}) for details."
      ;;
  esac
else
  # No output file — the SDK likely crashed before producing output (e.g. credit errors, auth errors).
  # Try to extract the actual error from the current job's check-run annotations.
  SDK_ERROR=""
  if [ -n "${GITHUB_RUN_ID:-}" ] && [ -n "${REPO:-}" ]; then
    JOB_ID=$(gh api "repos/${REPO}/actions/runs/${GITHUB_RUN_ID}/jobs" \
      --jq ".jobs[] | select(.name == \"${GITHUB_JOB:-claude-review}\") | .id" 2>/dev/null || true)
    if [ -n "$JOB_ID" ]; then
      RAW_ERROR=$(gh api "repos/${REPO}/check-runs/${JOB_ID}/annotations" \
        --jq '[.[] | select(.annotation_level == "failure") | .message] | last // empty' 2>/dev/null || true)
      # Strip nested prefixes to get the core error message
      SDK_ERROR=$(echo "$RAW_ERROR" \
        | sed 's/^Action failed with error: //' \
        | sed 's/^SDK execution error: //' \
        | sed 's/^Error: //' \
        | sed 's/^Claude Code returned an error result: //')
    fi
  fi

  if [ -n "$SDK_ERROR" ]; then
    BODY="❌ Review failed — ${SDK_ERROR}. Check the [workflow run](${RUN_URL}) for details."
  else
    BODY="❌ Review failed — no execution output produced. This usually means the workflow file on this branch differs from the default branch. Check the [workflow run](${RUN_URL})."
  fi
fi

gh pr comment "$PR_NUMBER" --repo "$REPO" --body "$BODY" || true
echo "::notice::Failure comment posted: ${ERROR_TYPE:-no-output}"
