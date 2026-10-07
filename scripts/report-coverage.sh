#!/usr/bin/env bash
set -uo pipefail

# Verify which truncated files Claude actually read, and write that into its review — the model's own claim is not trusted.
# Best effort: every failure is a warning, never a red job on a review that was posted.
# Inputs (env vars): GH_TOKEN, REPO, PR_NUMBER, HEAD_SHA, CLAUDE_OUTCOME, CLAUDE_OUTPUT_FILE, HAS_PREVIOUS, DIFF_INLINE
# Inputs (files): /tmp/truncated-files.txt
skip() { echo "::warning::Coverage check skipped — $1"; exit 0; }

[ "${CLAUDE_OUTCOME:-}" = "success" ] && [ -f "${CLAUDE_OUTPUT_FILE:-}" ] || exit 0

# Files Claude was told to read: each truncated file's diff, plus the whole diff when it was not inlined
: > /tmp/coverage-expected.txt
if [ "${DIFF_INLINE:-true}" = "false" ]; then echo "/tmp/pr-diff.txt" >> /tmp/coverage-expected.txt; fi
if [ -s /tmp/truncated-files.txt ]; then sed 's|^|/tmp/pr-diffs/|; s|$|.diff|' /tmp/truncated-files.txt >> /tmp/coverage-expected.txt; fi
[ -s /tmp/coverage-expected.txt ] || exit 0

# Strings from successful tool calls that read files: Read, and Bash reads (not `gh …` — Claude posts its review with `gh api -f body=…`)
jq -r '
  [.. | objects | select(.type == "tool_result" and .is_error == true) | .tool_use_id] as $failed
  | .. | objects | select(.type == "tool_use") | select(.id as $id | $failed | index($id) | not)
  | select(.name == "Read" or (.name == "Bash" and ((.input.command // "") | test("\\b(cat|head|tail|sed|awk|less)\\b") and (test("(^|[;&|]\\s*)gh\\s") | not))))
  | .input | .. | strings' "$CLAUDE_OUTPUT_FILE" > /tmp/coverage-tool-inputs.txt 2>/dev/null || skip "could not parse the execution output"

: > /tmp/coverage-unread.txt
while IFS= read -r path; do
  # Absolute path, or relative to /tmp/pr-diffs (after `cd`); bounded so a.ts.diff never matches a.ts.diff.diff
  rel="${path#/tmp/pr-diffs/}"
  re="(^|[^A-Za-z0-9._/-])(/tmp/pr-diffs/)?$(printf '%s' "$rel" | sed 's/[][\.*^$+?(){}|/]/\\&/g')([^A-Za-z0-9._/-]|$)"
  grep -qxF -- "$path" /tmp/coverage-tool-inputs.txt || grep -qE -- "$re" /tmp/coverage-tool-inputs.txt || echo "$path" >> /tmp/coverage-unread.txt
done < /tmp/coverage-expected.txt

TOTAL=$(wc -l < /tmp/coverage-expected.txt | tr -d ' ')
UNREAD=$(wc -l < /tmp/coverage-unread.txt | tr -d ' ')
if [ -s /tmp/truncated-files.txt ]; then HEAD_TXT="Diff was truncated."; else HEAD_TXT="Diff was too large to inline."; fi
if [ "$UNREAD" = 0 ]; then
  LINE="> **⚠️ ${HEAD_TXT}** Verified: Claude read all ${TOTAL} saved diffs."
else
  LIST=$(sed 's|^/tmp/pr-diffs/||; s|\.diff$||; s|^/tmp/pr-diff.txt$|(the full diff)|' /tmp/coverage-unread.txt | head -20 | awk '{ printf "%s`%s`", (NR > 1 ? ", " : ""), $0 }')
  if [ "$UNREAD" -gt 20 ]; then LIST="${LIST}, …"; fi
  LINE="> **⚠️ ${HEAD_TXT}** Verified: Claude read $((TOTAL - UNREAD))/${TOTAL} saved diffs. **Not reviewed:** ${LIST}"
fi

# The review this run posted for this commit (same selector as post-check-run.sh) — never an older one or a Q&A reply
REVIEWS=$(gh api --paginate "repos/${REPO}/pulls/${PR_NUMBER}/reviews") || skip "could not list reviews"
REVIEW=$(printf '%s' "$REVIEWS" | jq -sc --arg sha "${HEAD_SHA:-}" \
  'add | [.[] | select(.user.login == "claude[bot]" and ((.body // "") | test("Verdict")) and .commit_id == $sha)] | last | {id, state} // empty')
REVIEW_ID=$(printf '%s' "$REVIEW" | jq -r '.id // empty')
[ -n "$REVIEW_ID" ] || { echo "::notice::No Claude review for ${HEAD_SHA:0:7} — skipping coverage report (non-review action)"; exit 0; }

# A first review must not approve code it never read. Dismiss before editing, so a failed edit can't skip it.
# ponytail: re-reviews only get the line — they focus on new commits; dismiss there too if unread files are in those commits
if [ "$UNREAD" != 0 ] && [ "$(printf '%s' "$REVIEW" | jq -r .state)" = "APPROVED" ] && [ "${HAS_PREVIOUS:-false}" != "true" ]; then
  if gh api "repos/${REPO}/pulls/${PR_NUMBER}/reviews/${REVIEW_ID}/dismissals" --method PUT \
      -f message="Approval withdrawn: ${UNREAD} of ${TOTAL} truncated files were not reviewed" -f event=DISMISS > /dev/null; then
    echo "::warning::Approval dismissed — Claude did not read ${UNREAD}/${TOTAL} truncated files"
  else
    echo "::error::Could not dismiss the approval — Claude did not read ${UNREAD}/${TOTAL} truncated files"
  fi
fi

# Replace the model's own truncation lines with the verified one — never PUT if the body could not be fetched
gh api "repos/${REPO}/pulls/${PR_NUMBER}/reviews/${REVIEW_ID}" --jq '.body' > /tmp/review-body.raw 2>/dev/null || skip "could not fetch the review body"
[ -s /tmp/review-body.raw ] || skip "review body came back empty"
grep -vE -e '^> \*\*⚠[^ ]* Diff was (truncated|too large to inline)\.\*\*' -e '^> Files not reviewed:' /tmp/review-body.raw > /tmp/review-body.txt
printf '\n%s\n' "$LINE" >> /tmp/review-body.txt
jq -n --rawfile body /tmp/review-body.txt '{"body": $body}' \
  | gh api "repos/${REPO}/pulls/${PR_NUMBER}/reviews/${REVIEW_ID}" --method PUT --input - > /dev/null \
  || skip "could not update the review"
echo "::notice::Truncated coverage: read $((TOTAL - UNREAD))/${TOTAL}"
