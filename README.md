<p align="center">
  <img src="claude-icon.png" alt="Claude" width="80">
</p>

<h1 align="center">Claude Code Review Action</h1>

<p align="center">
  AI-powered code review using Claude. A reusable GitHub Composite Action that handles diff capture, re-review reconciliation, cost tracking, and configurable review authority.
</p>

## Setup

### Prerequisites

1. **Anthropic API key** — Get one from [console.anthropic.com](https://console.anthropic.com). Add it as a repository or organization secret:
   - Go to **Settings → Secrets and variables → Actions → New repository secret**
   - Name: `ANTHROPIC_API_KEY`
   - Value: your `sk-ant-...` key

2. **Claude GitHub App** — The action uses [anthropics/claude-code-action](https://github.com/anthropics/claude-code-action) under the hood. You must install the Claude GitHub App on your repo (run `/install-github-app` in Claude Code, or follow the [claude-code-action setup](https://github.com/anthropics/claude-code-action#setup)). This is **required** — without it, reviews post as `github-actions[bot]` instead of `claude[bot]`, and re-review detection, review dismissal, and cost tracking all break.

3. **Create the `claude-review` label** — Go to **Issues → Labels → New label** and create a label named `claude-review`. This is the trigger — adding it to a PR starts the review. (You can customize the label name via the `review-label` input, but your workflow's `if:` condition must match.)

4. **Private action repo access** (if this action repo is private) — Go to the action repo's **Settings → Actions → General → Access** and select "Accessible from repositories in the organization". Without this, other repos in the org can't reference the action.

### Optional

5. **Review guide** — Create a `.github/claude-review-guide.md` file in your repo with your team's review standards. See the [example template](examples/claude-review-guide.md). The action fetches this file from your default branch and injects it into the review prompt.

6. **GitHub Actions permissions** — If your org restricts Actions permissions, ensure the workflow has access to the permissions listed in [Required Permissions](#required-permissions) below.

### Add the workflow

Create `.github/workflows/claude-review.yml` in your repo:

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
          anthropic-api-key: ${{ secrets.ANTHROPIC_API_KEY }}
```

### Test it

1. Open any PR in your repo
2. Add the `claude-review` label
3. Watch the Actions tab — Claude will post a review within a few minutes

### Want `@claude` comment triggers too?

Use the [standard example](examples/standard.yml) instead — it adds support for `@claude` in PR comments and inline review comments, plus concurrency control.

## Features

- **3 trigger types** — Label (`claude-review`), `@claude` in PR comments, `@claude` in inline review comments
- **Re-review reconciliation** — Tracks previous findings, author responses, and new commits
- **Relevant commit filtering** — Only flags commits that contribute real changes vs base
- **Configurable review authority** — Comment-only, request-changes, or full (with auto-approve)
- **PR size guard** — Skips reviews for PRs exceeding configurable file limits
- **Diff truncation** — Line and byte limits prevent token overflow
- **Cost tracking** — Appends cost, turns, and model to the review body
- **Review dismissal** — Dismisses previous Claude reviews before posting new ones
- **Typed failure messages** — Distinguishes max-turns, API errors, and missing output
- **Review guide support** — Fetches guide from default branch with PR branch fallback
- **Pure bash** — No TypeScript, no node_modules, no build step

## Inputs

### Required

| Input | Description |
|-------|-------------|
| `anthropic-api-key` | Anthropic API key (from secrets) |

### Review Content

| Input | Default | Description |
|-------|---------|-------------|
| `review-guide-path` | `""` | Path to repo's review guide markdown. Empty = no guide |
| `critical-rules` | `""` | Multiline string injected as BLOCKER-level rules |
| `extra-prompt` | `""` | Appended to end of prompt (custom instructions) |
| `include-pr-description` | `true` | Feed PR title+body into review prompt |
| `context-intro` | `"You are a code reviewer."` | Opening line of prompt (repo identity/context) |

### Limits

| Input | Default | Description |
|-------|---------|-------------|
| `max-files` | `50` | Skip review if PR exceeds this many files |
| `max-diff-lines` | `3000` | Truncate diff after N lines |
| `max-diff-bytes` | `80000` | Truncate diff after N bytes |
| `max-turns` | `30` | Claude conversation turn limit |
| `timeout-minutes` | `20` | Job timeout (informational — set actual timeout on your job) |

### Model & Tools

| Input | Default | Description |
|-------|---------|-------------|
| `model` | `claude-sonnet-4-6` | Claude model to use |
| `allowed-tools` | `Bash,Read,Write,Grep,Glob` | Tools Claude can use during review |

### Review Authority

| Input | Default | Description |
|-------|---------|-------------|
| `review-authority` | `request-changes` | Level: `comment-only`, `request-changes`, or `full` |
| `approve-threshold` | `strict` | For `full` mode: `strict` (zero MEDIUM+) or `normal` (zero HIGH+) |
| `approve-max-files` | `50` | For `full` mode: only approve PRs with <= N files |

### Triggers

| Input | Default | Description |
|-------|---------|-------------|
| `review-label` | `claude-review` | Label name for `label_trigger`. Must match your workflow's `if:` |
| `trigger-phrase` | `@claude` | Comment trigger phrase (excluded from author feedback) |
| `default-branch` | `""` (auto-detect) | Base branch for guide fetch. Empty = auto-detect |

### Behavior

| Input | Default | Description |
|-------|---------|-------------|
| `skip-if-already-reviewed` | `true` | Skip on label trigger if no new commits since last review |
| `include-previous-review` | `true` | Enable re-review reconciliation with previous findings |
| `track-cost` | `true` | Append cost/turns/model to review comment |
| `dismiss-previous-reviews` | `true` | Dismiss old Claude reviews before posting new one |

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

## Examples

See the [`examples/`](examples/) directory:

- **[minimal.yml](examples/minimal.yml)** — Label trigger only (~20 lines)
- **[standard.yml](examples/standard.yml)** — 3 triggers, review guide, critical rules
- **[advanced.yml](examples/advanced.yml)** — All 20 inputs with explanatory comments
- **[claude-review-guide.md](examples/claude-review-guide.md)** — Example review guide template

## How It Works

```
resolve-pr.sh        → Normalize PR number + SHA across trigger types
  ↓
actions/checkout@v4  → Checkout the PR branch
  ↓
fetch-guide.sh       → Fetch review guide (default branch + PR fallback)
  ↓
capture-context.sh   → Diff capture, size guard, PR description
  ↓
detect-previous.sh   → Find previous reviews, calculate new commits
  ↓
fetch-comments.sh    → Author comments since last review (if re-review)
  ↓
build-prompt.sh      → Assemble 11-section prompt from all inputs
  ↓
claude-code-action   → Run Claude with assembled prompt
  ↓
post-failure.sh      → Post typed failure message (if failed)
  ↓
report-cost.sh       → Append cost/turns/model to review body
```

## Review Authority Levels

| Level | Can block? | Can approve? | Behavior |
|-------|-----------|-------------|----------|
| `comment-only` | No | No | Always posts as COMMENT. Advisory only — never blocks PRs. |
| `request-changes` | Yes | Yes | REQUEST_CHANGES for blockers/high, COMMENT for medium, APPROVE for clean. **Default.** |
| `full` | Yes | Yes (guarded) | Like `request-changes`, but approval is gated by `approve-threshold` (severity cutoff) and `approve-max-files` (PR size limit). |

## Re-review Reconciliation

When Claude detects a previous review on the same PR:

1. **Finds previous review** via dual API detection (PR reviews + comments fallback)
2. **Filters new commits** to only those contributing real changes vs base branch
3. **Captures author responses** (PR comments + inline comments since last review)
4. **Reconciles findings** — each previous HIGH/BLOCKER is marked FIXED, ACCEPTED, or STILL OPEN
5. **New verdict** reflects reconciliation — only STILL OPEN findings block approval

Set `include-previous-review: false` to disable reconciliation (always full review, no history).

## Migration from Standalone Workflow

If you have an existing 500+ line Claude review workflow:

1. Replace the entire workflow file with the [standard example](examples/standard.yml)
2. Keep your existing `.github/claude-review-guide.md` unchanged
3. Move critical rules from bash heredoc to `critical-rules:` input
4. Test on one PR — verify review quality matches
5. Delete the old workflow steps

## Known Limitations

1. **Review dismissal is best-effort** — Dismissal commands are injected into Claude's prompt, not a separate step. If Claude's API call fails mid-review, old reviews may persist.

2. **Failure type detection** — The action reliably detects `max_turns` failures. API error subtypes (401 vs 429) may not be distinguishable and fall back to a generic message.

3. **Shallow checkout** — Uses `fetch-depth: 1` for speed. Sufficient for Claude's file reads, but `detect-previous.sh` fetches the base branch separately for commit comparison.

## Contributing

This is a pure bash + markdown project — no build step required.

1. Create a feature branch
2. Make your changes
3. Test by pointing a workflow at your branch: `uses: toriihq/claude-review-action@your-branch`
4. Open a pull request

## License

[MIT](LICENSE)
