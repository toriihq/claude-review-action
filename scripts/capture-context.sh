#!/usr/bin/env bash
set -euo pipefail

# Capture PR context: size check, diff (truncated), description.
# Inputs (env vars): GH_TOKEN, REPO, PR_NUMBER, MAX_FILES, MAX_CHANGED_LINES, EXCLUDE_PATHS, MAX_DIFF_LINES, MAX_DIFF_BYTES, INCLUDE_PR_DESCRIPTION
# Outputs (GITHUB_OUTPUT): file_count, changed_lines, diff_truncated, missing_file_count
# Outputs (files): /tmp/pr-diff.txt, /tmp/pr-description.txt, /tmp/truncated-files.txt, /tmp/excluded-files.txt, /tmp/pr-diffs/<path>.diff

# Diff header -> new path (single parser). Symmetric a/X b/X first so " b/" inside X is safe; greedy for renames.
# ponytail: quoted paths keep octal escapes; a rename whose new path holds " b/" mis-splits — parse `rename to` if it bites
header_paths() {
  awk '/^diff --git /{
    r = substr($0, 12); gsub(/"/, "", r); n = length(r); h = (n - 1) / 2
    if (n % 2 && substr(r, 1, 2) == "a/" && substr(r, h + 2, 2) == "b/" && substr(r, 3, h - 2) == substr(r, h + 4)) print substr(r, h + 4)
    else { sub(/^a\/.* b\//, "", r); print r }
  }' "$1"
}

# exclude-paths: one bash pattern per line, `*` also matches `/`
EXCLUDE_PATTERNS=()
while IFS= read -r pat; do
  pat="${pat#"${pat%%[![:space:]]*}"}"; pat="${pat%"${pat##*[![:space:]]}"}"
  [ -n "$pat" ] && EXCLUDE_PATTERNS+=("$pat")
done <<< "${EXCLUDE_PATHS:-}"
is_excluded() {
  local pat
  for pat in ${EXCLUDE_PATTERNS[@]+"${EXCLUDE_PATTERNS[@]}"}; do
    [[ "$1" == $pat ]] && return 0
  done
  return 1
}

# --- PR size guard ---
# REST, paginated: `gh pr view --json files` stops at 100 files
gh api --paginate "repos/$REPO/pulls/$PR_NUMBER/files" --jq '.[] | "\(.additions + .deletions)\t\(.filename)"' > /tmp/pr-files.tsv
: > /tmp/excluded-files.txt
FILE_COUNT=0
CHANGED_LINES=0
while IFS=$'\t' read -r lines path; do
  if is_excluded "$path"; then echo "$path" >> /tmp/excluded-files.txt; continue; fi
  FILE_COUNT=$((FILE_COUNT + 1))
  CHANGED_LINES=$((CHANGED_LINES + lines))
done < /tmp/pr-files.tsv
EXCLUDED_COUNT=$(wc -l < /tmp/excluded-files.txt | tr -d ' ')
EXCLUDED_NOTE=""
[ "$EXCLUDED_COUNT" -gt 0 ] && EXCLUDED_NOTE=", not counting $EXCLUDED_COUNT excluded files"
echo "file_count=$FILE_COUNT" >> "$GITHUB_OUTPUT"
echo "changed_lines=$CHANGED_LINES" >> "$GITHUB_OUTPUT"

skip_too_large() {
  gh pr comment "$PR_NUMBER" --repo "$REPO" \
    --body "⚠️ PR too large for automated review ($1${EXCLUDED_NOTE}, limit: $2). Please split into smaller PRs or review manually." || true
  echo "::notice::Review skipped — PR has $1 (limit: $2)"
  echo "skipped=true" >> "$GITHUB_OUTPUT"
  exit 0
}
if [ "$FILE_COUNT" -gt "$MAX_FILES" ]; then skip_too_large "$FILE_COUNT files" "$MAX_FILES"; fi
if [ -n "${MAX_CHANGED_LINES:-}" ] && [ "$CHANGED_LINES" -gt "$MAX_CHANGED_LINES" ]; then
  skip_too_large "$CHANGED_LINES changed lines" "$MAX_CHANGED_LINES"
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

# Drop excluded files before truncation so they don't use the diff budget
if [ "$EXCLUDED_COUNT" -gt 0 ]; then
  # Diff headers octal-escape non-ASCII bytes (caf\303\251.ts); decode to match the REST paths
  header_paths /tmp/pr-diff.txt | while IFS= read -r f; do
    is_excluded "$(printf '%b' "$(sed 's/\\\([0-7][0-7][0-7]\)/\\0\1/g' <<< "$f")")" && echo 0 || echo 1
  done > /tmp/pr-diff-keep.txt
  awk '/^diff --git /{ getline keep < "/tmp/pr-diff-keep.txt" } keep != "0"' /tmp/pr-diff.txt > /tmp/pr-diff-kept.txt
  mv /tmp/pr-diff-kept.txt /tmp/pr-diff.txt
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
