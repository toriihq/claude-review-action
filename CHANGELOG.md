# Changelog

## [Unreleased]

### Fixed
- When `claude-code-action` skipped itself (e.g. the branch's workflow file differs from the default branch), its step still reported success and the job went green with no review. The action now detects the missing execution output, comments on the PR and fails the job. Real Claude failures keep their current behaviour.
- Truncated-diff fallback reviewed whole files at HEAD, not their changes. The full diff is now split per file into `/tmp/pr-diffs/<path>.diff` and Claude is pointed at those, so removed lines and deleted files are covered.
- The file cut mid-way by truncation was counted as included, silently dropping its later hunks. It is now listed as missing.
- The missing-file list is derived from the diff itself (new paths), so renamed files are no longer always reported missing.

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
