---
status: completed
created: 2026-05-22
issue: 81
---

# CODEOWNERS Authoritative Comments Plan

## Problem Frame

Agents currently treat every issue or PR commenter as equally directive.
Issue #81 asks Aiur to use GitHub CODEOWNERS as the repo-local authority
signal so comments from code owners are directives, while comments from
non-owners remain advisory unless independently confirmed.

Scope stays focused on GitHub-backed repositories and agent comment-reading
guidance. Aiur will not implement review approval counts or persist
classification beyond the comment data and workpad/log text.

## Requirements Trace

- Parse `.github/CODEOWNERS`, then `CODEOWNERS`, then `docs/CODEOWNERS`, using
  GitHub's file resolution order.
- Match changed paths against CODEOWNERS patterns with last-match-wins.
- Expose helpers for path ownership, PR ownership, and commenter authority.
- Resolve same-org team owners to members through the GitHub API when needed,
  caching per run.
- Treat missing CODEOWNERS as the compatibility fallback where every external
  commenter remains authoritative.
- Treat the agent's own comments as non-authoritative.
- Update shared agent instructions so workpad, issue comments, and review
  feedback use the CODEOWNERS-first rule and mention why a comment counted.

## Implementation Units

### U1: CODEOWNERS Helper

Files:
- Create `elixir/lib/aiur/codeowners.ex`
- Create `elixir/test/aiur/codeowners_test.exs`

Approach:
- Add `Aiur.Codeowners` with `owners_for_path/1`, `owners_for_pr/1`, and
  `authoritative?/2`.
- Provide options for `repo_root`, `changed_paths`, `request_fun`,
  `agent_logins`, and `owner_repo` so tests and callers can avoid global state.
- Return owner entries that preserve both the owner handle and the matched
  pattern, so action logs can say why a comment counted.
- Implement a conservative CODEOWNERS matcher for the syntax Aiur needs:
  comments, inline comments, root-relative patterns, directory patterns,
  wildcard extension patterns, and last-match-wins.
- Resolve team handles with GitHub's team members endpoint and cache results in
  the process dictionary for the current run.

Test scenarios:
- `.github/CODEOWNERS` wins over root/docs files.
- `owners_for_path/1` honors last matching rule.
- Root-relative and directory patterns match expected paths.
- Missing CODEOWNERS returns compatibility fallback from `authoritative?/2`.
- Agent logins are never authoritative.
- Team owners resolve through the injected request function and are cached.

### U2: GitHub Comment Surfaces and Agent Instructions

Files:
- Modify `elixir/lib/aiur/github/client.ex`
- Modify `elixir/lib/aiur/github/tracker.ex` if the public tracker facade needs
  to expose GitHub-specific comment helpers.
- Modify `elixir/prompts/shared-agent-instructions.md`
- Update `elixir/test/aiur/github_client_test.exs`
- Update prompt-related tests if the shared instructions are asserted.

Approach:
- Add narrow GitHub client helpers that fetch changed PR files and PR review
  comments, then annotate each comment with `authoritative`,
  `authority_reason`, and `codeowners` data via `Aiur.Codeowners`.
- Keep issue-only comments compatible by using repo-wide CODEOWNERS owners when
  no changed paths are available.
- Document the runtime behavior in the shared prompt: authoritative comments
  are directives, advisory comments require independent confirmation, conflicts
  between authoritative commenters pause the agent, and workpad/action logs must
  mention the CODEOWNER reason.

Test scenarios:
- PR review comment classification marks owners authoritative and outsiders
  advisory.
- Missing CODEOWNERS preserves today's behavior for non-agent commenters.
- Shared prompt includes the "Whose comments to act on" guidance.

## Risks

- CODEOWNERS syntax is close to gitignore but not identical. The parser should
  skip unsupported invalid constructs rather than inventing behavior.
- Team resolution may fail for private org/team combinations. When the API
  cannot resolve a team, keep the team handle in the owner metadata and avoid
  silently treating unrelated users as owners.
- Existing agent skills outside this repository may read comments directly with
  `gh`. The shared prompt update is still necessary so those paths use the same
  rule even before they call the helper.

## Verification

- `mix test test/aiur/codeowners_test.exs test/aiur/github_client_test.exs`
- Manual CLI verification from `iex -S mix` or `mix run -e` for
  `Aiur.Codeowners.owners_for_path/1` and `Aiur.Codeowners.authoritative?/2`.
- `mix compile`
- `mix format`
- `mix lint`
- `make all`
