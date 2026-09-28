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

mkdir -p "$T/bin"
cat > "$T/bin/gh" <<GH
#!/usr/bin/env bash
case "\$1 \$2" in
  "pr view") echo 7 ;;
  "pr diff") cat "$T/diff" ;;
esac
GH
chmod +x "$T/bin/gh"

# Cut inside b.ts: a.ts complete, b.ts partial, the rest absent
PATH="$T/bin:$PATH" GITHUB_OUTPUT="$T/out" PR_NUMBER=1 REPO=x MAX_FILES=50 \
  MAX_DIFF_LINES=10 MAX_DIFF_BYTES=999999 INCLUDE_PR_DESCRIPTION=false \
  bash scripts/capture-context.sh > /dev/null

expected=$'$(touch PWNED)/x.ts\na b/foo.ts\ncaf\\303\\251.ts\ngone.ts\nrenamed.ts\nsrc/deep/b.ts'
[ "$(cat /tmp/truncated-files.txt)" = "$expected" ] || { echo "FAIL missing list:"; cat /tmp/truncated-files.txt; exit 1; }
grep -q '^missing_file_count=6$' "$T/out" || { echo "FAIL count"; cat "$T/out"; exit 1; }
grep -q '^+B2$' /tmp/pr-diffs/src/deep/b.ts.diff || { echo "FAIL b.ts diff incomplete"; exit 1; }
grep -q '^deleted file mode' /tmp/pr-diffs/gone.ts.diff || { echo "FAIL deleted diff"; exit 1; }
[ -f "/tmp/pr-diffs/\$(touch PWNED)/x.ts.diff" ] || { echo "FAIL odd path diff"; exit 1; }
[ ! -e PWNED ] && [ ! -e /tmp/pr-diffs/PWNED ] || { echo "FAIL path executed"; exit 1; }
grep -q '^+S$' "/tmp/pr-diffs/a b/foo.ts.diff" || { echo "FAIL space-b path"; exit 1; }
[ -f '/tmp/pr-diffs/caf\303\251.ts.diff' ] || { echo "FAIL quoted path"; exit 1; }
echo PASS
