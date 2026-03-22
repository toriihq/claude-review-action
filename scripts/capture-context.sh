#!/usr/bin/env bash
set -euo pipefail

# Capture PR context: size check, diff (truncated), description.
# Inputs (env vars): GH_TOKEN, REPO, PR_NUMBER, MAX_FILES, MAX_DIFF_LINES, MAX_DIFF_BYTES, INCLUDE_PR_DESCRIPTION, REVIEW_DEPTH, DEEP_MAX_FILES
# Outputs (GITHUB_OUTPUT): file_count, diff_truncated
# Outputs (files): /tmp/pr-diff.txt, /tmp/pr-description.txt, /tmp/truncated-files.txt

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

if [ "${REVIEW_DEPTH:-normal}" = "deep" ]; then
  # --- Deep mode: per-file diffs ---

  # Deep mode has its own file limit (cost scales faster)
  if [ "$FILE_COUNT" -gt "$DEEP_MAX_FILES" ]; then
    gh pr comment "$PR_NUMBER" --repo "$REPO" \
      --body "⚠️ PR too large for deep review ($FILE_COUNT files, deep limit: $DEEP_MAX_FILES). Remove the \`claude-deep-review\` label and apply \`claude-review\` for a normal review, or split the PR." || true
    echo "::notice::Deep review skipped — PR has $FILE_COUNT files (deep limit: $DEEP_MAX_FILES)"
    echo "skipped=true" >> "$GITHUB_OUTPUT"
    exit 0
  fi

  # Fetch base branch for git diff (checkout is shallow, fetch-depth: 1)
  BASE_BRANCH=$(gh pr view "$PR_NUMBER" --repo "$REPO" --json baseRefName --jq '.baseRefName')
  git fetch origin "$BASE_BRANCH" --depth=1

  # Clean up any stale diffs (defensive for self-hosted runners)
  rm -rf /tmp/diffs
  mkdir -p /tmp/diffs

  # Get changed files with stats
  gh pr view "$PR_NUMBER" --repo "$REPO" --json files \
    --jq '.files[] | [.path, .additions, .deletions] | @tsv' > /tmp/changed-files-stats.txt

  # Generate per-file diffs with 20 lines of surrounding context
  # Two-dot diff (not three-dot) — works with shallow clones because
  # both commits' trees are available after depth=1 fetches
  while IFS=$'\t' read -r filepath additions deletions; do
    mkdir -p "/tmp/diffs/$(dirname "$filepath")"
    git diff "origin/${BASE_BRANCH}" HEAD -U20 -- "$filepath" \
      > "/tmp/diffs/${filepath}.diff" 2>/dev/null || true
  done < /tmp/changed-files-stats.txt

  # Write manifest
  {
    echo "# Changed Files"
    echo "| File | Lines Added | Lines Removed |"
    echo "|------|------------|---------------|"
    while IFS=$'\t' read -r filepath additions deletions; do
      echo "| \`$filepath\` | +$additions | -$deletions |"
    done < /tmp/changed-files-stats.txt
  } > /tmp/diff-manifest.txt

  TOTAL_FILES=$(wc -l < /tmp/changed-files-stats.txt | tr -d ' ')
  echo "::notice::Deep mode — generated per-file diffs for $TOTAL_FILES files"
  echo "diff_truncated=false" >> "$GITHUB_OUTPUT"
  : > /tmp/pr-diff.txt        # Empty — not used in deep mode
  : > /tmp/truncated-files.txt # Empty — no truncation in deep mode

else
  # --- Normal mode: existing behavior (unchanged) ---

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

  # Track whether truncation occurs
  TRUNCATED=false

  # Truncate by line count
  LINES=$(wc -l < /tmp/pr-diff.txt)
  if [ "$LINES" -gt "$MAX_DIFF_LINES" ]; then
    TRUNCATED=true
    head -"$MAX_DIFF_LINES" /tmp/pr-diff.txt > /tmp/pr-diff-truncated.txt
    echo "" >> /tmp/pr-diff-truncated.txt
    echo "... [diff truncated — $LINES total lines, showing first $MAX_DIFF_LINES. Use Read tool on specific files for full context.]" >> /tmp/pr-diff-truncated.txt
    mv /tmp/pr-diff-truncated.txt /tmp/pr-diff.txt
  fi

  # Truncate by byte size
  BYTES=$(wc -c < /tmp/pr-diff.txt | tr -d ' ')
  if [ "$BYTES" -gt "$MAX_DIFF_BYTES" ]; then
    TRUNCATED=true
    head -c "$MAX_DIFF_BYTES" /tmp/pr-diff.txt > /tmp/pr-diff-truncated.txt
    echo "" >> /tmp/pr-diff-truncated.txt
    echo "... [diff truncated — ${BYTES} bytes total, showing first $MAX_DIFF_BYTES. Use Read tool on specific files for full context.]" >> /tmp/pr-diff-truncated.txt
    mv /tmp/pr-diff-truncated.txt /tmp/pr-diff.txt
  fi

  echo "::notice::PR diff captured ($LINES lines, $(wc -c < /tmp/pr-diff.txt | tr -d ' ') bytes)"
  echo "diff_truncated=$TRUNCATED" >> "$GITHUB_OUTPUT"

  # --- Detect files missing from truncated diff ---
  : > /tmp/truncated-files.txt
  if [ "$TRUNCATED" = "true" ]; then
    gh pr view "$PR_NUMBER" --repo "$REPO" --json files --jq '.files[].path' | sort > /tmp/all-pr-files.txt
    grep -oP '(?<=^diff --git a/).+(?= b/)' /tmp/pr-diff.txt | sort -u > /tmp/included-files.txt || true
    comm -23 /tmp/all-pr-files.txt /tmp/included-files.txt > /tmp/truncated-files.txt
    MISSING_COUNT=$(wc -l < /tmp/truncated-files.txt | tr -d ' ')
    echo "::notice::Diff truncated — $MISSING_COUNT files not included in diff"
  fi
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
