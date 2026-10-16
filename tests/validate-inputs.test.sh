#!/usr/bin/env bash
# Self-check for size-limit validation: bash tests/validate-inputs.test.sh
set -uo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
printf '#!/usr/bin/env bash\necho "$*" >> "%s/gh.log"\n' "$T" > "$T/bin/gh"
printf '#!/usr/bin/env bash\necho 200\n' > "$T/bin/curl"
chmod +x "$T/bin/gh" "$T/bin/curl"
fail() { echo "FAIL: $*"; exit 1; }
run() {
  : > "$T/gh.log"
  env PATH="$T/bin:$PATH" ANTHROPIC_API_KEY=k REVIEW_AUTHORITY=full REPO=x PR_NUMBER=1 MAX_FILES=50 MAX_CHANGED_LINES= \
    APPROVE_MAX_FILES=50 APPROVE_MAX_CHANGED_LINES= "$@" bash scripts/validate-inputs.sh > /dev/null
}

run || fail "defaults: exit"
run MAX_CHANGED_LINES=5000 APPROVE_MAX_CHANGED_LINES=0 || fail "whole numbers: exit"
for bad in abc 5k 1,000 -1 ' 5'; do
  run MAX_CHANGED_LINES="$bad" && fail "max-changed-lines '$bad': accepted"
  grep -qF "max-changed-lines: '$bad'" "$T/gh.log" || fail "max-changed-lines '$bad': no PR comment"
done
run APPROVE_MAX_CHANGED_LINES=5k && fail "approve-max-changed-lines: accepted"
run APPROVE_MAX_FILES=abc && fail "approve-max-files: accepted"
run MAX_FILES=abc && fail "max-files: accepted"
echo PASS
