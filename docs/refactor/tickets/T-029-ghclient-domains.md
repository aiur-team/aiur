# T-029: github client wave 2: Issues, Comments, PullRequests, RepoEvents, DependenciesApi, Teams

**Phase:** 3
**Depends-on:** T-028
**Labels:** `agent:todo` `refactor` `phase:3` `complexity:3`

## Problem / context

`src/lib/aiur/github/client.ex` is a 2,597-line module (`Aiur.GitHub.Client`) —
the transport, error taxonomy, auth preflight, every REST/GraphQL domain, the
review-thread reply/resolve machinery, and the label-encoded issue state
machine, all in one file. It sits inside hotspot #1 of
`docs/refactor/research-history-hotspots.md` ("GitHub event ingestion &
comment→wake/rework pipeline"). The decomposition plan in
`docs/refactor/research-arch/giant-client.md` splits it into ~17 focused
modules under `src/lib/aiur/github/`, extracted in strictly serialized waves,
with `Aiur.GitHub.Client` retained forever as a thin facade of explicit
one-line wrappers (the load-bearing `:github_client_module` behaviour contract —
see giant-client.md §"Load-bearing external contract").

T-028 (this ticket's dependency) is wave 1: it extracts `Aiur.GitHub.Transport`,
`Aiur.GitHub.Errors`, `Aiur.GitHub.AuthPreflight`, `Aiur.GitHub.StatePolicy`,
and `Aiur.GitHub.BotIdentity`, and leaves the facade routing all remaining code
through them. **This ticket is wave 2**: extract the six pure per-API-domain
modules — `Aiur.GitHub.Issues`, `Aiur.GitHub.Comments`,
`Aiur.GitHub.PullRequests`, `Aiur.GitHub.RepoEvents`,
`Aiur.GitHub.DependenciesApi`, `Aiur.GitHub.Teams` — onto the T-028 `Transport`.
These are the REST-read/write domains with no review-thread entanglement;
giant-client.md §3 sequences them as its waves 3 (Issues + DependenciesApi +
Teams) and 4 (RepoEvents + Comments + PullRequests). The review-thread modules
and the issue-state writer are wave 3 (T-030), not here.

This is a **verbatim code move, not a rewrite**. Function bodies, guards, clause
order, heredoc queries, `Logger` messages, and comments move unchanged. Public
function signatures — including default-arg zero/one-arity variants — and all
observable behavior are unchanged; the facade delegates to the extracted
modules with explicit one-line wrappers so every existing caller keeps working.
Test files are never edited. **Line numbers below were verified against the
branch state at ticket-writing time, but T-028 lands first and will shift them;
if a line number has drifted, locate the function by name — the function names
and their module assignments (giant-client.md §2 name map) are the binding
contract.** giant-client.md §1 is the full function/line census.

## Scope (exact)

Precondition: T-028 is merged, so `Aiur.GitHub.Transport`, `Aiur.GitHub.Errors`,
and `Aiur.GitHub.StatePolicy` exist and the facade already calls them. Every
module below depends **downward only**: domain module → (`StatePolicy` for
Issues) → `Transport` | `Errors` → `Aiur.GitHub.Config`. Nothing you create may
call back into `Aiur.GitHub.Client` (that would be a dependency cycle). Where a
moved body currently calls a helper that T-028 relocated (e.g.
`normalize_state/1`, `require_token/0`, `require_token/1`, `fetch_json_list/3`,
`github_headers/2`, `github_graphql/4`, `parse_next_page_url/1`, `header/2`,
`classify_error/1`, `github_status_error/1`), requalify the call to the T-028
module (`StatePolicy.`/`Transport.`/`Errors.`) — do **not** change which arity
or which helper is called.

**Token-resolution arity is behaviorally load-bearing (giant-client.md risk #2,
FI-GH-002): do NOT unify or swap `require_token/0` and `require_token/1` at any
call site.** Move each domain's calls byte-identical: Issues, `create_comment`,
and DependenciesApi use `Transport.require_token/0` (config-only); RepoEvents,
PullRequests, the repo comment streams, and `fetch_issue_comments` use
`Transport.require_token/1` (opts `:token` → literal `"test-gh-token"` when a
`:request_fun` is injected → config). Keep whatever arity each site uses today.

1. **Create `src/lib/aiur/github/issues.ex`** defining
   `defmodule Aiur.GitHub.Issues`. Add a `@moduledoc`, `alias Aiur.Issue`,
   `alias Aiur.GitHub.{Config, Errors, StatePolicy, Transport}`, and a `@spec`
   on every public def. Move, verbatim (each moved `defp` becomes a public `def`
   with a `@spec`; each moved public `def` keeps its exact signature and default
   args):
   - Public (currently in `client.ex`): `fetch_candidate_issues/1` (~L275),
     `fetch_issues_by_states/2` (~L280), `fetch_issue_states_by_ids/2` (~L286),
     `fetch_issue_raw/2` (~L419).
   - Private → public: `fetch_issues_for_each_label/6` (~L1120),
     `reduce_label_issues/7` (~L1133), `do_fetch_issues_by_states/2` (~L1144),
     `do_fetch_issue_states_by_ids/2` (~L1155), `do_list_issues/6` (~L1165),
     `do_fetch_issues_by_id_list/6` (~L1180), `reduce_fetch_issue/7` (~L1193),
     `normalize_issue/4` (~L2329), `extract_state/3` (~L2351, both clauses),
     `extract_priority/1` (~L2363), `parse_priority_label/1` (~L2367),
     `parse_priority_int/1` (~L2374), `parse_datetime/1` (~L2381, both clauses).
   - The inline `normalize_state(...)` calls inside `fetch_candidate_issues`/
     `do_fetch_issues_by_states` (the `<prefix>:<state>` label construction of
     FI-GH-012) become `StatePolicy.normalize_state(...)` — same argument, same
     result. `extract_state/3`'s `"closed"` clause (FI-GH-014, closed issue →
     `"Closed"` overriding stale `agent:*` labels) moves byte-for-byte.

2. **Create `src/lib/aiur/github/comments.ex`** defining
   `defmodule Aiur.GitHub.Comments`. Add `@moduledoc`, `alias Aiur.Codeowners`,
   `alias Aiur.GitHub.{Config, Errors, Transport}`, and `@spec`s. Move, verbatim:
   - Public: `create_comment/3` (~L291, the full head + all clauses),
     `fetch_recent_repo_review_comments/1` (~L613),
     `fetch_recent_repo_issue_comments/1` (~L636), `fetch_issue_comments/2`
     (~L676), `fetch_classified_issue_comments/2` (~L831).
   - Private → public: `repo_comment_stream_query/1` (~L646),
     `fetch_repo_comment_stream/4` (~L652, both clauses), `comment_query/1`
     (~L1222).
   - `fetch_classified_issue_comments/2` keeps its `Aiur.Codeowners` call verbatim
     (FI-GH-028). The repo comment streams keep the `since` cursor + `Link
     rel="next"` pagination exactly (FI-GH-065 wake-pipeline entry points).

3. **Create `src/lib/aiur/github/pull_requests.ex`** defining
   `defmodule Aiur.GitHub.PullRequests`. Add `@moduledoc`,
   `alias Aiur.Codeowners`, `alias Aiur.GitHub.{Config, Errors, Transport}`, and
   `@spec`s. Move, verbatim:
   - Public: `fetch_pull_request_changed_paths/2` (~L486),
     `fetch_pull_request_review_comments/2` (~L504),
     `fetch_open_pull_request_for_branch/2` (~L521),
     `fetch_open_pull_requests_by_label/2` (~L556),
     `fetch_pull_request_head_ref/2` (~L695), `fetch_open_pull_request/2`
     (~L729), `fetch_classified_pr_review_comments/2` (~L760).
   - Private → public: `fetch_labeled_open_pull_requests/5` (~L570, both
     clauses), `pull_request_has_label?/2` (~L587, all three clauses),
     `open_pull_request_or_nil/1` (~L754, all three clauses).
   - Preserve verbatim (giant-client.md risk #6): `open_pull_request_or_nil/1`
     maps closed/merged → `nil` (FI-GH-027 routing signal);
     `fetch_open_pull_request/2` maps 404 → `{:ok, nil}` (not an error);
     `fetch_open_pull_requests_by_label/2` follows `Link rel="next"` so watched
     PRs past page 1 are not dropped (FI-GH-064); the `aiur/<issue#>` head-ref
     branch match in `fetch_open_pull_request_for_branch/2` (FI-GH-026) is
     unchanged.

4. **Create `src/lib/aiur/github/repo_events.ex`** defining
   `defmodule Aiur.GitHub.RepoEvents`. Add `@moduledoc`,
   `alias Aiur.GitHub.{Config, Errors, Transport}`, and `@spec`s. Move, verbatim:
   - Public: `fetch_repo_events/1` (~L336) — the `/repos/{o}/{r}/events`
     firehose with `If-None-Match`, 304 → `{:not_modified, etag,
     poll_interval}`, and the prior-etag-preserved-on-omitted-header behavior
     (FI-GH-040, giant-client.md risk #6 — the caching-proxy note comment at the
     tail of this function moves with it).
   - Private → public: `poll_interval/1` (~L2585, default 60s, non-integer
     fallback).

5. **Create `src/lib/aiur/github/dependencies_api.ex`** defining
   `defmodule Aiur.GitHub.DependenciesApi`. Add `@moduledoc`,
   `alias Aiur.GitHub.{Config, Errors, Transport}`, `@spec`s, and move the
   `@dependencies_api_version "2026-03-10"` module attribute (~L2503) into this
   module. Move, verbatim:
   - Public: `fetch_blocked_by/2` (~L378), `fetch_blocking/2` (~L387),
     `add_dependency/3` (~L401, full head + clauses), `remove_dependency/3`
     (~L408, full head + clauses).
   - Private → public: `dependency_get/3` (~L2505), `dependency_mutate/4`
     (~L2531).
   - The distinct `X-GitHub-Api-Version: 2026-03-10` header (FI-GH-022 — every
     OTHER call uses `2022-11-28`) is set via the moved `@dependencies_api_version`
     passed through `Transport.github_headers/2`'s `:api_version` override; move
     the API-version comment block above `dependency_get/3` with it. Naming note:
     the module is `Aiur.GitHub.DependenciesApi` (NOT `Dependencies`) — this is
     the binding name from giant-client.md §2 #9, chosen to avoid colliding with
     the existing policy module `Aiur.GitHub.IssueDependencies`, which is
     untouched and keeps calling through the facade this wave.

6. **Create `src/lib/aiur/github/teams.ex`** defining
   `defmodule Aiur.GitHub.Teams`. Add `@moduledoc`,
   `alias Aiur.GitHub.{Config, Errors, Transport}`, and `@spec`s. Move, verbatim:
   - Public: `fetch_team_members/3` (~L442) — `/orgs/{org}/teams/{team}/members`
     at `per_page=100` following `Link rel="next"` across all pages (FI-GH-037,
     consumed by `Aiur.GitHub.CodeOwners`).
   - Private → public: `fetch_member_logins/4` (~L450, both clauses),
     `member_login_list/1` (~L467, both clauses).

7. **Edit `src/lib/aiur/github/client.ex` (the facade):**
   - Delete every moved definition (public and private) and its moved comments
     listed in steps 1–6, and delete the moved `@dependencies_api_version`
     attribute.
   - Add `alias Aiur.GitHub.{Comments, DependenciesApi, Issues, PullRequests,
     RepoEvents, Teams}` alongside the aliases T-028 already added.
   - Replace each moved **public** function with an explicit one-line wrapper
     that preserves the exact name, arity, and default args (NOT `defdelegate` —
     default args like `/1` vs `/2` must survive per giant-client.md risk #1),
     e.g.
     `def fetch_candidate_issues(opts \\ []), do: Issues.fetch_candidate_issues(opts)`;
     `def create_comment(issue_number, body, opts \\ []), do: Comments.create_comment(issue_number, body, opts)`;
     `def add_dependency(blocked, blocker, opts \\ []), do: DependenciesApi.add_dependency(blocked, blocker, opts)`.
     Keep the existing `@spec` / `@doc` lines on these facade functions if
     present.
   - Do NOT leave any moved **private** helper (or a delegating `defp` for it) in
     the facade: the private helpers moved wholesale into their domain module and
     are now only called from inside that module. If, after deleting, the
     compiler reports a remaining facade function still calling a moved private
     helper, that function was mis-assigned — recheck the name map; do not
     recreate the helper in the facade.
   - Mechanical loop: make the deletions + wrappers, run
     `mix compile --warnings-as-errors`, fix exactly what the compiler names,
     repeat until clean. An unused `defp` or `alias` fails `--warnings-as-errors`.

8. **Edit `src/mix.exs`:** do NOT add any of the six new modules to
   `test_coverage.ignore_modules`. New modules are not coverage-exempt; the 85%
   threshold enforces their tests. Leave the existing `Aiur.GitHub.Client`,
   `Aiur.GitHub.Config`, and `Aiur.GitHub.Tracker` entries and every other entry
   exactly as they are. (This step is a no-op edit-check: confirm the list is
   unchanged and contains none of the six new module names.)

9. **Create one test file per new module** (new files only; never touch any
   existing test file). Each exercises the extracted module directly by injecting
   a `:request_fun` (so no network, no env token needed — the `"test-gh-token"`
   seam applies). Cover the FI behaviors named below; these also fill the
   "missing characterization coverage" gaps flagged in giant-client.md §4:
   - `src/test/aiur/github/issues_test.exs` — `fetch_candidate_issues` issues one
     request per `<prefix>:<state>` label and dedups by id, empty state list →
     `{:ok, []}` with no request (FI-GH-012); `fetch_issue_states_by_ids` skips
     404s and preserves order (FI-GH-013); `normalize_issue`/`extract_state`
     return `"Closed"` for a closed GitHub issue overriding stale labels,
     priority from `priority:N`, timestamps parsed-or-nil (FI-GH-014);
     `fetch_issue_raw` returns the raw map with the internal numeric `id`
     (FI-GH-023).
   - `src/test/aiur/github/comments_test.exs` — `create_comment` → `:ok` on
     200/201, `{:error, {:github_api_status, status}}` otherwise (FI-GH-018);
     `fetch_recent_repo_review_comments`/`fetch_recent_repo_issue_comments`
     `since`-cursor query shape + `Link rel="next"` pagination + error taxonomy
     (FI-GH-065 — previously untested); `fetch_issue_comments` and
     `fetch_classified_issue_comments` (authoritative-vs-not classification via
     CODEOWNERS, FI-GH-028).
   - `src/test/aiur/github/pull_requests_test.exs` —
     `fetch_open_pull_request_for_branch` matches the `aiur/<issue#>` head
     (FI-GH-026); `fetch_open_pull_request` 404 → `{:ok, nil}` and closed/merged →
     `{:ok, nil}` (FI-GH-027); `fetch_pull_request_head_ref` →
     `{:error, :head_ref_missing}` when absent; `fetch_open_pull_requests_by_label`
     client-side label filter + `Link rel="next"` pagination (FI-GH-064);
     `fetch_pull_request_changed_paths` and `fetch_pull_request_review_comments`
     shape pins; `fetch_classified_pr_review_comments` per-path classification
     (FI-GH-028).
   - `src/test/aiur/github/repo_events_test.exs` — `fetch_repo_events` 304 →
     `{:not_modified, etag, poll_interval}`, prior etag preserved when GitHub
     omits the response ETag header on 200 AND 304, `X-Poll-Interval` default 60s
     (FI-GH-040); `poll_interval/1` non-integer header → 60 fallback.
   - `src/test/aiur/github/dependencies_api_test.exs` — `fetch_blocked_by`/
     `fetch_blocking` GET the right paths; `add_dependency` POSTs
     `{"issue_id": blocker_internal_id}`, `remove_dependency` DELETEs; ALL four
     send `X-GitHub-Api-Version: 2026-03-10` (assert the request header)
     (FI-GH-022).
   - `src/test/aiur/github/teams_test.exs` — `fetch_team_members` lists at
     `per_page=100`, follows `Link rel="next"` across pages, 403 surfaces as an
     error (FI-GH-037).
   - Follow the authoring rules in `docs/refactor/regression-safety.md` §2: no
     `Process.sleep` synchronization, `assert_receive` windows ≥ 2000 ms if used
     at all (these are pure injected-`request_fun` tests and should need none),
     no reliance on `:log_file`/global env, `async: false` unless the file
     provably touches no shared singleton.

10. **Run the Agent gate** (below) after each of steps 1–9 lands and once at the
    end. Every existing test — including all of `src/test/aiur/regression/`,
    `src/test/aiur/github_client_test.exs`,
    `src/test/aiur/github/client_events_test.exs`,
    `src/test/aiur/github_auth_preflight_test.exs`,
    `src/test/aiur/github_issue_dependencies_test.exs`,
    `src/test/aiur/github/code_owners_test.exs`, and
    `src/test/aiur/tracker_github_test.exs` — must pass with zero edits to any
    test file (they all exercise the facade, which now delegates).

## Files

- Create:
  `src/lib/aiur/github/issues.ex`,
  `src/lib/aiur/github/comments.ex`,
  `src/lib/aiur/github/pull_requests.ex`,
  `src/lib/aiur/github/repo_events.ex`,
  `src/lib/aiur/github/dependencies_api.ex`,
  `src/lib/aiur/github/teams.ex`,
  `src/test/aiur/github/issues_test.exs`,
  `src/test/aiur/github/comments_test.exs`,
  `src/test/aiur/github/pull_requests_test.exs`,
  `src/test/aiur/github/repo_events_test.exs`,
  `src/test/aiur/github/dependencies_api_test.exs`,
  `src/test/aiur/github/teams_test.exs`
- Modify: `src/lib/aiur/github/client.ex`, `src/mix.exs`
- Test: the six created test files above; all existing GitHub-client and
  regression test files (listed in Scope step 10) run unmodified as the behavior
  pin.

## Out of scope

- The review-thread modules (`Aiur.GitHub.ReviewThreads`,
  `ReviewThreads.Reply`, `ReviewThreads.Resolution`,
  `ReviewThreads.ResolutionPolicy`), `Aiur.GitHub.HumanReviewGate`, and
  `Aiur.GitHub.IssueState` — those are wave 3 (T-030). Do not touch
  `reply_to_review_thread`, `resolve_review_thread`,
  `fetch_unaddressed_pr_review_thread_comments`, `verify_human_review_ready`,
  `update_issue_state`, `add_label`, `remove_label`, or any of their private
  helpers, and do not move the review-thread GraphQL heredocs.
- `Aiur.GitHub.Transport`, `Aiur.GitHub.Errors`, `Aiur.GitHub.AuthPreflight`,
  `Aiur.GitHub.StatePolicy`, `Aiur.GitHub.BotIdentity` — created by T-028; you
  only *call* them, never edit them.
- `Aiur.GitHub.Config` (token cache / `persistent_term`), `Aiur.GitHub.Tracker`,
  `Aiur.GitHub.IssueDependencies` (the BFS cycle-check policy),
  `Aiur.GitHub.CodeOwners`, `Aiur.GitHub.Connectivity`, `Aiur.GitHub.Labels`,
  and every caller (`orchestrator.ex`, `events/github_firehose.ex`,
  `events/github_comments_poller.ex`, `codex/dynamic_tool.ex`) — unchanged; they
  keep calling through the facade (caller migration is giant-client.md's optional
  wave 9, a separate future ticket).
- Any edit to any existing file under `src/test/` (including moving pins to match
  the new modules).
- Any behavior, signature, arity, default-arg, log-message, header, query-shape,
  or config change whatsoever. No unifying `require_token/0` with `/1`.

## Inventory-IDs

From `docs/refactor/feature-inventory/gh.md` — the features whose implementing
functions this ticket moves (behavior must be identical after the move):

- FI-GH-002 (per-call token requirement + `"test-gh-token"` seam — the
  `require_token/0` vs `/1` distinction preserved per call site)
- FI-GH-012 (candidate issue fetch by state labels — one request per
  `<prefix>:<state>`, dedup by id, empty-list short-circuit)
- FI-GH-013 (fetch issue states by ids — 404-tolerant, order-preserving)
- FI-GH-014 (issue normalization to `Aiur.Issue` — closed → `"Closed"`, priority
  label, timestamps)
- FI-GH-018 (`create_comment` on issue)
- FI-GH-022 (Issue Dependencies REST wrappers pinned to API version
  `2026-03-10`)
- FI-GH-023 (`fetch_issue_raw` — internal numeric id resolution)
- FI-GH-026 (canonical branch → open PR mapping, `aiur/<issue#>` head)
- FI-GH-027 (PR head-ref + open-PR lookup; 404/closed/merged → `{:ok, nil}`)
- FI-GH-028 (CODEOWNERS-classified PR review / issue comments)
- FI-GH-037 (team member expansion with `Link` pagination)
- FI-GH-040 (ETag-conditional repo `/events` polling — 304, etag-preserve,
  `X-Poll-Interval`)
- FI-GH-064 (watched-PR listing by label with `Link rel="next"` pagination)
- FI-GH-065 (repo-wide comment streams — the `since`-cursor review/issue comment
  fetchers, previously untested directly)

## Characterization-tests

- The GitHub-ingestion characterization file landed by T-008:
  `src/test/aiur/regression/github_ingestion_test.exs`. The entire
  `src/test/aiur/regression/` directory must pass UNMODIFIED.
- Existing behavior pins that must also pass unmodified (all exercise the facade,
  which now delegates to the extracted modules):
  `src/test/aiur/github_client_test.exs`,
  `src/test/aiur/github/client_events_test.exs` (repo events etag/poll-interval,
  dependencies API-version header, labeled-PR pagination — the direct pin for
  RepoEvents/DependenciesApi/PullRequests),
  `src/test/aiur/github_auth_preflight_test.exs`,
  `src/test/aiur/github_issue_dependencies_test.exs`,
  `src/test/aiur/github/code_owners_test.exs` (`fetch_team_members`),
  `src/test/aiur/tracker_github_test.exs`.

A failing characterization test means your change is wrong. Never edit the test.
Stop: comment on the issue describing the failing test, emit `emit_alert` with
`needs_attention: true`, and end your turn without opening a PR.

## Acceptance criteria

All checks run from the repo root; every one must hold:

- The six new modules exist at their exact paths:
  - `grep -c "^defmodule Aiur.GitHub.Issues do" src/lib/aiur/github/issues.ex` == 1
  - `grep -c "^defmodule Aiur.GitHub.Comments do" src/lib/aiur/github/comments.ex` == 1
  - `grep -c "^defmodule Aiur.GitHub.PullRequests do" src/lib/aiur/github/pull_requests.ex` == 1
  - `grep -c "^defmodule Aiur.GitHub.RepoEvents do" src/lib/aiur/github/repo_events.ex` == 1
  - `grep -c "^defmodule Aiur.GitHub.DependenciesApi do" src/lib/aiur/github/dependencies_api.ex` == 1
  - `grep -c "^defmodule Aiur.GitHub.Teams do" src/lib/aiur/github/teams.ex` == 1
- Each new lib file has a `@moduledoc`: `grep -c "@moduledoc" <file>` >= 1 for
  all six; `mix lint` / `mix credo --strict` (which runs `specs.check`) passes,
  proving a `@spec` on every public def.
- The moved concerns are gone from the facade (each moved definition deleted):
  - `grep -cE "defp (normalize_issue|extract_state|extract_priority|parse_priority_label|parse_priority_int|parse_datetime|do_list_issues|reduce_fetch_issue|fetch_issues_for_each_label|reduce_label_issues|do_fetch_issues_by_states|do_fetch_issue_states_by_ids|do_fetch_issues_by_id_list)\(" src/lib/aiur/github/client.ex` == 0
  - `grep -cE "defp (repo_comment_stream_query|fetch_repo_comment_stream|comment_query)\(" src/lib/aiur/github/client.ex` == 0
  - `grep -cE "defp (fetch_labeled_open_pull_requests|pull_request_has_label\?|open_pull_request_or_nil)\(" src/lib/aiur/github/client.ex` == 0
  - `grep -cE "defp (poll_interval|dependency_get|dependency_mutate|fetch_member_logins|member_login_list)\(" src/lib/aiur/github/client.ex` == 0
  - `grep -c "@dependencies_api_version" src/lib/aiur/github/client.ex` == 0
- Each moved **public** function that remains in the facade is a one-line
  wrapper, not a reimplementation: for each of `fetch_candidate_issues`,
  `fetch_issues_by_states`, `fetch_issue_states_by_ids`, `fetch_issue_raw`,
  `create_comment`, `fetch_recent_repo_review_comments`,
  `fetch_recent_repo_issue_comments`, `fetch_issue_comments`,
  `fetch_classified_issue_comments`, `fetch_pull_request_changed_paths`,
  `fetch_pull_request_review_comments`, `fetch_open_pull_request_for_branch`,
  `fetch_open_pull_requests_by_label`, `fetch_pull_request_head_ref`,
  `fetch_open_pull_request`, `fetch_classified_pr_review_comments`,
  `fetch_repo_events`, `fetch_blocked_by`, `fetch_blocking`, `add_dependency`,
  `remove_dependency`, `fetch_team_members` —
  `grep -A2 "def <name>(" src/lib/aiur/github/client.ex` shows the body is a
  single `do: Issues.…`/`Comments.…`/`PullRequests.…`/`RepoEvents.…`/
  `DependenciesApi.…`/`Teams.…` call (no multi-line logic). No `defdelegate` is
  used for these (default args must survive):
  `grep -cE "defdelegate (fetch_candidate_issues|create_comment|fetch_open_pull_request|fetch_repo_events|add_dependency|fetch_team_members)" src/lib/aiur/github/client.ex` == 0
- Parent file shrank: `wc -l < src/lib/aiur/github/client.ex` <= 1500. (Starting
  from ~2,597 pre-T-028; T-028 removes ~700 lines and this wave removes ~700
  more net of one-line wrappers. If T-028's actual reduction differs, the
  binding check is that the facade dropped by at least 600 lines versus its
  state at the tip of `v2` when this ticket started:
  `test $(( $(git show v2:src/lib/aiur/github/client.ex | wc -l) - $(wc -l < src/lib/aiur/github/client.ex) )) -ge 600`.)
- File-size budget: each new `.ex` module <= 200 lines
  (`for f in issues comments pull_requests repo_events dependencies_api teams;
  do test $(wc -l < src/lib/aiur/github/$f.ex) -le 200; done`; `pull_requests.ex`
  is the tightest at ~200 — if `@moduledoc`/`@spec`/aliases on the verbatim move
  push it to at most 220 that is acceptable, nothing exceeds 220). No NEW
  function (anything not moved verbatim) exceeds 20 logic lines; moved bodies are
  not rewritten to game any limit.
- Coverage is enforced for the new modules (none is coverage-exempt):
  `grep -cE "Aiur\.GitHub\.(Issues|Comments|PullRequests|RepoEvents|DependenciesApi|Teams)" src/mix.exs` == 0,
  and all six test files exist:
  `ls src/test/aiur/github/{issues,comments,pull_requests,repo_events,dependencies_api,teams}_test.exs`.
- No test file changed: `git diff --name-only origin/v2 -- src/test/` shows only
  the six newly added test files (all under `src/test/aiur/github/`), and zero
  modifications to any pre-existing test file.
- The full Agent gate below is green.

## Verification
### Agent gate (run all, from src/)
```
mix compile --warnings-as-errors
mix format --check-formatted
mix test
mix credo --strict
mix dialyzer
```
### At-merge (reviewer)

- `cd src && mix test --cover` — the 85% threshold passes with the six new
  modules counted (none in `ignore_modules`).
- Diff review: every hunk in `src/lib/aiur/github/client.ex` is a deletion, a
  one-line wrapper, or the alias line — zero logic edits. The six new lib files
  contain only moved bodies plus `@moduledoc`/`@spec`/aliases (and the moved
  `@dependencies_api_version` in `dependencies_api.ex`).
- FI-GH-022 Check: run `mix test test/aiur/github/client_events_test.exs`
  alone — the dependency calls still send `X-GitHub-Api-Version: 2026-03-10`
  while every other call uses `2022-11-28`, and labeled-PR pagination +
  repo-events etag/poll-interval are unchanged (this file pins RepoEvents,
  DependenciesApi, and PullRequests through the facade).
- FI-GH-040 spot-check: in `iex -S mix`, a `fetch_repo_events` call whose
  injected `request_fun` returns 304 yields `{:not_modified, etag,
  poll_interval}` and preserves the prior etag when the response omits the ETag
  header.
- FI-GH-002 spot-check: confirm (grep the six new modules) that Issues,
  `create_comment`, and DependenciesApi call `Transport.require_token/0` while
  RepoEvents / PullRequests / the comment streams call
  `Transport.require_token(opts)` — arities match the pre-move facade exactly.
- Confirm `git log --oneline` shows no commit touching
  `src/test/aiur/regression/`, and the tripwire CI check (T-005) is green.
- Fleet health: the phase-3 aiur run on `v2` stays healthy after merge — issue
  candidate fetch, comment polling, PR discovery, repo-events firehose, and
  dependency declaration all exercise the moved code on every tick.

## Executor rules (do not skip)
- Work only on your pre-created branch `aiur/<issue-number>`; the PR base is `v2`. PR description starts `Closes #<issue-number>`.
- Commits: 3-7 word imperative messages. Never mention AI, models, or tools in commits or the PR description.
- Behavior-preserving: no feature or API changes beyond the stated Scope.
- If completing this ticket seems to require editing any file not listed in Files, stop: comment the blocker on the issue instead of touching the file.
- If any test under `src/test/aiur/regression/` fails, your change is wrong. Never edit those tests. Comment on the issue, emit `emit_alert` with `needs_attention: true`, and end your turn without opening a PR.
- Never run `aiurdev --test` or `--test3`. Verification is the Agent gate above, only.
