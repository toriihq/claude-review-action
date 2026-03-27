#!/bin/bash
# build-security-prompt.sh — assembles the security review prompt
# Env vars: ACTION_PATH, REPO, PR_NUMBER, HEAD_SHA, INCLUDE_PR_DESCRIPTION, BLOCKING
set -e

PROMPT_FILE="/tmp/security-prompt.md"
> "$PROMPT_FILE"

# ── Header ───────────────────────────────────────────────────────────────────
cat >> "$PROMPT_FILE" << 'HEREDOC'
You are a senior security engineer conducting a focused security review.
HEREDOC

printf '\nReviewing PR #%s in %s.\n' "$PR_NUMBER" "$REPO" >> "$PROMPT_FILE"

# ── PR description ────────────────────────────────────────────────────────────
if [ "${INCLUDE_PR_DESCRIPTION:-true}" = "true" ] && [ -f /tmp/pr-description.txt ]; then
  printf '\n## PR Description\n\n' >> "$PROMPT_FILE"
  cat /tmp/pr-description.txt >> "$PROMPT_FILE"
fi

# ── Diff ─────────────────────────────────────────────────────────────────────
printf '\n## Diff\n\n' >> "$PROMPT_FILE"

if [ -f /tmp/pr-diff.txt ] && [ -s /tmp/pr-diff.txt ]; then
  printf '```diff\n' >> "$PROMPT_FILE"
  cat /tmp/pr-diff.txt >> "$PROMPT_FILE"
  printf '\n```\n' >> "$PROMPT_FILE"
else
  printf '_No diff content available._\n' >> "$PROMPT_FILE"
fi

# ── Security guide ────────────────────────────────────────────────────────────
printf '\n' >> "$PROMPT_FILE"
if [ -f /tmp/security-guide.md ] && [ -s /tmp/security-guide.md ]; then
  cat /tmp/security-guide.md >> "$PROMPT_FILE"
else
  cat >> "$PROMPT_FILE" << 'HEREDOC'
## Security Review Instructions

Review the diff above for security vulnerabilities. Focus ONLY on HIGH-CONFIDENCE issues
with real exploitation potential (>80% confident). Minimize false positives.
Skip theoretical issues, style concerns, DoS, rate limiting, and disk secrets.

Categories to check: SQL/command injection, auth bypass, XSS, SSRF, path traversal,
mass assignment, information disclosure, hardcoded secrets.

Output format:
## BLOCKERS — must fix before merge
## HIGH — strongly recommended
## MEDIUM — worth addressing

End with: APPROVE or REQUEST CHANGES
HEREDOC
fi

# ── Submission instructions ───────────────────────────────────────────────────
# Bake REPO, HEAD_SHA, ACTION_PATH, BLOCKING into the prompt so Claude
# does not need these as runtime env vars when it calls the script.
cat >> "$PROMPT_FILE" << HEREDOC

---

## How to Submit Your Review

1. Write your complete security report to \`/tmp/security-report.md\`
   (Use the output format from the guide above. If no issues: write "No security issues found.")

2. Run the submission script with two arguments: conclusion and title.

   **If you found BLOCKER or HIGH findings:**
   \`\`\`bash
   bash ${ACTION_PATH}/scripts/post-check-run.sh "failure" "Found N issues: X BLOCKER, Y HIGH"
   \`\`\`
   (Replace N, X, Y with actual counts from your report)

   **If NO BLOCKER or HIGH findings (clean or MEDIUM only):**
   \`\`\`bash
   bash ${ACTION_PATH}/scripts/post-check-run.sh "success" "No security issues found"
   \`\`\`

   The script requires these env vars (already set by the runner):
   - \`REPO=${REPO}\`
   - \`HEAD_SHA=${HEAD_SHA}\`
   - \`BLOCKING=${BLOCKING:-false}\`
   - \`GH_TOKEN\` (set by runner)

3. Confirm the script printed a notice line. You are done.

**IMPORTANT:** Do NOT post a PR review, PR comment, or any other GitHub API call.
Only use the submission script above.
HEREDOC

# ── Write to GITHUB_OUTPUT using collision-resistant delimiter ────────────────
DELIMITER="SECURITY_PROMPT_EOF_${GITHUB_RUN_ID}"
{
  echo "prompt<<${DELIMITER}"
  cat "$PROMPT_FILE"
  echo "${DELIMITER}"
} >> "$GITHUB_OUTPUT"

echo "::notice::Security prompt built ($(wc -l < "$PROMPT_FILE") lines)"
