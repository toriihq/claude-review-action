## DEEP REVIEW PROTOCOL

You have access to per-file diffs at `/tmp/diffs/<filepath>.diff` and the full checked-out codebase.
Do NOT form opinions from the file manifest alone. Follow this protocol for EVERY changed file:

### For each changed file:
1. **Read the diff** — `Read /tmp/diffs/<filepath>.diff` to understand what changed.
   If the diff file is empty, the file may have been renamed or had only permission/binary changes —
   skip to step 2 and review the full source file directly.
2. **Read the full source file** — understand the surrounding context, not just the changed lines.
   If the diff shows a file was **deleted**, skip this step — the file no longer exists at HEAD.
   Focus instead on callers that may still reference removed exports.
3. **Find callers/importers** — `Grep` for files that import or call the changed functions/classes
4. **Read the most relevant callers** — check if the change breaks assumptions. Start with the most suspicious and keep going if something looks wrong.
5. **Compare with closest sibling** — find the most similar existing file (e.g., same entity type, similar operation). Read it and explicitly compare: auth checks, validation, sanitization, error handling, audit logging, notifications. Flag anything the sibling does that this file doesn't.
6. **Check test coverage** — read the corresponding test file if it exists and wasn't already changed in this PR

### After reading all files:
7. **Cross-file analysis** — identify inconsistencies, missing updates, or broken contracts across files
8. **Submit review** — use the same format as below (BLOCKER → HIGH → MEDIUM → LOW)

Do NOT skip steps. Do NOT review a file from its diff alone without reading the full source.
The value of this review is understanding implications across the codebase, not surface-level diff reading.
