## DEEP REVIEW PROTOCOL

You have access to per-file diffs at `/tmp/diffs/<filepath>.diff` and the full checked-out codebase.
Do NOT form opinions from the file manifest alone. Follow this protocol for EVERY changed file:

**Explore, don't just verify.** The hardest bugs are semantic — a function name that promises one thing but the query does another, an unbounded fetch hidden behind a `.slice()`, a filter that silently drops data the caller expects. Don't just check patterns; reason about what the code actually does at runtime and whether that matches its contract.

### For each changed file:
1. **Read the diff** — `Read /tmp/diffs/<filepath>.diff` to understand what changed.
   If the diff file is empty, the file may have been renamed or had only permission/binary changes —
   skip to step 2 and review the full source file directly.
2. **Read the full source file** — understand the surrounding context, not just the changed lines.
   If the diff shows a file was **deleted**, skip this step — the file no longer exists at HEAD.
   Focus instead on callers that may still reference removed exports.
3. **Find callers/importers** — `Grep` for files that import or call the changed functions/classes
4. **Read the most relevant callers** — check if the change breaks assumptions. Start with the most suspicious and keep going if something looks wrong.
5. **Check test coverage** — read the corresponding test file if it exists and wasn't already changed in this PR

### After reading all files:
6. **Cross-file analysis** — identify inconsistencies, missing updates, or broken contracts across files
7. **Submit review** — use the same format as below (BLOCKER → HIGH → MEDIUM → LOW)

Do NOT skip steps. Do NOT review a file from its diff alone without reading the full source.
The value of this review is understanding implications across the codebase, not surface-level diff reading.
