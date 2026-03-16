#!/usr/bin/env bash
set -euo pipefail

post_error() {
  local msg="$1"
  gh api "repos/$REPO/issues/$PR_NUMBER/comments" --method POST -f body="$msg" || true
}

# Check for missing API key
if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
  post_error "$(cat <<'MSG'
❌ **Claude Review failed — missing API key**

The `ANTHROPIC_API_KEY` secret is not set. Add it in your repo or org settings.

See the [setup guide](https://github.com/toriihq/claude-review-action#setup).
MSG
)"
  echo "::error::Missing ANTHROPIC_API_KEY. Make sure the secret is set in your repo or org settings."
  exit 1
fi

# Check for valid review authority
case "${REVIEW_AUTHORITY:-}" in
  comment-only|request-changes|full) ;;
  *)
    post_error "$(cat <<MSG
❌ **Claude Review failed — invalid configuration**

\`review-authority: '${REVIEW_AUTHORITY}'\` is not valid. Must be one of: \`comment-only\`, \`request-changes\`, \`full\`.
MSG
)"
    echo "::error::Invalid review-authority: '${REVIEW_AUTHORITY}'. Must be one of: comment-only, request-changes, full."
    exit 1
    ;;
esac

# Check for valid review depth
case "${REVIEW_DEPTH:-normal}" in
  normal|deep) ;;
  *)
    post_error "$(cat <<MSG
❌ **Claude Review failed — invalid configuration**

\`review-depth: '${REVIEW_DEPTH}'\` is not valid. Must be one of: \`normal\`, \`deep\`.
MSG
)"
    echo "::error::Invalid review-depth: '${REVIEW_DEPTH}'. Must be one of: normal, deep."
    exit 1
    ;;
esac

# Validate the key works with a lightweight API call
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
  https://api.anthropic.com/v1/messages \
  -H "x-api-key: $ANTHROPIC_API_KEY" \
  -H "anthropic-version: 2023-06-01" \
  -H "content-type: application/json" \
  -d '{"model":"claude-haiku-4-5-20251001","max_tokens":1,"messages":[{"role":"user","content":"hi"}]}')

if [ "$HTTP_STATUS" = "401" ] || [ "$HTTP_STATUS" = "403" ]; then
  post_error "$(cat <<MSG
❌ **Claude Review failed — invalid API key** (HTTP ${HTTP_STATUS})

The \`ANTHROPIC_API_KEY\` secret is set but the key is invalid or unauthorized. Check the secret value in your repo or org settings.

See the [setup guide](https://github.com/toriihq/claude-review-action#setup).
MSG
)"
  echo "::error::ANTHROPIC_API_KEY is invalid (HTTP $HTTP_STATUS). Check that the secret value is correct."
  exit 1
elif [ "$HTTP_STATUS" != "200" ] && [ "$HTTP_STATUS" != "400" ]; then
  echo "::warning::Anthropic API returned HTTP $HTTP_STATUS during key validation — proceeding anyway"
fi

echo "::notice::Input validation passed"
