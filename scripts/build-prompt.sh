#!/usr/bin/env bash
set -euo pipefail

# Assemble the full review prompt from inputs, captured context, and templates.
# Inputs (env vars): ACTION_PATH, REPO, PR_NUMBER, EVENT_TYPE, USER_COMMENT,
#   HAS_PREVIOUS, NEW_COMMITS, INCLUDE_PREVIOUS_REVIEW, CONTEXT_INTRO, CRITICAL_RULES,
#   EXTRA_PROMPT, REVIEW_AUTHORITY, APPROVE_THRESHOLD, APPROVE_MAX_FILES,
#   DISMISS_PREVIOUS_REVIEWS, FILE_COUNT
# Outputs (GITHUB_OUTPUT): prompt

PROMPT_FILE="/tmp/claude-prompt.md"

# --- Sections 1+2: Context intro + PR_NUMBER/REPO (merged into one heredoc) ---
cat > "$PROMPT_FILE" <<INTRO_END
${CONTEXT_INTRO}

PR_NUMBER: ${PR_NUMBER}
REPO: ${REPO}
INTRO_END

# --- Section 3: PR description (if enabled and non-trivial) ---
if [ -s /tmp/pr-description.txt ]; then
  PR_DESC_LENGTH=$(wc -c < /tmp/pr-description.txt | tr -d ' ')
  if [ "$PR_DESC_LENGTH" -gt 20 ]; then
    cat >> "$PROMPT_FILE" <<'PR_DESC_HEADER'

## PR DESCRIPTION (author's stated intent):
> Note: This description was written at PR creation time. It may not reflect later changes
> from review feedback or follow-up commits. Use it as context for the author's intent,
> but always trust the actual diff as the source of truth.

PR_DESC_HEADER
    cat /tmp/pr-description.txt >> "$PROMPT_FILE"
  else
    echo "" >> "$PROMPT_FILE"
    echo "_No meaningful PR description was provided._" >> "$PROMPT_FILE"
  fi
fi

# --- Section 4: User comment + routing (if comment trigger) ---
if [ "$EVENT_TYPE" = "issue_comment" ] || [ "$EVENT_TYPE" = "pull_request_review_comment" ]; then
  cat >> "$PROMPT_FILE" <<COMMENT_END

## USER COMMENT:
${USER_COMMENT}

If the user is asking for a code review, follow the REVIEW FORMAT and CRITICAL RULES below.
If the user is asking a question or making a specific request, respond to their message directly — use the PR diff and codebase for context, but skip the formal review format. Submit your response using:
  gh api repos/${REPO}/pulls/${PR_NUMBER}/reviews --method POST -f event=COMMENT -f body="your response"
COMMENT_END
fi

# --- Section 5: Critical rules (if provided) ---
if [ -n "$CRITICAL_RULES" ]; then
  cat >> "$PROMPT_FILE" <<RULES_END

CRITICAL RULES (violations are BLOCKERS):
${CRITICAL_RULES}
RULES_END
fi

# --- Section 6: Review guide (if fetched) ---
if [ -s /tmp/review-guide.md ]; then
  echo "" >> "$PROMPT_FILE"
  cat /tmp/review-guide.md >> "$PROMPT_FILE"
fi

# --- Section 7: PR diff ---
cat >> "$PROMPT_FILE" <<'DIFF_HEADER'

---

## PR DIFF:
```diff
DIFF_HEADER

cat /tmp/pr-diff.txt >> "$PROMPT_FILE"
echo '```' >> "$PROMPT_FILE"

# --- Section 7b: Truncated files list (if diff was truncated) ---
if [ -s /tmp/truncated-files.txt ]; then
  MISSING_COUNT=$(wc -l < /tmp/truncated-files.txt | tr -d ' ')
  cat >> "$PROMPT_FILE" <<TRUNC_HEADER

## ⚠️ DIFF TRUNCATED — ${MISSING_COUNT} files not shown

