<p align="center">
  <img src="claude-icon.png" alt="Claude" width="80">
</p>

<h1 align="center">Claude Code Review Action</h1>

<p align="center">
  AI-powered code review using Claude. Drop this into any repo and get reviews in minutes.
</p>

## Quick Start

**1. Add the workflow** — create `.github/workflows/claude-review.yml`:

```yaml
name: Claude Code Review
on:
  pull_request:
    types: [labeled]

jobs:
  review:
    runs-on: ubuntu-latest
    if: github.event.label.name == 'claude-review'
    permissions:
      contents: write
      pull-requests: write
      issues: write
      id-token: write
      actions: read
      checks: read
    steps:
      - uses: toriihq/claude-review-action@v1
        with:
          # Use one of the two authentication methods:
          anthropic-api-key: ${{ secrets.ANTHROPIC_API_KEY }}
          # Or use an OAuth token instead:
          # claude-code-oauth-token: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
```

**2. Add authentication** — Go to repo **Settings > Secrets > Actions** and add one of:
- `ANTHROPIC_API_KEY` — an Anthropic API key ([get one here](https://console.anthropic.com)), or
- `CLAUDE_CODE_OAUTH_TOKEN` — a Claude Code OAuth token (from Claude Code's `/login` command)

**3. Install the Claude GitHub App** — run `/install-github-app` in Claude Code, or follow the [claude-code-action setup](https://github.com/anthropics/claude-code-action#setup)

**4. Create a `claude-review` label** — Go to **Issues > Labels > New label**

**5. Test it** — open any PR, add the `claude-review` label, and watch the Actions tab.

That's it. Claude will post a review within a few minutes.

---

## Make It Better

The action works out of the box, but reviews improve dramatically when you tell Claude about your project. Three levels — use whichever fits:

### Level 1: Tell Claude what it's reviewing

```yaml
- uses: toriihq/claude-review-action@v1
  with:
    anthropic-api-key: ${{ secrets.ANTHROPIC_API_KEY }}
    context-intro: "You are a code reviewer for Acme's billing service — a Node.js/TypeScript API that processes payments and manages subscriptions."
```

One sentence about your project, tech stack, and domain. Default is `"You are a code reviewer."` — generic and unhelpful.

### Level 2: Add critical rules

```yaml
- uses: toriihq/claude-review-action@v1
  with:
    anthropic-api-key: ${{ secrets.ANTHROPIC_API_KEY }}
    context-intro: "You are a code reviewer for Acme's billing service."
    critical-rules: |
      1. All database queries MUST use parameterized statements
      2. All API endpoints MUST check authentication
      3. No secrets or credentials in code or logs
      4. Always yarn, never npm
      5. All new functions MUST have tests
```

These become BLOCKER-level findings. Keep it to 3-7 rules — too many dilutes their impact.

### Level 3: Full review guide

For detailed review standards, create `.github/claude-review-guide.md` in your repo and point to it:

```yaml
- uses: toriihq/claude-review-action@v1
  with:
    anthropic-api-key: ${{ secrets.ANTHROPIC_API_KEY }}
    context-intro: "You are a code reviewer for Acme's billing service."
    critical-rules: |
      1. All database queries MUST use parameterized statements
      2. All API endpoints MUST check authentication
    review-guide-path: .github/claude-review-guide.md
```

A good review guide covers security checklists, testing expectations, code style, architecture rules, and domain-specific patterns. See the [example template](examples/claude-review-guide.md).

### Bonus: `CLAUDE.md` — your repo's built-in knowledge

If your repo has a `CLAUDE.md` file at the root, Claude automatically reads it during every review. This is a built-in Claude Code behavior — no configuration needed.

This means conventions you've already documented for Claude Code (architecture decisions, naming patterns, database conventions, common gotchas) also inform code reviews. Teams with a well-maintained `CLAUDE.md` see noticeably better reviews because Claude understands the project's context beyond just the diff.

**You don't need a `CLAUDE.md` to use this action** — it works great without one. But if you already have one, reviews get better automatically.

**`CLAUDE.md` vs review guide — what goes where?**
- **`CLAUDE.md`** = domain knowledge (project structure, naming conventions, database patterns, tech stack). Tells Claude *what the codebase looks like*.
- **Review guide** = review behavior (severity format, security checklist, testing expectations, scope validation). Tells Claude *how to judge the code*.

They complement each other — don't duplicate content between them. If your `CLAUDE.md` already documents that all DB queries filter by `org_id`, the review guide just needs to say "flag missing `org_id` as a BLOCKER."

---

## Want `@claude` in comments too?

The minimal setup only triggers on labels. To also support `@claude` in PR comments and inline review comments, use this workflow instead:

```yaml
name: Claude Code Review

on:
  pull_request:
    types: [labeled]
  issue_comment:
    types: [created]
  pull_request_review_comment:
    types: [created]

concurrency:
  group: claude-review-${{ github.event.pull_request.number || github.event.issue.number }}
  cancel-in-progress: false

jobs:
  claude-review:
    runs-on: ubuntu-latest
    timeout-minutes: 20
    if: |
      (github.event_name == 'pull_request' && github.event.label.name == 'claude-review') ||
      (github.event_name == 'issue_comment' && github.event.issue.pull_request && contains(github.event.comment.body, '@claude')) ||
      (github.event_name == 'pull_request_review_comment' && contains(github.event.comment.body, '@claude'))
    permissions:
      contents: write
      pull-requests: write
      issues: write
      id-token: write
      actions: read
      checks: read
    steps:
      - uses: toriihq/claude-review-action@v1
        with:
          anthropic-api-key: ${{ secrets.ANTHROPIC_API_KEY }}
          # Add your customization here:
          # context-intro: "..."
          # critical-rules: |
          #   1. ...
          # review-guide-path: .github/claude-review-guide.md
```

Also available as copyable files: [minimal.yml](examples/minimal.yml), [standard.yml](examples/standard.yml), [advanced.yml](examples/advanced.yml).

---

## All Inputs

You must provide one of `anthropic-api-key` or `claude-code-oauth-token`. Everything else has sensible defaults.

### Authentication

| Input | Default | Description |
|-------|---------|-------------|
| `anthropic-api-key` | `""` | Anthropic API key |
| `claude-code-oauth-token` | `""` | Claude Code OAuth token (alternative to API key) |

Provide **one** of the two. If neither is set, the action fails with a clear error. When using an OAuth token, API key validation is skipped.

### Review Content

| Input | Default | Description |
|-------|---------|-------------|
| `context-intro` | `"You are a code reviewer."` | Opening line of prompt — describe your project |
| `critical-rules` | `""` | Multiline string injected as BLOCKER-level rules |
| `review-guide-path` | `""` | Path to repo's review guide markdown |
| `extra-prompt` | `""` | Custom instructions appended to end of prompt |
| `include-pr-description` | `true` | Feed PR title+body into review prompt |

### Limits

| Input | Default | Description |
|-------|---------|-------------|
| `max-files` | `50` | Skip review if PR exceeds this many files |
| `max-diff-lines` | `3000` | Truncate diff after N lines |
| `max-diff-bytes` | `80000` | Truncate diff after N bytes |
| `max-turns` | `30` | Claude conversation turn limit |
| `timeout-minutes` | `20` | Informational — set actual timeout on your job |

### Model & Tools

| Input | Default | Description |
|-------|---------|-------------|
| `model` | `claude-sonnet-4-6` | Claude model to use |
| `allowed-tools` | `Bash,Read,Write,Grep,Glob` | Tools Claude can use during review |

### Review Authority

| Input | Default | Description |
|-------|---------|-------------|
| `review-authority` | `request-changes` | `comment-only`, `request-changes`, or `full` |
| `approve-threshold` | `strict` | For `full`: `strict` (zero MEDIUM+) or `normal` (zero HIGH+) |
| `approve-max-files` | `50` | For `full`: only approve PRs with <= N files |

**Authority levels:**

| Level | Can block? | Can approve? | Behavior |
|-------|-----------|-------------|----------|
| `comment-only` | No | No | Advisory only — never blocks PRs |
| `request-changes` | Yes | No | Blocks on blockers/high. **Default.** |
| `full` | Yes | Yes (guarded) | Can also APPROVE clean PRs, gated by threshold + file count |

### Triggers

| Input | Default | Description |
|-------|---------|-------------|
| `review-label` | `claude-review` | Label trigger name (must match your `if:` condition) |
| `trigger-phrase` | `@claude` | Comment trigger phrase |
| `default-branch` | `""` (auto) | Base branch for guide fetch |

### Behavior

| Input | Default | Description |
|-------|---------|-------------|
| `skip-if-already-reviewed` | `true` | Skip on label trigger if no new commits since last review |
| `include-previous-review` | `true` | Re-review reconciliation with previous findings |
| `track-cost` | `true` | Append cost/turns/model to review comment |
| `dismiss-previous-reviews` | `true` | Dismiss old Claude reviews before posting new one |

---

## Features

- **3 trigger types** — Label, `@claude` in PR comments, `@claude` in inline review comments
- **Re-review reconciliation** — Tracks previous findings, author responses, and new commits. Each HIGH/BLOCKER is marked FIXED, ACCEPTED, or STILL OPEN
- **Relevant commit filtering** — Only flags commits that contribute real changes vs base
- **Truncation awareness** — When diff exceeds limits, detects missing files, instructs Claude to spot-check, and requires disclosure in the verdict
- **PR size guard** — Skips reviews for PRs exceeding configurable file limits
- **Cost tracking** — Appends cost, turns, and model to the review body
- **Review dismissal** — Dismisses previous Claude reviews before posting new ones
- **Typed failure messages** — Distinguishes max-turns, API errors, and missing output
- **Pure bash** — No TypeScript, no node_modules, no build step

## How It Works

```
resolve-pr.sh        → Normalize PR number + SHA across trigger types
  ↓
actions/checkout@v4  → Checkout the PR branch
  ↓
fetch-guide.sh       → Fetch review guide (default branch + PR fallback)
  ↓
capture-context.sh   → Diff capture, size guard, truncation detection
  ↓
detect-previous.sh   → Find previous reviews, calculate new commits
  ↓
fetch-comments.sh    → Author comments since last review (if re-review)
  ↓
build-prompt.sh      → Assemble prompt from all inputs + context
  ↓
claude-code-action   → Run Claude with assembled prompt
  ↓
post-failure.sh      → Post typed failure message (if failed)
  ↓
report-cost.sh       → Append cost/turns/model to review body
```

## Required Permissions

Your workflow job **must** include these permissions:

```yaml
permissions:
  contents: write        # Checkout PR branch, read files
  pull-requests: write   # Post reviews, dismiss reviews, read PR data
  issues: write          # Post comments on PRs (issue_comment API)
  id-token: write        # Required by claude-code-action for auth
  actions: read          # Read workflow run info (for failure URLs)
  checks: read           # Read check status (optional, used by Claude)
```

## Known Limitations

1. **Custom trigger phrases don't get the 👀 reaction** — The Claude GitHub App reacts with 👀 to `@claude` mentions. Custom trigger phrases work but don't get this cosmetic reaction.

2. **Review dismissal is best-effort** — Dismissal commands are in Claude's prompt, not a separate step. If Claude fails mid-review, old reviews may persist.

3. **Failure type detection** — Reliably detects `max_turns` failures. API error subtypes (401 vs 429) fall back to a generic message.

## License

[MIT](LICENSE)
