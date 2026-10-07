#!/usr/bin/env bash
# Self-check for truncated-diff file detection: bash tests/capture-context.test.sh
set -euo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

cat > "$T/diff" <<'DIFF'
diff --git a/src/a.ts b/src/a.ts
--- a/src/a.ts
+++ b/src/a.ts
@@ -1 +1 @@
-a
+A
diff --git a/src/deep/b.ts b/src/deep/b.ts
--- a/src/deep/b.ts
+++ b/src/deep/b.ts
@@ -1,3 +1,3 @@
-b1
+B1
-b2
+B2
diff --git a/old.ts b/renamed.ts
similarity index 90%
rename from old.ts
rename to renamed.ts
diff --git a/$(touch PWNED)/x.ts b/$(touch PWNED)/x.ts
new file mode 100644
--- /dev/null
+++ b/$(touch PWNED)/x.ts
@@ -0,0 +1 @@
+y
diff --git a/a b/foo.ts b/a b/foo.ts
--- a/a b/foo.ts
+++ b/a b/foo.ts
@@ -1 +1 @@
-s
+S
diff --git "a/caf\303\251.ts" "b/caf\303\251.ts"
--- "a/caf\303\251.ts"
+++ "b/caf\303\251.ts"
@@ -1 +1 @@
-c
+C
diff --git a/gone.ts b/gone.ts
deleted file mode 100644
--- a/gone.ts
+++ /dev/null
@@ -1 +0,0 @@
-x
DIFF

# What the REST files endpoint returns after gh's --jq: "<additions + deletions>\t<path>"
printf '%s\t%s\n' 2 src/a.ts 4 src/deep/b.ts 0 renamed.ts 1 '$(touch PWNED)/x.ts' 2 'a b/foo.ts' 2 'café.ts' 1 gone.ts > "$T/files.tsv"

mkdir -p "$T/bin"
cat > "$T/bin/gh" <<GH
#!/usr/bin/env bash
case "\$1 \$2" in
  "api --paginate") cat "$T/files.tsv" ;;
  "pr diff") cat "$T/diff" ;;
  "pr comment") echo "\$*" >> "$T/gh.log" ;;
esac
GH
chmod +x "$T/bin/gh"
capture() {
  : > "$T/out"; : > "$T/gh.log"
  env PATH="$T/bin:$PATH" GITHUB_OUTPUT="$T/out" PR_NUMBER=1 REPO=x INCLUDE_PR_DESCRIPTION=false MAX_FILES=50 \
    MAX_CHANGED_LINES= EXCLUDE_PATHS= MAX_DIFF_LINES=999999 MAX_DIFF_BYTES=999999 "$@" bash scripts/capture-context.sh > /dev/null
}

# Cut inside b.ts: a.ts complete, b.ts partial, the rest absent
capture MAX_DIFF_LINES=10
grep -q '^file_count=7$' "$T/out" && grep -q '^changed_lines=12$' "$T/out" || { echo "FAIL counts"; cat "$T/out"; exit 1; }

expected=$'$(touch PWNED)/x.ts\na b/foo.ts\ncaf\\303\\251.ts\ngone.ts\nrenamed.ts\nsrc/deep/b.ts'
[ "$(cat /tmp/truncated-files.txt)" = "$expected" ] || { echo "FAIL missing list:"; cat /tmp/truncated-files.txt; exit 1; }
grep -q '^missing_file_count=6$' "$T/out" || { echo "FAIL count"; cat "$T/out"; exit 1; }
grep -q '^+B2$' /tmp/pr-diffs/src/deep/b.ts.diff || { echo "FAIL b.ts diff incomplete"; exit 1; }
grep -q '^deleted file mode' /tmp/pr-diffs/gone.ts.diff || { echo "FAIL deleted diff"; exit 1; }
[ -f "/tmp/pr-diffs/\$(touch PWNED)/x.ts.diff" ] || { echo "FAIL odd path diff"; exit 1; }
[ ! -e PWNED ] && [ ! -e /tmp/pr-diffs/PWNED ] || { echo "FAIL path executed"; exit 1; }
grep -q '^+S$' "/tmp/pr-diffs/a b/foo.ts.diff" || { echo "FAIL space-b path"; exit 1; }
[ -f '/tmp/pr-diffs/caf\303\251.ts.diff' ] || { echo "FAIL quoted path"; exit 1; }

# exclude-paths: out of the diff and both counts; patterns trimmed, blank lines ignored, `*` crosses `/`
capture EXCLUDE_PATHS=$'  src/*/b.ts  \n\ngone.ts'
[ "$(cat /tmp/excluded-files.txt)" = $'src/deep/b.ts\ngone.ts' ] || { echo "FAIL excluded list"; cat /tmp/excluded-files.txt; exit 1; }
grep -q '^file_count=5$' "$T/out" && grep -q '^changed_lines=7$' "$T/out" || { echo "FAIL excluded counts"; cat "$T/out"; exit 1; }
grep -qE '^diff --git a/(src/deep/b|gone)\.ts' /tmp/pr-diff.txt && { echo "FAIL excluded file still in diff"; exit 1; }
grep -q '^+A$' /tmp/pr-diff.txt && grep -q '^+S$' /tmp/pr-diff.txt && grep -q '^rename to renamed.ts$' /tmp/pr-diff.txt \
  || { echo "FAIL kept file dropped from diff"; exit 1; }

# Non-ASCII path: the diff header is octal-escaped, the REST path isn't
capture EXCLUDE_PATHS='café.ts'
grep -q '^file_count=6$' "$T/out" || { echo "FAIL non-ASCII count"; cat "$T/out"; exit 1; }
grep -q 'caf\\303\\251' /tmp/pr-diff.txt && { echo "FAIL non-ASCII file still in diff"; exit 1; }

# Excluded files never show up as truncated
capture MAX_DIFF_LINES=10 EXCLUDE_PATHS=$'gone.ts\n*foo.ts'
[ "$(cat /tmp/truncated-files.txt)" = $'$(touch PWNED)/x.ts\ncaf\\303\\251.ts\nrenamed.ts\nsrc/deep/b.ts' ] \
  || { echo "FAIL excluded + truncated:"; cat /tmp/truncated-files.txt; exit 1; }
grep -q '^missing_file_count=4$' "$T/out" || { echo "FAIL excluded + truncated count"; cat "$T/out"; exit 1; }

# max-changed-lines: skips over the limit; excluded files don't count toward it
capture MAX_CHANGED_LINES=11
grep -q '^skipped=true$' "$T/out" && grep -q '12 changed lines' "$T/gh.log" || { echo "FAIL line limit not enforced"; exit 1; }
capture MAX_CHANGED_LINES=11 EXCLUDE_PATHS=gone.ts
grep -q '^skipped=true$' "$T/out" && { echo "FAIL excluded lines counted"; exit 1; }

# Over 100 files are counted (gh pr view --json files stops at 100)
for i in $(seq 150); do printf '1\tf%s.ts\n' "$i"; done > "$T/files.tsv"
capture MAX_FILES=120
grep -q '^skipped=true$' "$T/out" && grep -q '150 files' "$T/gh.log" || { echo "FAIL file count over 100"; cat "$T/out"; exit 1; }
echo PASS
