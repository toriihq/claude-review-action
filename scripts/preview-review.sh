#!/usr/bin/env bash
# Print the review this action would write for one PR. Does not post, dismiss, or comment.
#
# Uses the action's default model (claude-sonnet-4-6) unless the workflow sets `model`.
# Reads that repo's .github/workflows/claude-review.yml for context-intro, critical-rules,
# the review guide, and the diff limits, and turns the architecture section on.
#
# Usage:
#   scripts/preview-review.sh <owner/repo> <pr> --checkout <local clone>
#
# Example:
#   scripts/preview-review.sh toriihq/torii-monorepo 4821 \
#     --checkout "$HOME/torii/torii-ai-workspace/repos/torii-monorepo"
#
# The review is printed and saved to /tmp/claude-review-preview.md.
set -euo pipefail

ACTION_PATH="$(cd "$(dirname "$0")/.." && pwd)"
REPO="${1:-}"
PR="${2:-}"
CHECKOUT=""
shift 2 || true
while [ $# -gt 0 ]; do
  case "$1" in
    --checkout) CHECKOUT="${2:-}"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

if [ -z "$REPO" ] || [ -z "$PR" ] || [ -z "$CHECKOUT" ]; then
  echo "usage: scripts/preview-review.sh <owner/repo> <pr> --checkout <local clone>" >&2
  exit 1
fi
if [ ! -d "$CHECKOUT/.git" ] && [ ! -f "$CHECKOUT/.git" ]; then
  echo "not a git checkout: $CHECKOUT" >&2
  exit 1
fi
command -v claude >/dev/null || { echo "claude CLI is not on PATH" >&2; exit 1; }

# Child scripts comment on the PR when they skip. A preview must not.
gh() {
  if [ "${1:-}" = "pr" ] && [ "${2:-}" = "comment" ]; then
    echo "preview: suppressed a PR comment" >&2
    return 0
  fi
  command gh "$@"
}
export -f gh

DEFAULT_BRANCH="$(gh api "repos/${REPO}" --jq '.default_branch')"
gh api "repos/${REPO}/contents/.github/workflows/claude-review.yml?ref=${DEFAULT_BRANCH}" \
  --jq '.content' | base64 -d > /tmp/preview-workflow.yml

eval "$(python3 - "$ACTION_PATH" <<'PY'
import shlex, sys
from pathlib import Path
import yaml

action = yaml.safe_load(Path(sys.argv[1]).joinpath("action.yml").read_text())
defaults = {k: (v.get("default") if isinstance(v, dict) else None) for k, v in action["inputs"].items()}
doc = yaml.safe_load(Path("/tmp/preview-workflow.yml").read_text())
found = None
for job in (doc.get("jobs") or {}).values():
    for step in job.get("steps") or []:
        uses = step.get("uses") or ""
        if uses.startswith("toriihq/claude-review-action"):
            found = step.get("with") or {}
            break
    if found is not None:
        break
if found is None:
    sys.exit("workflow has no toriihq/claude-review-action step")

def val(key):
    if key in found and found[key] not in (None, ""):
        return found[key]
    d = defaults.get(key)
    return "" if d is None else d

keys = {
    "CONTEXT_INTRO": "context-intro",
    "CRITICAL_RULES": "critical-rules",
    "GUIDE_PATH": "review-guide-path",
    "ARCH_GUIDE_PATH": "architecture-guide-path",
    "EXTRA_PROMPT": "extra-prompt",
    "MAX_FILES": "max-files",
    "MAX_DIFF_LINES": "max-diff-lines",
    "MAX_DIFF_BYTES": "max-diff-bytes",
    "REVIEW_AUTHORITY": "review-authority",
    "APPROVE_THRESHOLD": "approve-threshold",
    "APPROVE_MAX_FILES": "approve-max-files",
    "MODEL": "model",
}
for env, key in keys.items():
    print(f"{env}={shlex.quote(str(val(key)))}")
PY
)"

if [ -n "$GUIDE_PATH" ]; then
  gh api "repos/${REPO}/contents/${GUIDE_PATH}?ref=${DEFAULT_BRANCH}" \
    --jq '.content' | base64 -d > /tmp/review-guide.md
else
  : > /tmp/review-guide.md
fi
rm -f /tmp/architecture-guide.md
if [ -n "${ARCH_GUIDE_PATH:-}" ]; then
  gh api "repos/${REPO}/contents/${ARCH_GUIDE_PATH}?ref=${DEFAULT_BRANCH}" \
    --jq '.content' | base64 -d > /tmp/architecture-guide.md 2>/dev/null || true
fi
if [ ! -s /tmp/architecture-guide.md ] && [ -n "$CHECKOUT" ] && [ -f "$CHECKOUT/.github/claude-architecture-guide.md" ]; then
  cp "$CHECKOUT/.github/claude-architecture-guide.md" /tmp/architecture-guide.md
fi
: > /tmp/truncated-files.txt
: > /tmp/user-comment.txt

export GH_TOKEN="${GH_TOKEN:-}"
export REPO PR_NUMBER="$PR"
export MAX_FILES MAX_DIFF_LINES MAX_DIFF_BYTES INCLUDE_PR_DESCRIPTION=true
export GITHUB_OUTPUT=/tmp/preview-github-output
: > "$GITHUB_OUTPUT"
bash "$ACTION_PATH/scripts/capture-context.sh"

FILE_COUNT="$(sed -n 's/^file_count=//p' "$GITHUB_OUTPUT" | head -1)"
if grep -q '^skipped=true$' "$GITHUB_OUTPUT"; then
  echo "preview: capture skipped this PR (too large, or the diff could not be fetched). Nothing was posted." >&2
  exit 1
fi

SHA="$(gh pr view "$PR" --repo "$REPO" --json headRefOid --jq '.headRefOid')"
WT="/tmp/claude-review-wt-${PR}-$$"
cleanup() {
  git -C "$CHECKOUT" worktree remove --force "$WT" >/dev/null 2>&1 || rm -rf "$WT"
}
trap cleanup EXIT
git -C "$CHECKOUT" fetch --depth 1 --no-tags origin "pull/${PR}/head"
git -C "$CHECKOUT" worktree add --detach "$WT" FETCH_HEAD

echo "preview: separate architecture review, model ${MODEL} on ${REPO}#${PR} @ ${SHA}" >&2
echo "preview: comment review only, nothing will be posted" >&2
export ACTION_PATH MODEL ARCHITECTURE_PREVIEW=1 ARCHITECTURE_WORKDIR="$WT"
bash "$ACTION_PATH/scripts/architecture-review.sh" | tee /tmp/claude-review-preview.md
