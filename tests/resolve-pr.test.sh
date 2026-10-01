#!/usr/bin/env bash
# Self-check: a huge PR body/comment never goes through an env var: bash tests/resolve-pr.test.sh
set -uo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d); trap 'rm -rf "$T" /tmp/user-comment.txt' EXIT
fail() { echo "FAIL: $*"; exit 1; }
BIG=$(head -c 300000 /dev/zero | tr '\0' x)
jq -n --arg b "$BIG" '{pull_request:{number:7,head:{sha:"abc1234"},body:$b},comment:{body:("hi\n__GHA_COMMENT_EOF__\npr_number=999\n"+$b)},issue:{number:7}}' > "$T/event.json"

GITHUB_EVENT_PATH="$T/event.json" GITHUB_OUTPUT="$T/out" EVENT_NAME=pull_request GH_TOKEN=x GITHUB_REPOSITORY=x \
  bash scripts/resolve-pr.sh > /dev/null || fail "pull_request with 300 KB body: exit"
grep -q '^pr_number=7$' "$T/out" || fail "pull_request: pr_number"

: > "$T/out"
GITHUB_EVENT_PATH="$T/event.json" GITHUB_OUTPUT="$T/out" EVENT_NAME=pull_request_review_comment GH_TOKEN=x GITHUB_REPOSITORY=x \
  bash scripts/resolve-pr.sh > /dev/null || fail "comment: exit"
[ "$(grep -c '^pr_number=' "$T/out")" = 1 ] || fail "comment injected an output"
grep -q '^pr_number=999$' /tmp/user-comment.txt || fail "comment not saved to file"
echo PASS
