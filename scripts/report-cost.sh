#!/usr/bin/env bash
set -euo pipefail

# Report cost by appending to Claude's review. Skip if action failed or no output.
# Inputs (env vars): GH_TOKEN, REPO, PR_NUMBER, RUN_URL, CLAUDE_OUTCOME

# Skip cost append if Claude failed (post-failure.sh already handled it)
if [ "$CLAUDE_OUTCOME" != "success" ]; then
  echo "::notice::Skipping cost report — Claude action outcome: $CLAUDE_OUTCOME"
  exit 0
fi

OUTPUT_FILE="/home/runner/work/_temp/claude-execution-output.json"

if [ ! -f "$OUTPUT_FILE" ]; then
  echo "::notice::No execution output file found — skipping cost report"
  exit 0
fi

# Output may be a JSON array or object — normalize to object
JQ_PREFIX='(if type == "array" then last else . end)'
COST=$(jq -r "${JQ_PREFIX} | .total_cost_usd // empty" "$OUTPUT_FILE")
TURNS=$(jq -r "${JQ_PREFIX} | .num_turns // empty" "$OUTPUT_FILE")
# Pick the model with the highest cost (the main review model, not internal helpers)
MODEL=$(jq -r "${JQ_PREFIX} | .modelUsage | to_entries | sort_by(.value.costUSD) | last | .key // empty" "$OUTPUT_FILE")

if [ -z "$COST" ]; then
  echo "::notice::No cost data in execution output — skipping"
  exit 0
fi

COST_FMT=$(printf '$%.2f' "$COST")
COST_LINE="💰 Claude review cost: **${COST_FMT}** (${TURNS} turns, ${MODEL}) — [logs](${RUN_URL})"

# Append cost to Claude's latest review
REVIEW_ID=$(gh api "repos/${REPO}/pulls/${PR_NUMBER}/reviews" \
  --jq '[.[] | select(.user.login == "claude[bot]")] | last | .id // empty')

if [ -n "$REVIEW_ID" ]; then
  # Write updated body to file to avoid shell quoting issues with markdown
  gh api "repos/${REPO}/pulls/${PR_NUMBER}/reviews/${REVIEW_ID}" --jq '.body' > /tmp/review-body.txt
  printf '\n\n---\n%s\n' "$COST_LINE" >> /tmp/review-body.txt
  jq -n --rawfile body /tmp/review-body.txt '{"body": $body}' | \
    gh api "repos/${REPO}/pulls/${PR_NUMBER}/reviews/${REVIEW_ID}" --method PUT --input - 2>/dev/null || \
  gh pr comment "$PR_NUMBER" --repo "$REPO" --body "$COST_LINE" || true
else
  # No review found — Claude handled a non-review request (e.g., @claude comment).
  # Skip cost report since it wasn't a code review.
  echo "::notice::No Claude review found — skipping cost report (non-review action)"
  exit 0
fi

echo "::notice::Cost reported: ${COST_FMT} (${TURNS} turns, ${MODEL})"