The following files are part of this PR but were cut off by the diff size limit.
You MUST read and review ALL of these files using the Read tool before submitting your review.
Prioritize reading order by risk:
1. Files matching CRITICAL RULES patterns (routes, DB queries, Lambda invokes)
2. Files with security-sensitive names (auth, permissions, secrets, credentials)
3. New files (more likely to have issues than modifications)
4. All remaining files

**Files not in diff:**
TRUNC_HEADER
  while IFS= read -r file; do
    echo "- \`$file\`" >> "$PROMPT_FILE"
  done < /tmp/truncated-files.txt
fi

# --- Section 8: Focus info (re-review with new commits — always shown, even without reconciliation) ---
if [ "$HAS_PREVIOUS" = "true" ] && [ -n "$NEW_COMMITS" ]; then
  cat >> "$PROMPT_FILE" <<FOCUS_END

## FOCUS: This is a re-review. New commits since last review:
${NEW_COMMITS}

Prioritize reviewing the new commits, but use the full diff above for context.
FOCUS_END
fi

# --- Section 9: Reconciliation block (re-review + include-previous-review) ---
if [ "$HAS_PREVIOUS" = "true" ] && [ "$INCLUDE_PREVIOUS_REVIEW" = "true" ] && [ -s /tmp/previous-review.txt ]; then
  echo "" >> "$PROMPT_FILE"
  echo "---" >> "$PROMPT_FILE"
  echo "" >> "$PROMPT_FILE"
  cat "${ACTION_PATH}/templates/reconciliation.md" >> "$PROMPT_FILE"

  cat >> "$PROMPT_FILE" <<'PREV_REVIEW_HEADER'

### Your previous review:
PREV_REVIEW_HEADER
  cat /tmp/previous-review.txt >> "$PROMPT_FILE"

  # Author comments
  if [ -s /tmp/author-comments.txt ]; then
    cat >> "$PROMPT_FILE" <<'AUTHOR_HEADER'

### Author's responses since your review:
The PR author posted these comments after your previous review.
Use them when reconciling findings — if the author provided a technical
justification for a finding, you can reference it in your ACCEPTED resolution.

AUTHOR_HEADER
    cat /tmp/author-comments.txt >> "$PROMPT_FILE"
  fi
fi

# --- Section 10: Review instructions + authority-specific submission ---
echo "" >> "$PROMPT_FILE"
echo "---" >> "$PROMPT_FILE"
echo "" >> "$PROMPT_FILE"
cat "${ACTION_PATH}/templates/review-instructions.md" >> "$PROMPT_FILE"

# Dismissal instructions (if enabled)
if [ "$DISMISS_PREVIOUS_REVIEWS" = "true" ]; then
  cat >> "$PROMPT_FILE" <<'DISMISS_BLOCK'

DISMISSING PREVIOUS REVIEWS:
Before submitting your new review, dismiss previous Claude reviews so only the latest is visible.
Run this SINGLE command (it checks and dismisses in one step — no separate check needed):
  REVIEW_IDS=$(gh api repos/$REPO/pulls/$PR_NUMBER/reviews --jq '[.[] | select(.user.login == "claude[bot]" and (.state == "APPROVED" or .state == "CHANGES_REQUESTED" or .state == "COMMENTED")) | .id] | .[]' 2>/dev/null); if [ -n "$REVIEW_IDS" ]; then for REVIEW_ID in $REVIEW_IDS; do gh api repos/$REPO/pulls/$PR_NUMBER/reviews/$REVIEW_ID/dismissals --method PUT -f message="Superseded by new review" -f event="DISMISS" 2>/dev/null || true; done; echo "Dismissed previous reviews"; else echo "No previous reviews to dismiss"; fi
IMPORTANT: Only dismiss previous reviews when performing a FULL code review. Do NOT dismiss when responding to a user question via @claude.
DISMISS_BLOCK
fi

# Authority-specific submission rules
case "$REVIEW_AUTHORITY" in
  comment-only)
    cat >> "$PROMPT_FILE" <<'AUTH_COMMENT'

SUBMITTING THE REVIEW:
Always use COMMENT event (this action is configured for advisory-only reviews):
  gh api repos/$REPO/pulls/$PR_NUMBER/reviews --method POST -f event=COMMENT -f body="your review"
