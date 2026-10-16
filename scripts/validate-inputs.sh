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

# Size limits must be whole numbers, so a typo like '5k' can't switch a limit off
for INPUT in max-files max-changed-lines approve-max-files approve-max-changed-lines; do
  VAR=$(echo "$INPUT" | tr 'a-z-' 'A-Z_')
  [ -n "${!VAR+x}" ] || { echo "::error::${INPUT} is not passed to validate-inputs.sh (set ${VAR} in action.yml)"; exit 1; }
  VALUE="${!VAR}"
  [[ -z "$VALUE" || "$VALUE" =~ ^[0-9]+$ ]] && continue
  post_error "$(cat <<MSG
❌ **Claude Review failed — invalid configuration**

\`${INPUT}: '${VALUE}'\` is not valid. Must be a whole number, or empty for no limit.
MSG
)"
  echo "::error::Invalid ${INPUT}: '${VALUE}'. Must be a whole number, or empty for no limit."
  exit 1
done

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
