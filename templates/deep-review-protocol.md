## DEEP REVIEW PROTOCOL

You have access to per-file diffs at `/tmp/diffs/<filepath>.diff` and the full checked-out codebase.
Do NOT form opinions from the file manifest alone. Follow this protocol for every changed file:

**Explore, don't just verify.** The hardest bugs are semantic — a function name that promises one thing but the query does another, an unbounded fetch hidden behind a `.slice()`, a filter that silently drops data the caller expects. Don't just check patterns; reason about what the code actually does at runtime and whether that matches its contract.

### For each changed file:
1. **Read the diff** — `Read /tmp/diffs/<filepath>.diff` to understand what changed.
   If the diff file is empty, the file may have been renamed or had only permission/binary changes —
   skip to step 2 and review the full source file directly.
2. **Read the full source file** — understand the surrounding context, not just the changed lines.
   If the diff shows a file was **deleted**, skip this step — the file no longer exists at HEAD.
   Focus instead on callers that may still reference removed exports.
3. **Assess impact** — Before searching for callers, ask: What contract does this code have with its callers? Did the function signature, return type, error behavior, or data shape change? If the change is purely internal (same inputs, same outputs, same side effects), skip steps 4-5 for this file.
4. **Find callers/importers** — `Grep` for files that import or call the changed functions/classes.
   Apply steps 4-6 when the change affects exported functions, classes, types, or data flow.
   Skip caller tracing for: documentation, config files, test files, styles, and files with only internal/private changes.
5. **Read the most relevant callers** — check if the change breaks assumptions. Start with the most suspicious and keep going if something looks wrong.
6. **Check test coverage** — read the corresponding test file if it exists and wasn't already changed in this PR

### Re-reviews (new commits since your last review):
If this is a re-review with new commits, apply the full protocol (steps 1-6) to files changed in the new commits. For files unchanged since your last review, briefly re-check whether your previous findings were addressed — don't repeat the full caller/test tracing.

### After reading all files:
7. **Cross-file analysis** — identify inconsistencies, missing updates, or broken contracts across files
8. **Submit review** — use the same format as below (BLOCKER → HIGH → MEDIUM → LOW)

Do NOT review a file from its diff alone without reading the full source.
The value of this review is understanding implications across the codebase, not surface-level diff reading.
