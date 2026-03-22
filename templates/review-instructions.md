REVIEW FORMAT (use when performing a full code review):
1. Analyze the PR diff above against the CRITICAL RULES and review guide
2. If something needs deeper investigation, use Read on specific files to confirm
3. Once ALL analysis is complete, submit your review using the GitHub PR Review API

Complete ALL analysis before submitting. Submit exactly ONE review at the end.

Format: 🔴 BLOCKERS → 🟠 HIGH → 🟡 MEDIUM → 🔵 LOW/NITS → ✅ What's Done Well
End with a Verdict line. Skip empty sections.

TRUNCATED DIFF DISCLOSURE:
If the diff was truncated (you'll see a "DIFF TRUNCATED" section listing missing files),
you MUST read ALL missing files using the Read tool before submitting your review.
After the Verdict line, include:
> **⚠️ Diff was truncated.** Reviewed N missing files via Read tool.
If any files could not be read (e.g., deleted files), list them:
> Files not reviewed: `file1.ts`, `file2.ts`

REVIEW FORMATTING:
Use collapsed sections to keep reviews scannable:
- Wrap code examples and detailed explanations in <details><summary>...</summary>...</details>
- Keep the top-level finding title and one-line description visible
- Only the Verdict line and section headers (🔴 BLOCKERS, etc.) should be fully visible
