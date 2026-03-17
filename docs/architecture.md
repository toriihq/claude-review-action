# Claude Review Action — Architecture

## Event Flow

```
┌─────────────────────────────────────────────────────────────────────┐
│                        GitHub Event                                  │
│  pull_request [labeled] / issue_comment / review_comment             │
└──────────────────────────────┬──────────────────────────────────────┘
                               │
                               ▼
┌──────────────────────────────────────────────────────────────────────┐
│  1. resolve-pr.sh                                                    │
│                                                                      │
│  Extract PR number, SHA, event type from GitHub event JSON.          │
│  Detect if the triggering label matches deep-review-label.           │
│                                                                      │
│  Outputs: pr_number, pr_sha, event_type, is_deep_label              │
└──────────────────────────────┬──────────────────────────────────────┘
                               │
                               ▼
┌──────────────────────────────────────────────────────────────────────┐
│  2. validate-inputs.sh                                               │
│                                                                      │
│  Validate ANTHROPIC_API_KEY (exists + HTTP 200 health check).        │
│  Validate review-authority is one of: comment-only, request-changes, │
│  full.                                                               │
│  Validate review-depth is one of: normal, deep.                      │
│                                                                      │
│  Posts error comment on PR if validation fails.                      │
└──────────────────────────────┬──────────────────────────────────────┘
                               │
                               ▼
┌──────────────────────────────────────────────────────────────────────┐
│  3. actions/checkout@v4                                              │
│                                                                      │
│  Checkout the PR head commit (fetch-depth: 1).                       │
│  This gives Claude access to the full source tree via Read/Grep.     │
└──────────────────────────────┬──────────────────────────────────────┘
                               │
                               ▼
┌──────────────────────────────────────────────────────────────────────┐
│  4. fetch-guide.sh                                                   │
│                                                                      │
│  Fetch .github/claude-review-guide.md from the repo's default       │
│  branch (not the PR branch — prevents PR from modifying its own      │
│  review rules).                                                      │
│                                                                      │
│  Output: /tmp/review-guide.md                                        │
└──────────────────────────────┬──────────────────────────────────────┘
                               │
                               ▼
┌──────────────────────────────────────────────────────────────────────┐
│  5. Resolve review depth                                             │
│                                                                      │
│  is_deep_label=true OR review-depth=deep  ──►  effective_depth=deep  │
│  otherwise                                ──►  effective_depth=normal │
│                                                                      │
│  If deep:                                                            │
│    effective_model = deep-review-model (e.g., claude-opus-4-6)       │
│    effective_max_turns = deep-max-turns (default 50)                 │
│  If normal:                                                          │
│    effective_model = model (default claude-sonnet-4-6)               │
│    effective_max_turns = max-turns (default 30)                      │
└──────────────────────────────┬──────────────────────────────────────┘
                               │
                               ▼
┌──────────────────────────────────────────────────────────────────────┐
│  6. capture-context.sh                                               │
│                                                                      │
│                    ┌──────────┐                                       │
│                    │  depth?  │                                       │
│                    └────┬─────┘                                       │
│               ┌─────────┴──────────┐                                 │
│               ▼                    ▼                                  │
│  ┌─────────────────────┐  ┌────────────────────────────────────┐     │
│  │      NORMAL         │  │             DEEP                   │     │
│  │                     │  │                                    │     │
│  │  gh pr diff ──►     │  │  File count > deep-max-files?      │     │
│  │  /tmp/pr-diff.txt   │  │    yes ──► skip + comment on PR    │     │
│  │                     │  │    no  ──► continue                 │     │
│  │  Truncate if:       │  │                                    │     │
│  │  > max-diff-lines   │  │  git fetch origin/<base-branch>    │     │
│  │  > max-diff-bytes   │  │                                    │     │
│  │                     │  │  For each changed file:             │     │
│  │  Detect truncated   │  │    mkdir -p /tmp/diffs/<dir>/      │     │
│  │  files list         │  │    git diff origin/<base> HEAD     │     │
│  │                     │  │      -U20 -- <filepath>            │     │
│  │                     │  │      > /tmp/diffs/<filepath>.diff  │     │
│  │                     │  │                                    │     │
│  │                     │  │  -U20 = 20 lines of surrounding    │     │
│  │                     │  │  context (vs default 3)            │     │
│  │                     │  │                                    │     │
│  │                     │  │  Write /tmp/diff-manifest.txt:     │     │
│  │                     │  │  | File | +Added | -Removed |      │     │
│  │                     │  │                                    │     │
│  │                     │  │  Write /tmp/changed-files-stats.txt│     │
│  └─────────────────────┘  └────────────────────────────────────┘     │
│                                                                      │
│  Both: capture PR description ──► /tmp/pr-description.txt            │
│  Output: file_count, diff_truncated                                  │
└──────────────────────────────┬──────────────────────────────────────┘
                               │
                               ▼
┌──────────────────────────────────────────────────────────────────────┐
│  7. detect-previous.sh                                               │
│                                                                      │
│  Find last claude[bot] review on this PR.                            │
│                                                                      │
│  If depth=deep AND skip-if-already-reviewed=true:                    │
│    Read previous review body                                         │
│    If contains "claude-review-depth: deep" ──► respect skip          │
│    If contains "claude-review-depth: normal"                         │
│      or no previous review ──► override skip (deep beats normal)     │
│                                                                      │
│  If skip-if-already-reviewed AND no new commits ──► post skip comment│
│                                                                      │
│  Outputs: has_previous, last_review_date, has_new_commits, commits   │
│  Output file: /tmp/previous-review.txt                               │
└──────────────────────────────┬──────────────────────────────────────┘
                               │
                               ▼
┌──────────────────────────────────────────────────────────────────────┐
│  8. fetch-comments.sh  (if has_previous + include-previous-review)   │
│                                                                      │
│  Fetch author comments posted after last review (for reconciliation).│
│  Output: /tmp/author-comments.txt                                    │
└──────────────────────────────┬──────────────────────────────────────┘
                               │
                               ▼
┌──────────────────────────────────────────────────────────────────────┐
│  9. Pre-flight comment  (deep only)                                  │
│                                                                      │
│  Posts: "🔍 Starting deep review of N files. This will read each     │
│  file's diff, source, callers, and tests."                           │
└──────────────────────────────┬──────────────────────────────────────┘
                               │
                               ▼
┌──────────────────────────────────────────────────────────────────────┐
│  10. build-prompt.sh                                                 │
│                                                                      │
│  Assembles the full prompt from ~12 sections:                        │
│                                                                      │
│  ┌─────────────────────────────────────────────────────────────┐     │
│  │  Section 1:  Context intro ("You are a code reviewer...")   │     │
│  │  Section 2:  Critical rules (BLOCKER-level)                 │     │
│  │  Section 3:  PR description (title + body)                  │     │
│  │  Section 4:  Review guide (.github/claude-review-guide.md)  │     │
│  │                                                             │     │
│  │  Section 7:  ──── FORK ────                                 │     │
│  │  │                                                          │     │
│  │  │  NORMAL:                                                 │     │
│  │  │    Monolithic diff (```diff ... ```)                     │     │
│  │  │    Truncated files list (if applicable)                  │     │
│  │  │                                                          │     │
│  │  │  DEEP:                                                   │     │
│  │  │    File manifest table (path, +added, -removed)          │     │
│  │  │    Instructions: "Per-file diffs at /tmp/diffs/<path>"   │     │
│  │  │    Deep review protocol (from template):                 │     │
│  │  │      1. Read /tmp/diffs/<path>.diff                      │     │
│  │  │      2. Read full source file                            │     │
│  │  │      3. Grep for callers/importers                       │     │
│  │  │      4. Read most relevant callers (up to 3)             │     │
│  │  │      5. Check test coverage                              │     │
│  │  │      6. Cross-file analysis                              │     │
│  │  │      7. Submit review                                    │     │
│  │  │                                                          │     │
│  │  Section 8:  Focus info (new commits since last review)     │     │
│  │  Section 9:  Previous review + reconciliation instructions  │     │
│  │  Section 9b: Author comments since last review              │     │
│  │  Section 10: Review format + submission instructions        │     │
│  │  Section 10b: Dismiss previous reviews command              │     │
│  │  Section 10c: Authority rules (comment-only/rc/full)        │     │
│  │  Section 11: Depth marker + visible label                   │     │
│  │  Section 12: Extra prompt (custom instructions)             │     │
│  └─────────────────────────────────────────────────────────────┘     │
│                                                                      │
│  Output: prompt (full text in GITHUB_OUTPUT)                         │
└──────────────────────────────┬──────────────────────────────────────┘
                               │
                               ▼
┌──────────────────────────────────────────────────────────────────────┐
│  11. claude-code-action@v1                                           │
│                                                                      │
│  Runs Claude with the assembled prompt.                              │
│                                                                      │
│  --model = effective_model (Sonnet or Opus)                          │
│  --max-turns = effective_max_turns (30 or 50)                        │
│  --allowedTools = Bash,Read,Write,Grep,Glob                         │
│                                                                      │
│  ┌─────────────────────────────────────────────────────────────┐     │
│  │                                                             │     │
│  │  NORMAL MODE                    DEEP MODE                   │     │
│  │                                                             │     │
│  │  Claude sees the full diff      Claude sees the file        │     │
│  │  inline in the prompt.          manifest but NOT the diffs. │     │
│  │                                                             │     │
│  │  May use Read tool to check     For each changed file:      │     │
│  │  specific files if needed.      ┌──────────────────────┐    │     │
│  │                                 │ Read /tmp/diffs/     │    │     │
│  │  Typically 3-7 turns.           │   <path>.diff        │    │     │
│  │                                 │        │             │    │     │
│  │                                 │        ▼             │    │     │
│  │                                 │ Read full source     │    │     │
│  │                                 │        │             │    │     │
│  │                                 │        ▼             │    │     │
│  │                                 │ Grep for callers     │    │     │
│  │                                 │        │             │    │     │
│  │                                 │        ▼             │    │     │
│  │                                 │ Read top 3 callers   │    │     │
│  │                                 │        │             │    │     │
│  │                                 │        ▼             │    │     │
│  │                                 │ Read test file       │    │     │
│  │                                 └──────────────────────┘    │     │
│  │                                                             │     │
│  │                                 Then: cross-file analysis   │     │
│  │                                 Typically 12-18 turns.      │     │
│  │                                                             │     │
│  │  ──────────────── Both modes ────────────────               │     │
│  │  Submit review via GitHub PR Review API                     │     │
│  │  Body starts with:                                          │     │
│  │    <!-- claude-review-depth: normal/deep -->                │     │
│  │    📋 Code Review  /  🔬 Deep Review                        │     │
│  │  Then: 🔴 BLOCKERS → 🟠 HIGH → 🟡 MEDIUM → 🔵 LOW → ✅    │     │
│  │  Ends with: Verdict line                                    │     │
│  │                                                             │     │
│  └─────────────────────────────────────────────────────────────┘     │
└──────────────────────────────┬──────────────────────────────────────┘
                               │
                               ▼
┌──────────────────────────────────────────────────────────────────────┐
│  12. post-failure.sh  (if claude-code-action failed)                 │
│                                                                      │
│  Posts comment: "Claude review failed" + link to Actions run.        │
└──────────────────────────────┬──────────────────────────────────────┘
                               │
                               ▼
┌──────────────────────────────────────────────────────────────────────┐
│  13. report-cost.sh  (always, if track-cost=true)                    │
│                                                                      │
│  Parses claude-code-action output for cost/turns/model.              │
│  Appends to review body:                                             │
│    💰 Claude review cost: $X.XX (N turns, model) — [logs](url)      │
└──────────────────────────────────────────────────────────────────────┘
```

