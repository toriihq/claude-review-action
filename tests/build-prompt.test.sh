#!/usr/bin/env bash
# Self-check for the prompt size cap: bash tests/build-prompt.test.sh
set -uo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d); trap 'rm -rf "$T" /tmp/claude-prompt.md /tmp/pr-diff.txt /tmp/pr-description.txt /tmp/review-guide.md /tmp/architecture-guide.md /tmp/truncated-files.txt' EXIT
mkdir -p "$T/bin"; printf '#!/usr/bin/env bash\necho "$*" >> "%s/gh.log"\n' "$T" > "$T/bin/gh"; chmod +x "$T/bin/gh"
for v in $(grep -oE '\$\{?[A-Z_]+' scripts/build-prompt.sh | sed 's/[${]//g' | sort -u); do export "$v="; done
export PATH="$T/bin:$PATH" ACTION_PATH="$PWD" REPO=x PR_NUMBER=1 EVENT_TYPE=pull_request REVIEW_AUTHORITY=comment-only GITHUB_RUN_ID=1
: > /tmp/review-guide.md; : > /tmp/truncated-files.txt; : > /tmp/user-comment.txt
fail() { echo "FAIL: $*"; exit 1; }
run() { : > "$T/out"; : > "$T/gh.log"; GITHUB_OUTPUT="$T/out" MAX_PROMPT_BYTES="$1" bash scripts/build-prompt.sh > /dev/null; }

printf 'diff --git a/x b/x\n+```\n+secret-line\n' > /tmp/pr-diff.txt; echo "desc" > /tmp/pr-description.txt
run 120000 || fail "small: exit"
grep -q '^+secret-line$' /tmp/claude-prompt.md && grep -q '^```diff$' /tmp/claude-prompt.md || fail "small: diff not inlined"
grep -q '@@CLAUDE_REVIEW_PR_DIFF@@' /tmp/claude-prompt.md && fail "small: marker left"

for i in $(seq 100); do echo "+padding line $i of the big diff"; done >> /tmp/pr-diff.txt
run 4000 || fail "big diff: exit"
grep -q 'secret-line' /tmp/claude-prompt.md && fail "big diff: diff still inlined"
grep -q '/tmp/pr-diff.txt' /tmp/claude-prompt.md || fail "big diff: no pointer"
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

printf 'diff --git a/x b/x\n+one\n' > /tmp/pr-diff.txt
echo desc > /tmp/pr-description.txt
EVENT_TYPE=pull_request INCLUDE_ARCHITECTURE_REVIEW=false EXTRA_PROMPT= run 120000 || fail "arch off: exit"
grep -q 'ARCHITECTURE PASS (advisory' /tmp/claude-prompt.md && fail "arch off: pass leaked into prompt"
DISMISS_PREVIOUS_REVIEWS=true EVENT_TYPE=pull_request INCLUDE_ARCHITECTURE_REVIEW=true EXTRA_PROMPT='EXTRA_PROMPT_SENTINEL' run 120000 || fail "arch on: exit"
grep -q 'Write one line per item in the guide below' /tmp/claude-prompt.md && fail "arch on: checklist leaked into the main review"
grep -q 'startswith("## 🏗️ Architecture")' /tmp/claude-prompt.md || fail "arch on: dismiss must spare the architecture review"
grep -q 'EXTRA_PROMPT_SENTINEL' /tmp/claude-prompt.md || fail "arch on: extra prompt missing"
rm -f /tmp/architecture-guide.md
ARCHITECTURE_BUILD_ONLY=1 ACTION_PATH="$PWD" bash scripts/architecture-review.sh || fail "arch prompt: exit"
grep -q 'Write one line per item in the guide below' /tmp/claude-architecture-prompt.md || fail "arch prompt: checklist missing"
grep -q '— none' /tmp/claude-architecture-prompt.md || fail "arch prompt: none option missing"
grep -q 'Candidates you must judge' /tmp/claude-architecture-prompt.md || fail "arch prompt: candidates missing"
grep -q 'different words' /tmp/claude-architecture-prompt.md || fail "arch prompt: logical duplicate rule missing"
grep -q 'Readable functions' /tmp/claude-architecture-prompt.md || fail "arch prompt: generic guide missing"
grep -q 'Composition of passes' /tmp/claude-architecture-prompt.md && fail "arch prompt: company axes leaked into the default guide"
grep -q '@@CLAUDE_REVIEW_ARCHITECTURE_GUIDE@@' /tmp/claude-architecture-prompt.md && fail "arch prompt: placeholder left"
printf 'ARCH_GUIDE_SENTINEL\n' > /tmp/architecture-guide.md
ARCHITECTURE_BUILD_ONLY=1 ACTION_PATH="$PWD" bash scripts/architecture-review.sh || fail "arch guide: exit"
grep -q 'ARCH_GUIDE_SENTINEL' /tmp/claude-architecture-prompt.md || fail "arch guide: repo guide missing"
grep -q 'Readable functions' /tmp/claude-architecture-prompt.md && fail "arch guide: generic guide still present"
rm -f /tmp/architecture-guide.md
echo PASS
