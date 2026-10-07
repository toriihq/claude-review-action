#!/usr/bin/env bash
set -euo pipefail

# Post the code-review verdict as a GitHub Check Run by reading back the PR review
# Claude posted for the current HEAD SHA. Deterministic — does not depend on Claude
# calling anything. Mirrors the SHA-anchored read-back in detect-previous.sh.
#
# Inputs (env vars): GH_TOKEN, REPO, PR_NUMBER, HEAD_SHA, BLOCKING, CHECK_NAME, RUN_URL
# Posts a check run via: POST /repos/{REPO}/check-runs  (needs checks:write)

# --- Find the review for THIS commit (SHA-anchored, login + Verdict filtered) ---
read_review_field() {
  # $1 = jq field to extract (.state / .body)
  # HEAD_SHA is passed as a jq --arg (never interpolated into the program text).
  gh api "repos/${REPO}/pulls/${PR_NUMBER}/reviews" \
    | jq -r --arg sha "${HEAD_SHA}" \
        "[.[] | select(.user.login == \"claude[bot]\" and (.body | test(\"Verdict\")) and .commit_id == \$sha)] | last | $1 // empty"
}

# --- Bounded retry for cross-token replication lag (review posted under app token) ---
STATE=""
for attempt in 1 2 3; do
  STATE=$(read_review_field '.state')
  [ -n "$STATE" ] && break
  echo "::notice::No review for ${HEAD_SHA} yet (attempt ${attempt}) — retrying"
  sleep 2
done

if [ -z "$STATE" ]; then
  echo "::warning::No Claude review found for ${HEAD_SHA} after retries — posting neutral check"
  CONCLUSION="neutral"
  BODY="_No review was found for this commit. The check could not determine a verdict._"
  TITLE="No verdict available"
else
  BODY=$(read_review_field '.body')
  [ -z "$BODY" ] && BODY="_(review body empty)_"
  case "$STATE" in
    CHANGES_REQUESTED)
      TITLE="Changes requested"
      if [ "${BLOCKING:-false}" = "true" ]; then CONCLUSION="failure"; else CONCLUSION="neutral"; fi
      ;;
    DISMISSED)  # report-coverage.sh withdrew an approval given without reading the truncated files
      TITLE="Approval withdrawn — truncated files not reviewed"
      CONCLUSION="neutral"
      ;;
    APPROVED)
      TITLE="Approved"
      CONCLUSION="success"
      ;;
    *)  # COMMENTED or anything else
      TITLE="Reviewed (comments)"
      CONCLUSION="neutral"
      ;;
  esac
fi

# --- Build payload with jq --arg/--rawfile (JSON-injection safe) ---
jq -n \
  --arg name "${CHECK_NAME:-Claude Code Review}" \
  --arg sha "${HEAD_SHA:?HEAD_SHA env var required}" \
  --arg conclusion "$CONCLUSION" \
  --arg title "$TITLE" \
  --arg summary "Verdict from the Claude code review for this commit." \
  --rawfile text <(printf '%s' "$BODY") \
  '{
    "name": $name,
    "head_sha": $sha,
    "status": "completed",
    "conclusion": $conclusion,
    "output": { "title": $title, "summary": $summary, "text": $text }
  }' > /tmp/check-run-payload.json

# --- Post; surface HTTP status on failure (e.g. 403 = missing checks:write) ---
if ! gh api "repos/${REPO:?REPO env var required}/check-runs" \
      --method POST --input /tmp/check-run-payload.json > /tmp/check-run-resp.json 2>/tmp/check-run-err.txt; then
  echo "::warning::Failed to post check run (conclusion=${CONCLUSION}). gh error: $(cat /tmp/check-run-err.txt)"
  echo "::warning::A 403 here usually means the consumer workflow lacks 'checks: write' permission."
  exit 0
fi

echo "::notice::Check run posted: ${CONCLUSION} — ${TITLE}"
