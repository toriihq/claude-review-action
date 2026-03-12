#!/usr/bin/env bash
set -euo pipefail

# Detect previous Claude reviews and calculate relevant new commits.
# Inputs (env vars): GH_TOKEN, REPO, PR_NUMBER, EVENT_TYPE, SKIP_IF_ALREADY_REVIEWED
# Outputs (GITHUB_OUTPUT): has_previous, last_review_date, has_new_commits, commits
# Outputs (files): /tmp/previous-review.txt

# --- Find last Claude review ---
# Fetch date, commit SHA, and body in one API call (reviews API first, comments fallback).
LAST_REVIEW_JSON=$(gh api "repos/${REPO}/pulls/${PR_NUMBER}/reviews" \
  --jq '[.[] | select(.user.login == "claude[bot]" and (.body | test("Verdict")))] | last // empty')

LAST_REVIEW_DATE=""
LAST_REVIEW_COMMIT=""
LAST_REVIEW_BODY=""

if [ -n "$LAST_REVIEW_JSON" ] && [ "$LAST_REVIEW_JSON" != "null" ]; then
  LAST_REVIEW_DATE=$(echo "$LAST_REVIEW_JSON" | jq -r '.submitted_at // empty')
  LAST_REVIEW_COMMIT=$(echo "$LAST_REVIEW_JSON" | jq -r '.commit_id // empty')
  LAST_REVIEW_BODY=$(echo "$LAST_REVIEW_JSON" | jq -r '.body // empty')
fi

# Fallback: comments API (older format — no commit_id available)
if [ -z "$LAST_REVIEW_DATE" ]; then
  LAST_COMMENT_JSON=$(gh api "repos/${REPO}/issues/${PR_NUMBER}/comments" \
    --jq '[.[] | select(.user.login == "claude[bot]" and (.body | test("Verdict")))] | last // empty')

  if [ -n "$LAST_COMMENT_JSON" ] && [ "$LAST_COMMENT_JSON" != "null" ]; then
    LAST_REVIEW_DATE=$(echo "$LAST_COMMENT_JSON" | jq -r '.created_at // empty')
    LAST_REVIEW_BODY=$(echo "$LAST_COMMENT_JSON" | jq -r '.body // empty')
  fi
fi

echo "${LAST_REVIEW_BODY:-}" > /tmp/previous-review.txt

# --- No previous review → first review mode ---
if [ -z "$LAST_REVIEW_DATE" ]; then
  echo "has_previous=false" >> "$GITHUB_OUTPUT"
  echo "has_new_commits=false" >> "$GITHUB_OUTPUT"
  echo "last_review_date=" >> "$GITHUB_OUTPUT"
  echo "commits=" >> "$GITHUB_OUTPUT"
  echo "::notice::First review — no previous Claude review found"
  exit 0
fi

echo "has_previous=true" >> "$GITHUB_OUTPUT"
echo "last_review_date=$LAST_REVIEW_DATE" >> "$GITHUB_OUTPUT"

# --- Detect new commits: SHA comparison (pagination-proof) ---
# The reviews API returns commit_id (the SHA the review was submitted on).
# Comparing it to the current HEAD avoids the gh pr view --json commits pagination
# limit (default first:100), which silently drops newer commits on large PRs.
CURRENT_HEAD=$(gh pr view "$PR_NUMBER" --repo "$REPO" --json headRefOid --jq '.headRefOid')

if [ -n "$LAST_REVIEW_COMMIT" ] && [ "$LAST_REVIEW_COMMIT" = "$CURRENT_HEAD" ]; then
  # HEAD hasn't changed since last review — no new commits
  echo "has_new_commits=false" >> "$GITHUB_OUTPUT"
  echo "commits=" >> "$GITHUB_OUTPUT"

  if [ "$SKIP_IF_ALREADY_REVIEWED" = "true" ] && [ "$EVENT_TYPE" = "pull_request" ]; then
    gh pr comment "$PR_NUMBER" --repo "$REPO" \
      --body "ℹ️ Skipping review — no new commits since the last Claude review. Push new commits to trigger a fresh review." || true
    echo "::notice::Review skipped — HEAD ($CURRENT_HEAD) unchanged since last review"
    exit 1
  fi
  exit 0