AUTH_COMMENT
    ;;
  request-changes)
    cat >> "$PROMPT_FILE" <<'AUTH_RC'

SUBMITTING THE REVIEW:
If your review has 🔴 BLOCKERS or 🟠 HIGH findings, use REQUEST_CHANGES:
  gh api repos/$REPO/pulls/$PR_NUMBER/reviews --method POST -f event=REQUEST_CHANGES -f body="your review"
Otherwise (clean, or only 🟡 MEDIUM / 🔵 LOW findings), use COMMENT:
  gh api repos/$REPO/pulls/$PR_NUMBER/reviews --method POST -f event=COMMENT -f body="your review"
Do NOT use APPROVE — this authority level cannot approve PRs.
AUTH_RC
    ;;
  full)
    # NOTE: Unquoted heredoc means shell expansion is active.
    # \$REPO and \$PR_NUMBER are escaped → become literal $REPO/$PR_NUMBER in Claude's prompt.
    # ${APPROVE_MAX_FILES} and threshold conditions expand to actual values (intentional).
    if [ "$APPROVE_THRESHOLD" = "strict" ]; then
      cat >> "$PROMPT_FILE" <<AUTH_FULL_STRICT

SUBMITTING THE REVIEW — choose the event based on your findings:
1. If ANY 🔴 BLOCKER, 🟠 HIGH, or 🟡 MEDIUM findings exist → REQUEST_CHANGES:
     gh api repos/\$REPO/pulls/\$PR_NUMBER/reviews --method POST -f event=REQUEST_CHANGES -f body="your review"
2. If ONLY 🔵 LOW findings (or no findings at all) AND the PR has <= ${APPROVE_MAX_FILES} files → APPROVE:
     gh api repos/\$REPO/pulls/\$PR_NUMBER/reviews --method POST -f event=APPROVE -f body="your review"
3. Otherwise → COMMENT:
     gh api repos/\$REPO/pulls/\$PR_NUMBER/reviews --method POST -f event=COMMENT -f body="your review"

⚠️ STRICT THRESHOLD: You MUST NOT approve if there are ANY findings at 🟡 MEDIUM severity or above.
AUTH_FULL_STRICT
    else
      cat >> "$PROMPT_FILE" <<AUTH_FULL_NORMAL

SUBMITTING THE REVIEW — choose the event based on your findings:
1. If ANY 🔴 BLOCKER or 🟠 HIGH findings exist → REQUEST_CHANGES:
     gh api repos/\$REPO/pulls/\$PR_NUMBER/reviews --method POST -f event=REQUEST_CHANGES -f body="your review"
2. If NO findings above 🟡 MEDIUM (i.e., only MEDIUM/LOW or no findings) AND the PR has <= ${APPROVE_MAX_FILES} files → APPROVE:
     gh api repos/\$REPO/pulls/\$PR_NUMBER/reviews --method POST -f event=APPROVE -f body="your review"
3. Otherwise → COMMENT:
     gh api repos/\$REPO/pulls/\$PR_NUMBER/reviews --method POST -f event=COMMENT -f body="your review"

⚠️ NORMAL THRESHOLD: You MUST NOT approve if there are ANY 🟠 HIGH or 🔴 BLOCKER findings.
AUTH_FULL_NORMAL
    fi
    ;;
esac

# --- Section 11: Extra prompt (if provided) ---
if [ -n "$EXTRA_PROMPT" ]; then
  echo "" >> "$PROMPT_FILE"
  echo "$EXTRA_PROMPT" >> "$PROMPT_FILE"
fi

# --- Export prompt as GitHub Actions output ---
{
  echo "prompt<<EOF_PROMPT_${GITHUB_RUN_ID}"
  cat "$PROMPT_FILE"
  echo "EOF_PROMPT_${GITHUB_RUN_ID}"
} >> "$GITHUB_OUTPUT"

echo "::notice::Prompt assembled ($(wc -c < "$PROMPT_FILE" | tr -d ' ') bytes)"
