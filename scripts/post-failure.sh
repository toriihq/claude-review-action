#!/usr/bin/env bash
set -euo pipefail

# Post a failure comment on the PR with typed error messages, and fail the job when Claude never ran.
# Inputs (env vars): GH_TOKEN, REPO, PR_NUMBER, RUN_URL, MAX_TURNS, TIMEOUT_MINUTES, CLAUDE_OUTCOME
# Outputs (GITHUB_OUTPUT): did_not_run

# execution_file output of claude-code-action — empty when it skipped itself
OUTPUT_FILE="${CLAUDE_OUTPUT_FILE:-}"

# claude-code-action exits "success" without running when it skips itself (e.g. workflow file differs from the default branch)
if [ "${CLAUDE_OUTCOME:?}" = "success" ] && [ -f "$OUTPUT_FILE" ]; then
  exit 0
fi

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
  [ "$CLAUDE_OUTCOME" = "success" ] && echo "did_not_run=true" >> "$GITHUB_OUTPUT"
  BODY="❌ **Claude review did not run** — no review was produced. This usually means the workflow file on this branch differs from the default branch: merge the default branch into this PR and re-trigger the review. [Workflow run](${RUN_URL})"
fi

gh pr comment "$PR_NUMBER" --repo "$REPO" --body "$BODY" || true
echo "::notice::Failure comment posted: ${ERROR_TYPE:-no-output}"

if [ "$CLAUDE_OUTCOME" = "success" ]; then
  echo "::error::Claude review did not run — failing so the check is not green without a review"
  exit 1
fi