fi

# --- HEAD changed: fetch recent commits for focus context ---
# Use GraphQL commits(last:50) to get the most recent commits, avoiding the
# first:100 pagination limit that caused the original bug.
BASE_BRANCH=$(gh pr view "$PR_NUMBER" --repo "$REPO" --json baseRefName --jq '.baseRefName')
git fetch origin "$BASE_BRANCH" --depth=1

OWNER="${REPO%%/*}"
REPO_NAME="${REPO##*/}"

NEW_SHAS=$(gh api graphql -f query="
  { repository(owner:\"${OWNER}\", name:\"${REPO_NAME}\") {
    pullRequest(number:${PR_NUMBER}) {
      commits(last:50) {
        nodes { commit { oid committedDate } }
      }
    }
  }}" --jq "[.data.repository.pullRequest.commits.nodes[].commit | select(.committedDate > \"${LAST_REVIEW_DATE}\")] | .[].oid")

if [ -z "$NEW_SHAS" ]; then
  # HEAD changed but no commits found after review date. This can happen when
  # commit dates diverge from push order, or when the review came from the
  # comments API (no commit_id). Force a re-review since HEAD did change.
  echo "has_new_commits=true" >> "$GITHUB_OUTPUT"
  SHORT_HEAD="${CURRENT_HEAD:0:7}"
  echo "::notice::HEAD changed (${SHORT_HEAD}) but no commits found after review date — forcing re-review"
  {
    echo "commits<<EOF_COMMITS_${GITHUB_RUN_ID}"
    echo "${SHORT_HEAD} (new commits since last review)"
    echo "EOF_COMMITS_${GITHUB_RUN_ID}"
  } >> "$GITHUB_OUTPUT"
  exit 0
fi

echo "has_new_commits=true" >> "$GITHUB_OUTPUT"

# --- Filter to relevant commits (files that contribute to PR diff vs base) ---
RELEVANT_COMMITS=""
for SHA in $NEW_SHAS; do
  COMMIT_JSON=$(gh api "repos/${REPO}/commits/${SHA}" 2>/dev/null) || continue
  COMMIT_FILES=$(echo "$COMMIT_JSON" | jq -r '[.files[].filename] | join("\n")' 2>/dev/null)
  [ -z "$COMMIT_FILES" ] && continue

  # If any file from this commit differs between base and HEAD, the commit is relevant
  mapfile -t FILES <<< "$COMMIT_FILES"
  if ! git diff --quiet "origin/${BASE_BRANCH}" HEAD -- "${FILES[@]}" 2>/dev/null; then
    SHORT_SHA="${SHA:0:7}"
    MSG=$(echo "$COMMIT_JSON" | jq -r '.commit.message | split("\n") | .[0]')
    RELEVANT_COMMITS="${RELEVANT_COMMITS}${SHORT_SHA} ${MSG}\n"
  fi
done

NEW_COMMITS=$(printf '%b' "$RELEVANT_COMMITS" | sed '/^$/d')

if [ -n "$NEW_COMMITS" ]; then
  {
    echo "commits<<EOF_COMMITS_${GITHUB_RUN_ID}"
    echo "$NEW_COMMITS"
    echo "EOF_COMMITS_${GITHUB_RUN_ID}"
  } >> "$GITHUB_OUTPUT"
else
  echo "::notice::New commits found but none contribute to PR diff (likely merge/CI-only)"
  echo "commits=" >> "$GITHUB_OUTPUT"

  # Same skip logic applies when commits exist but none are relevant
  if [ "$SKIP_IF_ALREADY_REVIEWED" = "true" ] && [ "$EVENT_TYPE" = "pull_request" ]; then
    gh pr comment "$PR_NUMBER" --repo "$REPO" \
      --body "ℹ️ Skipping review — new commits since last review don't affect the PR diff (likely merge/CI-only). Push code changes to trigger a fresh review." || true
    echo "::notice::Review skipped — no relevant new commits"
    exit 1
  fi
fi