## Deep Mode — Per-File Diff Generation

In normal mode, `capture-context.sh` fetches one monolithic diff (`gh pr diff`) and injects it directly into the prompt. Claude sees the entire diff inline but has no per-file separation.

In deep mode, the script generates **individual diff files** on disk that Claude reads via tool calls during the review:

```
/tmp/diffs/
├── src/routes/pauseIntegration.ts.diff      ← git diff -U20
├── src/routes/getOrgStats.ts.diff           ← git diff -U20
├── src/models/integration.ts.diff           ← git diff -U20
└── src/services/auditService.ts.diff        ← git diff -U20
```

### How it works

1. **`capture-context.sh`** runs `git diff origin/<base> HEAD -U20 -- <filepath>` for each changed file
   - `-U20` gives 20 lines of surrounding context (vs the default 3), so Claude sees the neighborhood around each change
   - Each diff is written to `/tmp/diffs/<filepath>.diff`, preserving the directory structure
   - A manifest table (`/tmp/diff-manifest.txt`) lists all files with their +/- line counts

2. **`build-prompt.sh`** does NOT inject the diffs into the prompt. Instead it injects:
   - The file manifest (so Claude knows what changed)
   - Instructions: "Per-file diffs available at `/tmp/diffs/<filepath>.diff`"
   - The deep review protocol (7-step process)

