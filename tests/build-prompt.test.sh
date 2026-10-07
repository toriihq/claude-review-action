#!/usr/bin/env bash
# Self-check for the prompt size cap: bash tests/build-prompt.test.sh
set -uo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d); trap 'rm -rf "$T" /tmp/claude-prompt.md /tmp/pr-diff.txt /tmp/pr-description.txt /tmp/review-guide.md /tmp/truncated-files.txt /tmp/excluded-files.txt' EXIT
mkdir -p "$T/bin"; printf '#!/usr/bin/env bash\necho "$*" >> "%s/gh.log"\n' "$T" > "$T/bin/gh"; chmod +x "$T/bin/gh"
for v in $(grep -oE '\$\{?[A-Z_]+' scripts/build-prompt.sh | sed 's/[${]//g' | sort -u); do export "$v="; done
export PATH="$T/bin:$PATH" ACTION_PATH="$PWD" REPO=x PR_NUMBER=1 EVENT_TYPE=pull_request REVIEW_AUTHORITY=comment-only GITHUB_RUN_ID=1
: > /tmp/review-guide.md; : > /tmp/truncated-files.txt; : > /tmp/excluded-files.txt; : > /tmp/user-comment.txt
fail() { echo "FAIL: $*"; exit 1; }
run() { : > "$T/out"; : > "$T/gh.log"; GITHUB_OUTPUT="$T/out" MAX_PROMPT_BYTES="$1" bash scripts/build-prompt.sh > /dev/null; }

printf 'diff --git a/x b/x\n+```\n+secret-line\n' > /tmp/pr-diff.txt; echo "desc" > /tmp/pr-description.txt
run 120000 || fail "small: exit"
grep -q '^+secret-line$' /tmp/claude-prompt.md && grep -q '^```diff$' /tmp/claude-prompt.md || fail "small: diff not inlined"
grep -q "^diff_inline=true$" "$T/out" || fail "small: diff_inline output"

for i in $(seq 100); do echo "+padding line $i of the big diff"; done >> /tmp/pr-diff.txt
run 4000 || fail "big diff: exit"
grep -q 'secret-line' /tmp/claude-prompt.md && fail "big diff: diff still inlined"
grep -q '/tmp/pr-diff.txt' /tmp/claude-prompt.md || fail "big diff: no pointer"
grep -q "^diff_inline=false$" "$T/out" || fail "big diff: diff_inline output"
grep -q 'secret-line' "$T/out" && fail "big diff: diff in output"
[ "$(wc -c < /tmp/claude-prompt.md)" -le 4000 ] || fail "big diff: prompt over cap"

head -c 5000 /dev/zero | tr '\0' d > /tmp/pr-description.txt
run 4000 && fail "huge description: should exit non-zero"
grep -q 'review skipped' "$T/gh.log" || fail "huge description: no PR comment"
printf 'diff --git a/x b/x\n+one\n' > /tmp/pr-diff.txt; printf 'desc\n(PR diff)\nmore\n' > /tmp/pr-description.txt
run 120000 || fail "fake placeholder: exit"
[ "$(grep -c '^+one$' /tmp/claude-prompt.md)" = 1 ] || fail "fake placeholder: diff spliced twice"

printf 'diff --git a/x b/x\n' > /tmp/pr-diff.txt; for i in $(seq 120); do printf '+\t\t\t"q"\t"q"\n'; done >> /tmp/pr-diff.txt; echo desc > /tmp/pr-description.txt
RAW=$(( $(wc -c < /tmp/pr-diff.txt) + 1600 )); run $(( RAW + 400 )) || fail "escaped: exit"
grep -q '/tmp/pr-diff.txt' /tmp/claude-prompt.md || fail "escaped: raw fits but escaped does not — should use pointer"
printf 'what does $(whoami) do?\n' > /tmp/user-comment.txt
EVENT_TYPE=issue_comment run 120000 || fail "comment: exit"
grep -qF 'what does $(whoami) do?' /tmp/claude-prompt.md || fail "comment: not in prompt verbatim"

: > /tmp/user-comment.txt; printf 'package-lock.json\n$(whoami)/gen.ts\n' > /tmp/excluded-files.txt
run 120000 || fail "excluded: exit"
grep -q 'EXCLUDED FROM REVIEW — 2 files' /tmp/claude-prompt.md && grep -qF -- '- `$(whoami)/gen.ts`' /tmp/claude-prompt.md || fail "excluded: list missing"
REVIEW_AUTHORITY=full FILE_COUNT=0 run 120000 || fail "all excluded: exit"
grep -q 'Every changed file is excluded' /tmp/claude-prompt.md || fail "all excluded: approval allowed"
REVIEW_AUTHORITY=full FILE_COUNT=3 run 120000 || fail "some excluded: exit"
grep -q 'MUST NOT APPROVE' /tmp/claude-prompt.md && fail "some excluded: approval blocked"
: > /tmp/excluded-files.txt
run 120000 || fail "no excluded: exit"
grep -q 'EXCLUDED FROM REVIEW' /tmp/claude-prompt.md && fail "no excluded: section shown"

REVIEW_AUTHORITY=full CHANGED_LINES=500 APPROVE_MAX_CHANGED_LINES=100 run 120000 || fail "approve lines: exit"
grep -q 'MUST NOT APPROVE' /tmp/claude-prompt.md || fail "approve lines: over the limit but approval allowed"
REVIEW_AUTHORITY=full CHANGED_LINES=50 APPROVE_MAX_CHANGED_LINES=100 run 120000 || fail "approve lines under: exit"
grep -q 'MUST NOT APPROVE' /tmp/claude-prompt.md && fail "approve lines: under the limit but approval blocked"
REVIEW_AUTHORITY=full CHANGED_LINES=500 run 120000 || fail "approve lines unset: exit"
grep -q 'MUST NOT APPROVE' /tmp/claude-prompt.md && fail "approve lines: blocked with no limit set"
echo PASS
