# Changelog

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
