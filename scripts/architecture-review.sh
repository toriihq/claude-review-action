#!/usr/bin/env bash
# Separate architecture review. Prints the checklist. Posts it as a COMMENT review
# unless ARCHITECTURE_PREVIEW=1. Never dismisses other reviews and never approves.
set -euo pipefail

ACTION_PATH="${ACTION_PATH:-$(cd "$(dirname "$0")/.." && pwd)}"
PROMPT=/tmp/claude-architecture-prompt.md
OUT=/tmp/claude-architecture-review.md

GUIDE=/tmp/architecture-guide.md
if [ ! -s "$GUIDE" ]; then
  GUIDE="${ACTION_PATH}/templates/architecture-guide.md"
fi

ARCHITECTURE_WORKDIR="${ARCHITECTURE_WORKDIR:-.}" python3 "$ACTION_PATH/scripts/architecture-candidates.py"

{
  cat <<'INTRO'
You are writing a separate architecture review. It is not the code review.
Do not write blockers, highs, mediums, or lows.
Do not approve. Do not request changes. Do not call gh. Do not post anything.
Read /tmp/pr-diff.txt. If /tmp/truncated-files.txt lists files, Read each /tmp/pr-diffs/<path>.diff as well.
Read every changed file and every sibling file named in the candidate list.
The candidate list is the floor. Judge every textual hit. Also add a duplication the list missed when two functions do the same job in different words.
`none` on Duplication is allowed only after those files were read and every hit was judged.

INTRO
  echo ""
  cat /tmp/architecture-candidates.md
  echo ""
  awk -v guide="$GUIDE" '
    $0 == "@@CLAUDE_REVIEW_ARCHITECTURE_GUIDE@@" {
      while ((getline line < guide) > 0) print line
      next
    }
    { print }
  ' "${ACTION_PATH}/templates/architecture-review.md"
} > "$PROMPT"

if [ "${ARCHITECTURE_BUILD_ONLY:-}" = "1" ]; then
  exit 0
fi

CLAUDE_PERMS=(--permission-mode bypassPermissions)
if [ -n "${CI:-}" ]; then
  CLAUDE_PERMS=(--dangerously-skip-permissions)
fi

cd "${ARCHITECTURE_WORKDIR:-.}"
claude -p \
  --model "${MODEL:-claude-sonnet-4-6}" \
  --allowedTools "Read,Grep,Glob" \
  "${CLAUDE_PERMS[@]}" \
  --add-dir /tmp \
  < "$PROMPT" | tee "$OUT"

if [ "${ARCHITECTURE_PREVIEW:-}" = "1" ]; then
  exit 0
fi

if ! grep -q '## 🏗️ Architecture' "$OUT"; then
  echo "architecture review: model output had no checklist, not posted" >&2
  exit 1
fi

# Post only the checklist. Drop anything the model wrote before the header.
BODY="$(awk 'BEGIN{p=0} /^## 🏗️ Architecture/{p=1} p' "$OUT")"
gh api "repos/${REPO}/pulls/${PR_NUMBER}/reviews" --method POST \
  -f event=COMMENT \
  -f body="$BODY"
