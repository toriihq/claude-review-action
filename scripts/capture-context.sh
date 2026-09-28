#!/usr/bin/env bash
set -euo pipefail

# Capture PR context: size check, diff (truncated), description.
# Inputs (env vars): GH_TOKEN, REPO, PR_NUMBER, MAX_FILES, MAX_DIFF_LINES, MAX_DIFF_BYTES, INCLUDE_PR_DESCRIPTION
# Outputs (GITHUB_OUTPUT): file_count, diff_truncated, missing_file_count
# Outputs (files): /tmp/pr-diff.txt, /tmp/pr-description.txt, /tmp/truncated-files.txt, /tmp/pr-diffs/<path>.diff

# --- PR size guard ---
FILE_COUNT=$(gh pr view "$PR_NUMBER" --repo "$REPO" --json files --jq '.files | length')
echo "file_count=$FILE_COUNT" >> "$GITHUB_OUTPUT"

if [ "$FILE_COUNT" -gt "$MAX_FILES" ]; then
  gh pr comment "$PR_NUMBER" --repo "$REPO" \
    --body "⚠️ PR too large for automated review ($FILE_COUNT files, limit: $MAX_FILES). Please split into smaller PRs or review manually." || true
  echo "::notice::Review skipped — PR has $FILE_COUNT files (limit: $MAX_FILES)"
  echo "skipped=true" >> "$GITHUB_OUTPUT"
  exit 0
fi

# --- Capture diff ---
if ! gh pr diff "$PR_NUMBER" --repo "$REPO" > /tmp/pr-diff.txt 2>/tmp/diff-error.txt; then
  DIFF_ERROR=$(cat /tmp/diff-error.txt)
  if echo "$DIFF_ERROR" | grep -qi "too_large\|exceeded.*maximum\|406"; then
    gh pr comment "$PR_NUMBER" --repo "$REPO" \
      --body "⚠️ **Claude review skipped** — PR diff exceeds GitHub's 20,000-line API limit. Please split into smaller PRs or review manually." || true
    echo "::error::Review skipped — PR diff too large for GitHub API (HTTP 406)"
  else
    gh pr comment "$PR_NUMBER" --repo "$REPO" \
      --body "⚠️ **Claude review failed** — could not fetch PR diff. Error: \`${DIFF_ERROR}\`" || true
    echo "::error::Failed to fetch PR diff: $DIFF_ERROR"
  fi
  echo "skipped=true" >> "$GITHUB_OUTPUT"
  exit 0
fi

cp /tmp/pr-diff.txt /tmp/pr-diff-full.txt

# Track whether truncation occurs
TRUNCATED=false

# Truncate by line count
LINES=$(wc -l < /tmp/pr-diff.txt)
if [ "$LINES" -gt "$MAX_DIFF_LINES" ]; then
  TRUNCATED=true
  head -"$MAX_DIFF_LINES" /tmp/pr-diff.txt > /tmp/pr-diff-truncated.txt
  echo "" >> /tmp/pr-diff-truncated.txt
  echo "... [diff truncated — $LINES total lines, showing first $MAX_DIFF_LINES. See DIFF TRUNCATED below for the missing files.]" >> /tmp/pr-diff-truncated.txt
  mv /tmp/pr-diff-truncated.txt /tmp/pr-diff.txt
fi

# Truncate by byte size
BYTES=$(wc -c < /tmp/pr-diff.txt | tr -d ' ')
if [ "$BYTES" -gt "$MAX_DIFF_BYTES" ]; then
  TRUNCATED=true
  head -c "$MAX_DIFF_BYTES" /tmp/pr-diff.txt > /tmp/pr-diff-truncated.txt
  echo "" >> /tmp/pr-diff-truncated.txt
  echo "... [diff truncated — ${BYTES} bytes total, showing first $MAX_DIFF_BYTES. See DIFF TRUNCATED below for the missing files.]" >> /tmp/pr-diff-truncated.txt
  mv /tmp/pr-diff-truncated.txt /tmp/pr-diff.txt
fi

echo "::notice::PR diff captured ($LINES lines, $(wc -c < /tmp/pr-diff.txt | tr -d ' ') bytes)"
echo "diff_truncated=$TRUNCATED" >> "$GITHUB_OUTPUT"

# --- Detect files missing from truncated diff ---
: > /tmp/truncated-files.txt
if [ "$TRUNCATED" = "true" ]; then
  # Diff header -> new path (single parser). Symmetric a/X b/X first so " b/" inside X is safe; greedy for renames.
  # ponytail: quoted paths keep octal escapes; a rename whose new path holds " b/" mis-splits — parse `rename to` if it bites
  header_paths() {
    awk '/^diff --git /{
      r = substr($0, 12); gsub(/"/, "", r); n = length(r); h = (n - 1) / 2
      if (n % 2 && substr(r, 1, 2) == "a/" && substr(r, h + 2, 2) == "b/" && substr(r, 3, h - 2) == substr(r, h + 4)) print substr(r, h + 4)
      else { sub(/^a\/.* b\//, "", r); print r }
    }' "$1"
  }
  header_paths /tmp/pr-diff-full.txt > /tmp/pr-diff-paths.txt
  sort -u /tmp/pr-diff-paths.txt > /tmp/all-pr-files.txt
  HEADER_COUNT=$(wc -l < /tmp/pr-diff-paths.txt | tr -d ' ')
  [ "$HEADER_COUNT" = "$FILE_COUNT" ] || echo "::warning::Diff has $HEADER_COUNT file headers but the PR lists $FILE_COUNT files"
  # Files fully in the truncated diff — the last header is the one cut mid-way, so it counts as missing
  header_paths /tmp/pr-diff.txt | sed '$d' | sort -u > /tmp/included-files.txt
  # Split the full diff per file so missing files are reviewed as diffs (paths never reach a shell)
  rm -rf /tmp/pr-diffs
  while IFS= read -r f; do mkdir -p "/tmp/pr-diffs/$(dirname "$f")"; done < /tmp/pr-diff-paths.txt
  awk '/^diff --git /{ if (out) close(out); getline f < "/tmp/pr-diff-paths.txt"; out = "/tmp/pr-diffs/" f ".diff" }
    out { print > out }' /tmp/pr-diff-full.txt
  # Files in PR but not fully in truncated diff
  comm -23 /tmp/all-pr-files.txt /tmp/included-files.txt > /tmp/truncated-files.txt
  MISSING_COUNT=$(wc -l < /tmp/truncated-files.txt | tr -d ' ')
  echo "missing_file_count=$MISSING_COUNT" >> "$GITHUB_OUTPUT"
  echo "::notice::Diff truncated — $MISSING_COUNT files not included in diff"
else
  echo "missing_file_count=0" >> "$GITHUB_OUTPUT"
fi

# --- Capture PR description ---
if [ "$INCLUDE_PR_DESCRIPTION" = "true" ]; then
  gh pr view "$PR_NUMBER" --repo "$REPO" \
    --json title,body --jq '"# " + .title + "\n\n" + (.body // "")' \
    > /tmp/pr-description.txt 2>/dev/null || : > /tmp/pr-description.txt
  echo "::notice::PR description captured ($(wc -c < /tmp/pr-description.txt | tr -d ' ') bytes)"
else
  : > /tmp/pr-description.txt
fi
