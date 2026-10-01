# Changelog

## [Unreleased]

### Fixed
- Large prompts failed before Claude started ("Argument list too long"): the prompt is passed as one env var and Linux caps each at 128 KB. When the JSON-escaped prompt would exceed `max-prompt-bytes` (default 120000), the diff is now saved to `/tmp/pr-diff.txt` for Claude to Read instead of inlined. If the prompt is still too big without the diff, the review is skipped with a PR comment and a failed job (and a neutral check with `post-check-run`).
- The `prompt` output heredoc used a guessable delimiter (`EOF_PROMPT_<run id>`); PR text containing it could end the output early. It is now random.

### Added
- `max-prompt-bytes` input.

## [1.0.1] - 2026-03-12

### Fixed
- New-commit detection failed on PRs with >100 commits due to GraphQL `first:100` pagination limit silently dropping newer commits. Now uses HEAD SHA comparison (pagination-proof) for skip detection, and `commits(last:50)` for the focus commit list.
- Consolidated 3 separate reviews API calls into 1.

## [1.0.0] - 2026-03-10

### Added
- Initial release of claude-review-action
- 20 configurable inputs (1 required) with sensible defaults
- Support for 3 trigger types: label, issue comment, PR review comment
- Review guide fetch with default-branch + PR-branch fallback
- PR size guard and diff truncation (line + byte limits)
- Previous review detection via dual API (reviews + comments)
- Relevant commit filtering for re-reviews
- Re-review reconciliation with author response capture
- Configurable review authority (comment-only, request-changes, full)
- Cost tracking appended to review body
- Typed failure messages (max turns, API errors, no output)
- Review dismissal (prompt-injected, best-effort)
- Example workflows: minimal, standard, advanced
