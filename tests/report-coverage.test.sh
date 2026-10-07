#!/usr/bin/env bash
# Self-check: the truncation note reflects what Claude actually read: bash tests/report-coverage.test.sh
set -uo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d); trap 'rm -rf "$T" /tmp/truncated-files.txt /tmp/coverage-*.txt /tmp/review-body.*' EXIT
fail() { echo "FAIL: $*"; exit 1; }

# gh stub: one claude review (id 42) whose commit/state/body come from env; GET_FAIL / DISMISS_FAIL simulate API errors
mkdir -p "$T/bin"; cat > "$T/bin/gh" <<'GH'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
case "$*" in
  *dismissals*) [ -z "${DISMISS_FAIL:-}" ] ;;
  *"--method PUT --input -"*) cat > "$PUT_FILE" ;;
  *"reviews/42 --jq .body"*) [ -z "${GET_FAIL:-}" ] && printf 'Looks good.\n\n**Verdict:** Approving.\n\n> **⚠️ Diff was truncated.** Reviewed the diffs of 2 missing files via Read tool.\n' ;;
  *"--paginate"*) jq -n --arg s "$STATE" --arg c "${REVIEW_SHA:-abc}" '[{id:1,user:{login:"claude[bot]"},state:"APPROVED",commit_id:"old",body:"**Verdict:** ok"},{id:42,user:{login:"claude[bot]"},state:$s,commit_id:$c,body:"**Verdict:** x"}]' ;;
esac
GH
chmod +x "$T/bin/gh"
export GH_LOG="$T/gh.log" PUT_FILE="$T/put.json"

exec_with() { printf '[{"type":"assistant","message":{"content":[%s]}},{"type":"user","message":{"content":[%s]}}]' "$1" "${2:-}" > "$T/exec.json"; }
read_call() { printf '{"type":"tool_use","id":"%s","name":"Read","input":{"file_path":"%s"}}' "$1" "$2"; }
run() { : > "$T/gh.log"; rm -f "$T/put.json"; PATH="$T/bin:$PATH" GH_TOKEN=x REPO=x PR_NUMBER=1 HEAD_SHA=abc CLAUDE_OUTCOME=success \
  CLAUDE_OUTPUT_FILE="$T/exec.json" HAS_PREVIOUS="$1" STATE="$2" DIFF_INLINE="${DIFF_INLINE:-true}" bash scripts/report-coverage.sh > "$T/stdout" || fail "non-zero exit ($1 $2)"; }
body() { jq -r .body "$T/put.json" 2>/dev/null; }
dismissed() { grep -q dismissals "$T/gh.log"; }

printf 'src/a.ts\nsrc/b.ts\n' > /tmp/truncated-files.txt

# #10073 shape: first review, approved, read an unrelated file only
exec_with "$(read_call t1 /repo/src/header/style.ts)"; run false APPROVED
body | grep -qF 'Verified: Claude read 0/2 saved diffs. **Not reviewed:** `src/a.ts`, `src/b.ts`' || { body; fail "unread line"; }
body | grep -q 'Reviewed the diffs of 2' && fail "model's own claim kept"
body | grep -q 'Verdict' || fail "rest of the review lost"
dismissed || fail "first-review approval not dismissed"

run true APPROVED; dismissed && fail "re-review approval dismissed"
run false CHANGES_REQUESTED; dismissed && fail "non-approval dismissed"

# Read + relative cat after cd → all read, no dismissal
exec_with "$(read_call t1 /tmp/pr-diffs/src/a.ts.diff),{\"type\":\"tool_use\",\"id\":\"t2\",\"name\":\"Bash\",\"input\":{\"command\":\"cd /tmp/pr-diffs && cat src/b.ts.diff\"}}"
run false APPROVED
body | grep -qF 'Verified: Claude read all 2 saved diffs.' || fail "all-read line"
dismissed && fail "dismissed although all read"

# Not reads: path only in the posted review body, an ls, a failed Read, a longer name sharing the prefix
exec_with "{\"type\":\"tool_use\",\"id\":\"t1\",\"name\":\"Bash\",\"input\":{\"command\":\"gh api x -f body='skipped /tmp/pr-diffs/src/a.ts.diff'\"}},{\"type\":\"tool_use\",\"id\":\"t2\",\"name\":\"Bash\",\"input\":{\"command\":\"ls -l /tmp/pr-diffs/src/b.ts.diff\"}},$(read_call t3 /tmp/pr-diffs/src/a.ts.diff),$(read_call t4 /tmp/pr-diffs/src/b.ts.diff.diff)" \
  '{"type":"tool_result","tool_use_id":"t3","is_error":true}'
run false COMMENTED; body | grep -qF 'read 0/2' || { body; fail "non-reads counted as reads"; }

# Odd characters in a path are matched as raw strings
printf 'src/we"ird\\x.ts\n' > /tmp/truncated-files.txt
exec_with '{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"/tmp/pr-diffs/src/we\"ird\\x.ts.diff"}}'
run false APPROVED; body | grep -qF 'read all 1' || { body; fail "quoted/backslash path"; }

# Diff moved out of the prompt, nothing truncated, never read
: > /tmp/truncated-files.txt; exec_with "$(read_call t1 /tmp/x)"; DIFF_INLINE=false run false COMMENTED
body | grep -qF 'Diff was too large to inline.** Verified: Claude read 0/1 saved diffs. **Not reviewed:** `(the full diff)`' || { body; fail "pointer line"; }

# Review for another commit only (e.g. an @claude Q&A run) → leave old reviews alone
printf 'src/a.ts\n' > /tmp/truncated-files.txt; REVIEW_SHA=zzz run false APPROVED
[ -e "$T/put.json" ] && fail "edited a review from another commit"; dismissed && fail "dismissed a review from another commit"

# API failures never fail the step and never PUT a gutted body
GET_FAIL=1 run false COMMENTED; [ -e "$T/put.json" ] && fail "PUT after a failed GET"
DISMISS_FAIL=1 run false APPROVED; grep -q 'Could not dismiss' "$T/stdout" || fail "dismissal failure not reported"
grep -q 'Approval dismissed' "$T/stdout" && fail "claimed a failed dismissal"
echo 'not json' > "$T/exec.json"; run false APPROVED; grep -q 'could not parse' "$T/stdout" || fail "malformed output"

# Nothing truncated and diff inline → no API calls at all
: > /tmp/truncated-files.txt; exec_with "$(read_call t1 /x)"; run false APPROVED
[ -s "$T/gh.log" ] && fail "touched the review although nothing was truncated"
echo PASS
