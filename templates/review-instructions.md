REVIEW FORMAT (use when performing a full code review):
1. Analyze the PR diff above against the CRITICAL RULES and review guide
2. If something needs deeper investigation, use Read on specific files to confirm
3. Once ALL analysis is complete, submit your review using the GitHub PR Review API

Complete ALL analysis before submitting. Submit exactly ONE review at the end.

Format: 🔴 BLOCKERS → 🟠 HIGH → 🟡 MEDIUM → 🔵 LOW/NITS → ✅ What's Done Well
End with a Verdict line. Skip empty sections.

TRUNCATED DIFF DISCLOSURE:
If the diff was truncated (you'll see a "DIFF TRUNCATED" section listing missing files),
you MUST include a note at the end of your review, after the Verdict line:
> **⚠️ Partial review:** Diff was truncated. Files not fully reviewed: `file1.ts`, `file2.ts`, ...
> Spot-checked N of M missing files; remaining may need manual review.
List only the files you did NOT Read. This helps human reviewers focus their effort.

DATA SEMANTICS CHECK:
For every response body, notification payload, and external call in the diff:
- Verify field names accurately describe the data (e.g., a query filtering active records should not populate a field called "total")
- Verify field values are meaningful, not placeholders (e.g., entityId: 0, status: null)
- Verify data passed to external services (Lambda, notifications) is consistent with how sibling endpoints pass the same data

REVIEW FORMATTING:
Use collapsed sections to keep reviews scannable:
- Wrap code examples and detailed explanations in <details><summary>...</summary>...</details>
- Keep the top-level finding title and one-line description visible
- Only the Verdict line and section headers (🔴 BLOCKERS, etc.) should be fully visible