3. **Claude** (during `claude-code-action`) uses `Read` tool calls to access each diff:
   ```
   Read /tmp/diffs/src/routes/pauseIntegration.ts.diff   ← step 1: read the diff
   Read src/routes/pauseIntegration.ts                    ← step 2: read full source
   Grep "pauseIntegration" src/                           ← step 3: find callers
   Read src/routes/deleteIntegration.ts                   ← step 4: read sibling
   Read src/routes/__tests__/pauseIntegration.test.ts     ← step 5: check tests
   ```

### Why per-file diffs instead of monolithic?

| | Normal (monolithic) | Deep (per-file) |
|---|---|---|
| **Diff in prompt** | Yes — entire diff inline | No — only file manifest |
| **Context lines** | 3 (default `gh pr diff`) | 20 (`-U20`) |
| **Claude reads files** | Sometimes (if truncated) | Always (per protocol) |
| **Callers/importers** | Not checked | Grep + Read up to 3 |
| **Test coverage** | Not checked | Read test file if exists |
| **Prompt size** | Grows with diff size | Fixed (manifest only) |
| **Turns** | 3–7 | 12–18 |
| **Cost (Sonnet)** | ~$0.11 | ~$0.19 |
| **Cost (Opus)** | — | ~$0.26 |

The key insight: in deep mode, the diff is **not in the prompt** — it's on disk. This keeps the prompt small and forces Claude to actively read each file's diff as a deliberate step, then follow the protocol to investigate callers and tests. The tool calls are what enable cross-file analysis that catches bugs invisible to diff-only review.
