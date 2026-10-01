#!/usr/bin/env bash
# Self-check: a "successful" Claude step that never ran must fail loudly: bash tests/post-failure.test.sh
set -uo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"; printf '#!/usr/bin/env bash\necho "$*" >> "%s/gh.log"\n' "$T" > "$T/bin/gh"; chmod +x "$T/bin/gh"

run() { # $1 = outcome, $2 = output file present (yes/no)
  : > "$T/out"; : > "$T/gh.log"; rm -f "$T/exec.json"
  [ "$2" = yes ] && echo '{"subtype":"success"}' > "$T/exec.json"
  PATH="$T/bin:$PATH" GITHUB_OUTPUT="$T/out" CLAUDE_OUTPUT_FILE="$T/exec.json" CLAUDE_OUTCOME="$1" \
    GH_TOKEN=x REPO=x PR_NUMBER=1 RUN_URL=u MAX_TURNS=30 TIMEOUT_MINUTES=20 bash scripts/post-failure.sh > /dev/null
}
fail() { echo "FAIL: $*"; exit 1; }

run success yes && [ ! -s "$T/gh.log" ] || fail "ran: should exit 0 without commenting"
run success no && fail "never ran: should exit non-zero"
grep -q 'did not run' "$T/gh.log" || fail "never ran: no comment"
grep -q '^did_not_run=true$' "$T/out" || fail "never ran: no output"
run failure yes || fail "failed: should keep exiting 0"
grep -q 'review failed' "$T/gh.log" || fail "failed: no comment"
! grep -q did_not_run "$T/out" || fail "failed: wrongly marked did_not_run"
echo PASS
