# Decomposition proposal: `src/lib/aiur/github/client.ex` (2,597 lines)

Behavior-preserving split of `Aiur.GitHub.Client` for the aiur production-readiness refactor.
Repo root: `/home/orangekid/github/aiur`. House style: one source of truth per fact, pure policy
functions, single transport module, thin domain modules, one dependency direction
(domain → transport/errors, never back). Norm targets (≤20 logic lines/function, ≤200 lines/file,
≤2 nesting levels) applied with judgment.

**Load-bearing external contract (why the facade survives):**
`Aiur.GitHub.Tracker.client_module/0` resolves `Application.get_env(:aiur, :github_client_module, Client)`
and calls the Client function surface directly; `orchestrator.ex` does
`function_exported?(client, :verify_human_review_ready, 1)` and `preflight_auth/0` vs `/1` arity probes
(tracker.ex:39-40, orchestrator.ex:2780); test fakes (`orchestrator_deactivate_test.exs` fake client
modules) implement that same surface; `codex/dynamic_tool.ex` defaults to
`&GitHubClient.reply_to_review_thread/3` / `&GitHubClient.resolve_review_thread/2`. So
`Aiur.GitHub.Client` remains as a thin facade of explicit one-line wrappers (not `defdelegate`,
so default-arg arities like `preflight_auth/0` **and** `/1` stay exported), and every existing test
keeps passing unmodified through it during all waves.

---

## 1. Function / responsibility census

Line ranges from the current file. "≈LOC" counts the lines that will move for that concern
(including moduledoc-able comments and GraphQL heredocs).

### A. GraphQL documents for review threads (L12–117, ≈106 LOC)
- `@reply_review_thread_mutation` (12–28), `@resolve_review_thread_mutation` (30–39),
  `@unresolve_review_thread_mutation` (41–50), `@review_thread_query` (52–76),
  `@viewer_login_query` (78–84), `@unaddressed_review_threads_query` (86–117).

### B. Auth preflight & diagnostics (L119–149, 909–1059, 2461–2477 — ≈200 LOC)
- Public: `preflight_auth/1` (119–131), `format_auth_preflight_error/1` (143–149).
- Private: `finalize_preflight_result/2` (133–141), `preflight_checks/2` (909–918),
  `run_preflight_checks/5` (920–927), `run_preflight_check/5` (929–961), `auth_diagnostic/6`
  (963–973), `auth_failure_reason/2` (975–982), `enrich_auth_diagnostic/2` (984–990),
  `safe_gh_auth_status/1` (992–1002), `diagnostic_message/2` (1004–1019), `human_auth_reason/1`
  (1021–1045), `reset_suffix/1` (1047–1048), `human_gh_keyring_status/1` (1050–1059),
  `default_gh_auth_status_fun/0` (2461–2477).

### C. Error taxonomy & rate-limit signals (L151–272, 1061–1116, 1877–1881 — ≈190 LOC)
- Public: `@type classification` (151–157), `classify_error/1` (159–181).
- Private: `classify_transport/1` (183–188), `classify_transport_reason/1` (190–204),
  `classify_status/2` (206–231), `github_status_error/1` (233–239), `response_message/1` (241–242),
  `retry_after/1` (244–257), `rate_limit_poll_interval/1` (259–272), `rate_limited_response?/2`
  (1061–1066), `rate_limit_remaining/1` (1068–1084), `rate_limit_reset/1` (1086–1096),
  `rate_limit_body_remaining/1` (1098–1108), `rate_limit_message?/1` (1110–1116),
  `retryable_github_error?/1` (1877–1881).

### D. Issue fetch & normalization (L274–288, 413–431, 1118–1207, 2329–2388 — ≈200 LOC)
- Public: `fetch_candidate_issues/1` (274–277), `fetch_issues_by_states/2` (279–282),
  `fetch_issue_states_by_ids/2` (284–288), `fetch_issue_raw/2` (413–431).
- Private: `fetch_issues_for_each_label/6` (1118–1131), `reduce_label_issues/7` (1133–1142),
  `do_fetch_issues_by_states/2` (1144–1153), `do_fetch_issue_states_by_ids/2` (1155–1163),
  `do_list_issues/6` (1165–1178), `do_fetch_issues_by_id_list/6` (1180–1191), `reduce_fetch_issue/7`
  (1193–1207), `normalize_issue/4` (2329–2349), `extract_state/3` (2351–2361), `extract_priority/1`
  (2363–2365), `parse_priority_label/1` (2367–2372), `parse_priority_int/1` (2374–2379),
  `parse_datetime/1` (2381–2388).

### E. Comments (issue comments + repo-wide comment streams) (L290–310, 611–685, 829–846, 1222–1226 — ≈140 LOC)
- Public: `create_comment/3` (290–310), `fetch_recent_repo_review_comments/1` (597–621),
  `fetch_recent_repo_issue_comments/1` (623–644), `fetch_issue_comments/2` (671–685),
  `fetch_classified_issue_comments/2` (829–846).
- Private: `repo_comment_stream_query/1` (646–650), `fetch_repo_comment_stream/4` (652–669),
  `comment_query/1` (1222–1226).

### F. Repo events firehose (L312–370, 2585–2596 — ≈85 LOC)
- Public: `fetch_repo_events/1` (312–370) — etag/If-None-Match, 304 handling, poll-interval headers.
- Private: `poll_interval/1` (2585–2596, default 60s).

### G. Issue dependencies REST (L372–411, 2495–2559 — ≈110 LOC)
- Public: `fetch_blocked_by/2` (372–380), `fetch_blocking/2` (382–389), `add_dependency/3` (391–404),
  `remove_dependency/3` (406–411).
- Private: `@dependencies_api_version "2026-03-10"` (2503), `dependency_get/3` (2505–2529),
  `dependency_mutate/4` (2531–2559). Note the distinct API-version header requirement (comment
  2495–2502).

### H. Org teams (L433–468 — ≈40 LOC)
- Public: `fetch_team_members/3` (440–448) — consumed by `Aiur.GitHub.CodeOwners` (code_owners.ex:296).
- Private: `fetch_member_logins/4` (450–465), `member_login_list/1` (467–468).

### I. Pull requests REST (L484–595, 687–766 — ≈200 LOC)
- Public: `fetch_pull_request_changed_paths/2` (484–500), `fetch_pull_request_review_comments/2`
  (502–513), `fetch_open_pull_request_for_branch/2` (515–541), `fetch_open_pull_requests_by_label/2`
  (543–564), `fetch_pull_request_head_ref/2` (687–715), `fetch_open_pull_request/2` (717–749),
  `fetch_classified_pr_review_comments/2` (758–766).
- Private: `fetch_labeled_open_pull_requests/5` (566–585), `pull_request_has_label?/2` (587–595),
  `open_pull_request_or_nil/1` (751–756).

### J. Review threads — GraphQL fetch, reply, resolve, verification (L768–811, 1231–2055 — ≈880 LOC; the giant)
- Public: `fetch_unaddressed_pr_review_thread_comments/2` (768–787), `reply_to_review_thread/3`
  (789–800), `resolve_review_thread/2` (802–811).
- Fetch/paginate/classify: `normalize_pr_number/1` (1231–1240),
  `fetch_unaddressed_review_thread_pages/8` (1242–1276), `continue_unaddressed_review_thread_pages/8`
  (1278–1302), `review_threads_page/1` (1943–1952), `unaddressed_thread_comments/2` (1954–1957),
  `unaddressed_thread_comment/2` (1959–1978), `thread_comments/1` (1980–1985),
  `classify_thread_comment/3` (1987–1994), `normalize_thread_comment/2` (1996–2010),
  `thread_ownership_context/2` (2030–2034), `unresolved_agent_review_thread_reply?/2` (2036–2040),
  `mark_review_thread_resolution_required/1` (2051–2055), `fetch_review_thread/3` (1760–1762),
  `review_thread_from_body/1` (1806–1811), `normalize_verified_thread_comment/1` (1813–1823).
- Reply + retry/verify loop: `do_reply_to_review_thread/7` (1304–1339), `retry_review_thread_reply/3`
  (1341–1356), `verify_after_review_thread_reply/2` (1358–1379),
  `build_review_thread_retry_context/7` (1381–1399), `add_review_thread_reply/4` (1401–1406),
  `verify_review_thread_reply/5` (1741–1758), `verify_latest_review_thread_comment/6` (1764–1786),
  `latest_comment_author_mismatch/2` (1788–1795), `latest_comment_body_mismatch/2` (1797–1804),
  `retryable_review_thread_verification_error?/1` (1862–1875), `sleep_review_thread_retry/2`
  (1883–1887), `normalize_review_thread_id/1` (1889–1896), `normalize_review_thread_reply_body/1`
  (1898–1905), `normalize_positive_integer/2` (1917–1918), `normalize_non_negative_integer/2`
  (1920–1923).
- Resolve/unresolve + pre/post verification (the #682 TOCTOU machinery):
  `do_resolve_review_thread/5` (1408–1435), `verify_review_thread_after_resolution/6` (1437–1454),
  `resolve_review_thread_mutation/3` (1456–1464),
  `unresolve_review_thread_after_post_resolution_failure/4` (1466–1482),
  `unresolve_review_thread_mutation/3` (1484–1492), `verify_resolved_review_thread/3` (1494–1513),
  `verify_unresolved_review_thread/2` (1515–1532), `classify_review_thread_resolution_errors/2`
  (1534–1546), `review_thread_resolution_permission_error?/1` (1548–1554),
  `typed_permission_error?/1` (1556–1559), `known_pat_permission_message?/1` (1561–1564),
  `verify_review_thread_resolution_ready/5` (1566–1583),
  `verify_review_thread_resolution_still_latest/5` (1585–1612),
  `verify_review_thread_resolution_latest_reply/7-8` (1614–1681), `resolution_reason/2` (1683–1690),
  `add_unresolve_verification/2` (1692–1698), `add_unresolve_failure/2` (1700–1706),
  `resolution_precondition_failed/3` (1708–1713), `review_thread_authoritative_comment?/2`
  (1715–1735), `normalize_thread_for_comment_context/1` (1737–1739),
  `normalize_review_thread_terminal_reply_body/1` (1907–1915).
- Bot/agent identity: `review_thread_bot_account/3` (1825–1835), `fetch_authenticated_viewer_login/2`
  (1837–1851), `normalize_optional_binary/1` (1853–1860), `codeowners_classification_opts/1`
  (2012–2028), `agent_login?/2` (2042–2049).

### K. Label-encoded issue state machine + human-review gate (L813–905, 2057–2327 — ≈360 LOC)
- Public: `verify_human_review_ready/2` (813–827), `update_issue_state/3` (848–870), `add_label/3`
  (872–886), `remove_label/3` (888–905).
- State transition machinery: `do_update_issue_state/2` (2057–2074), `apply_issue_state_update/4`
  (2076–2092), `remove_active_state_labels/7` (2151–2171), `swap_and_maybe_close_issue/4`
  (2173–2183), `swap_labels/4` (2185–2198), `add_state_label/3` (2200–2213), `add_active_issue_label/2`
  (2215–2245), `remove_state_labels/7` (2247–2258), `delete_issue_label/6` (2260–2273),
  `add_issue_label/6` (2275–2288), `maybe_close_issue/4` (2290–2310), `closed_issue?/1` (2312–2313).
- Human-review readiness gate: `verify_human_review_review_threads_clear/2` (2094–2100),
  `verify_issue_review_threads_clear/1` (2102–2122), `verify_pr_review_threads_clear/3` (2124–2147).
- Pure state policy: `human_review_target_state?/1` (2149), `active_target_state?/1` (2315–2317),
  `terminal_state_label?/2` (2319–2323), `terminal_state_name?/1` (2325–2327), `normalize_state/1`
  (2390–2395).

### L. Transport core (L2397–2459, 2479–2493, 2561–2583, 1209–1229, 1925–1941, 470–482 — ≈180 LOC)
- `parse_repo/0` (2397–2408), `require_token/0` (2410–2415), `require_token/1` (2417–2429 — opts
  token → `"test-gh-token"` when `request_fun` injected → config fallback),
  `default_request_fun/1` × 4 method clauses (2431–2459, Req with 30s connect timeout, etag header
  injection on GET), `github_headers/2` (2479–2493, `api_version` override vs default `2022-11-28`),
  `github_graphql/4` (1925–1941, GraphQL POST + `{:github_graphql_errors, errors}` extraction),
  `fetch_json_list/3` (1209–1220), `header/2` list + map clauses (2561–2583),
  `parse_next_page_url/1` (470–482, `Link rel="next"` pagination), `maybe_put_query/3` (1228–1229),
  `@base_url` / `@graphql_url` (9–10).

---

## 2. Proposed module split (NAME MAP — the downstream contract)

All new files under `src/lib/aiur/github/`. Dependency direction is strictly downward:
facade → domain modules → (`BotIdentity` | `StatePolicy`) → (`Transport` | `Errors`) → `Aiur.GitHub.Config`.
`Aiur.Codeowners` (existing top-level policy module) is a sideways dependency of Comments,
PullRequests and ReviewThreads, unchanged. Nothing inside `Aiur.GitHub.*` calls back into the facade.

| # | Module | File | Responsibility (one sentence) | ≈LOC | Key functions that move |
|---|--------|------|-------------------------------|-----:|-------------------------|
| 1 | `Aiur.GitHub.Transport` | `src/lib/aiur/github/transport.ex` | The single HTTP/GraphQL transport: default `request_fun`, headers/API-version, GraphQL POST, JSON-list GET, `Link rel=next` pagination, header lookup, and repo/token resolution from config or opts. | 180 | `default_request_fun/1`, `github_headers/2`, `github_graphql/4`, `fetch_json_list/3`, `header/2`, `parse_next_page_url/1`, `maybe_put_query/3`, `parse_repo/0`, `require_token/0`, `require_token/1`, `base_url/0`, `graphql_url/0` |
| 2 | `Aiur.GitHub.Errors` | `src/lib/aiur/github/errors.ex` | Pure error taxonomy: classify transport failures and HTTP responses into `{:github, classification, detail}`, rate-limit signal detection, and retryability predicates. | 190 | `classify_error/1`, `@type classification`, `classify_transport*`, `classify_status/2`, `github_status_error/1`, `rate_limited_response?/2`, `retry_after/1`, `rate_limit_poll_interval/1`, `rate_limit_remaining/1`, `rate_limit_reset/1`, `rate_limit_body_remaining/1`, `rate_limit_message?/1`, `retryable_github_error?/1` |
| 3 | `Aiur.GitHub.AuthPreflight` | `src/lib/aiur/github/auth_preflight.ex` | Startup auth preflight (rate_limit/repo/issues probes) and operator-facing diagnostic message construction, including `gh` keyring status enrichment. | 200 | `preflight_auth/1`, `format_auth_preflight_error/1`, `preflight_checks/2`, `run_preflight_check(s)/…`, `auth_diagnostic/6`, `auth_failure_reason/2`, `enrich_auth_diagnostic/2`, `diagnostic_message/2`, `human_auth_reason/1`, `human_gh_keyring_status/1`, `safe_gh_auth_status/1`, `default_gh_auth_status_fun/0` |
| 4 | `Aiur.GitHub.StatePolicy` | `src/lib/aiur/github/state_policy.ex` | Pure policy for label-encoded issue states: name normalization, `prefix:state` label construction, and terminal/active/human-review predicates. | 55 | `normalize_state/1`, `state_label/2` (extracted from the two inline `"#{prefix}:#{normalize_state(...)}"` sites), `terminal_state_name?/1`, `terminal_state_label?/2`, `active_target_state?/1`, `human_review_target_state?/1` |
| 5 | `Aiur.GitHub.Issues` | `src/lib/aiur/github/issues.ex` | Issue fetching by state labels / by ids / raw, plus normalization of GitHub issue JSON into `%Aiur.Issue{}`. | 190 | `fetch_candidate_issues/1`, `fetch_issues_by_states/2`, `fetch_issue_states_by_ids/2`, `fetch_issue_raw/2`, `fetch_issues_for_each_label/6`, `do_list_issues/6`, `reduce_fetch_issue/7`, `normalize_issue/4`, `extract_state/3`, `extract_priority/1`, `parse_datetime/1` |
| 6 | `Aiur.GitHub.Comments` | `src/lib/aiur/github/comments.ex` | Issue-conversation comment creation and fetching, CODEOWNERS-classified issue comments, and the repo-wide review/issue comment streams with `since` cursor + Link pagination. | 145 | `create_comment/3`, `fetch_issue_comments/2`, `fetch_classified_issue_comments/2`, `fetch_recent_repo_review_comments/1`, `fetch_recent_repo_issue_comments/1`, `repo_comment_stream_query/1`, `fetch_repo_comment_stream/4`, `comment_query/1` |
| 7 | `Aiur.GitHub.PullRequests` | `src/lib/aiur/github/pull_requests.ex` | Pull-request REST reads: by branch, by label (paginated), by number with open/closed routing, head ref, changed paths, and classified PR review comments. | 200 | `fetch_open_pull_request/2`, `open_pull_request_or_nil/1`, `fetch_open_pull_request_for_branch/2`, `fetch_open_pull_requests_by_label/2`, `fetch_labeled_open_pull_requests/5`, `pull_request_has_label?/2`, `fetch_pull_request_head_ref/2`, `fetch_pull_request_changed_paths/2`, `fetch_pull_request_review_comments/2`, `fetch_classified_pr_review_comments/2` |
| 8 | `Aiur.GitHub.RepoEvents` | `src/lib/aiur/github/repo_events.ex` | The `/repos/{o}/{r}/events` firehose fetch with ETag conditional GETs, 304 handling, and X-Poll-Interval scheduling. | 85 | `fetch_repo_events/1`, `poll_interval/1` |
| 9 | `Aiur.GitHub.DependenciesApi` | `src/lib/aiur/github/dependencies_api.ex` | Raw Issue Dependencies REST endpoints (blocked_by/blocking get, add/remove) under the `2026-03-10` API version; graph policy stays in the existing `Aiur.GitHub.IssueDependencies`. | 115 | `fetch_blocked_by/2`, `fetch_blocking/2`, `add_dependency/3`, `remove_dependency/3`, `dependency_get/3`, `dependency_mutate/4`, `@dependencies_api_version` |
| 10 | `Aiur.GitHub.Teams` | `src/lib/aiur/github/teams.ex` | Org team membership listing (paginated) for CODEOWNERS `@org/team` expansion. | 45 | `fetch_team_members/3`, `fetch_member_logins/4`, `member_login_list/1` |
| 11 | `Aiur.GitHub.BotIdentity` | `src/lib/aiur/github/bot_identity.ex` | One source of truth for "who is the agent": configured bot account with GraphQL viewer-login fallback, and agent-login set construction for CODEOWNERS classification. | 90 | `review_thread_bot_account/3` (as `bot_account/3`), `fetch_authenticated_viewer_login/2`, `@viewer_login_query`, `normalize_optional_binary/1`, `codeowners_classification_opts/1`, `agent_login?/2` |
| 12 | `Aiur.GitHub.ReviewThreads` | `src/lib/aiur/github/review_threads.ex` | Review-thread reads: paginated unaddressed-thread GraphQL fetch, thread/comment normalization, CODEOWNERS classification, and the resolution-required marking for unresolved agent replies. | 250 | `fetch_unaddressed_pr_review_thread_comments/2`, `normalize_pr_number/1`, `fetch_unaddressed_review_thread_pages/8`, `review_threads_page/1`, `unaddressed_thread_comment(s)/2`, `thread_comments/1`, `classify_thread_comment/3`, `normalize_thread_comment/2`, `thread_ownership_context/2`, `mark_review_thread_resolution_required/1`, `fetch_review_thread/3`, `review_thread_from_body/1`, `normalize_verified_thread_comment/1`, `@unaddressed_review_threads_query`, `@review_thread_query` |
| 13 | `Aiur.GitHub.ReviewThreads.Reply` | `src/lib/aiur/github/review_threads/reply.ex` | Reply mutation with mutation-once/verify-with-retry semantics: post reply, then verify the latest thread comment is the bot's exact body, retrying only verification. | 230 | `reply_to_review_thread/3` impl, `do_reply_to_review_thread/7`, `verify_after_review_thread_reply/2`, `retry_review_thread_reply/3`, `build_review_thread_retry_context/7`, `add_review_thread_reply/4`, `verify_review_thread_reply/5`, `verify_latest_review_thread_comment/6`, mismatch helpers, `retryable_review_thread_verification_error?/1`, `sleep_review_thread_retry/2`, `normalize_review_thread_id/1`, `normalize_review_thread_reply_body/1`, `normalize_positive_integer/2`, `normalize_non_negative_integer/2`, `@reply_review_thread_mutation` |
| 14 | `Aiur.GitHub.ReviewThreads.Resolution` | `src/lib/aiur/github/review_threads/resolution.ex` | Resolve/unresolve mutations with the pre-verify → resolve → post-verify → unresolve-on-mismatch (TOCTOU) orchestration and permission-error classification. | 190 | `resolve_review_thread/2` impl, `do_resolve_review_thread/5`, `verify_review_thread_after_resolution/6`, `resolve_review_thread_mutation/3`, `unresolve_review_thread_mutation/3`, `unresolve_review_thread_after_post_resolution_failure/4`, `verify_resolved_review_thread/3`, `verify_unresolved_review_thread/2`, `classify_review_thread_resolution_errors/2`, `review_thread_resolution_permission_error?/1`, `add_unresolve_verification/2`, `add_unresolve_failure/2`, `normalize_review_thread_terminal_reply_body/1`, `@resolve_review_thread_mutation`, `@unresolve_review_thread_mutation` |
| 15 | `Aiur.GitHub.ReviewThreads.ResolutionPolicy` | `src/lib/aiur/github/review_threads/resolution_policy.ex` | Pure verification policy over a fetched thread body: latest-reply author/body preconditions (before/after resolve phases) and the CODEOWNERS authoritative-comment boundary. | 150 | `verify_review_thread_resolution_ready/5`, `verify_review_thread_resolution_still_latest/5`, `verify_review_thread_resolution_latest_reply/7-8`, `resolution_reason/2`, `resolution_precondition_failed/3`, `review_thread_authoritative_comment?/2`, `normalize_thread_for_comment_context/1` |
| 16 | `Aiur.GitHub.HumanReviewGate` | `src/lib/aiur/github/human_review_gate.ex` | The human-review readiness gate: block the human-review transition while the ticket's open PR has unaddressed/unresolved review threads. | 85 | `verify_human_review_ready/2`, `verify_human_review_review_threads_clear/2`, `verify_issue_review_threads_clear/1`, `verify_pr_review_threads_clear/3` |
| 17 | `Aiur.GitHub.IssueState` | `src/lib/aiur/github/issue_state.ex` | Label-encoded issue lifecycle writes: state-label swap with closed-issue re-check, terminal-state close, and raw per-issue label add/remove (idempotent delete). | 230 | `update_issue_state/3`, `add_label/3`, `remove_label/3`, `do_update_issue_state/2`, `apply_issue_state_update/4`, `swap_labels/4`, `swap_and_maybe_close_issue/4`, `add_state_label/3`, `add_active_issue_label/2`, `remove_state_labels/7`, `remove_active_state_labels/7`, `delete_issue_label/6`, `add_issue_label/6`, `maybe_close_issue/4`, `closed_issue?/1` |
| — | `Aiur.GitHub.Client` (retained) | `src/lib/aiur/github/client.ex` | Facade preserving the exact current public surface (the `:github_client_module` behaviour contract): one-line wrappers with original default args, delegating to the domain modules. | 130 | wrappers for all 27 current public functions + `@type classification` re-export via `Errors` |

Sum of new-module LOC ≈ 2,570 + 130 facade ≈ current file plus per-module moduledocs — consistent
with a verbatim move. Files over the 200-line target (`ReviewThreads` 250, `Reply` 230,
`IssueState` 230) are judged cohesive single concerns; splitting them further would cut a retry loop
or a state machine mid-invariant. Naming notes: `DependenciesApi` avoids colliding with the existing
policy module `Aiur.GitHub.IssueDependencies`; `IssueState` (writes) vs `StatePolicy` (pure
predicates) keeps one source of truth for terminal/active/normalize facts; the existing
`Aiur.GitHub.Labels` (label *definitions* seeding for `aiur init`) is untouched and distinct from
`IssueState`'s per-issue label attach/detach.

---

## 3. Extraction sequencing (waves; strictly serialized on this file)

Every wave: move code verbatim into the new module(s), make the moved helpers public (`@doc false`
where they were private), replace the moved bodies in `client.ex` with one-line wrappers keeping the
original names/arities/default args, run `mix compile --warnings-as-errors` + full test suite
(github_client_test.exs, github/client_events_test.exs, github_auth_preflight_test.exs and the
orchestrator/poller suites all exercise the facade, so they pass unmodified). No wave moves tests.
Each wave is one reviewable ticket, ≤400 lines moved.

- **Wave 1 — foundations: `Transport` + `Errors` (~370 lines moved).** No other module can move
  before these exist. `classify_error/1` and the `classification` type stay publicly reachable via
  the Client wrapper. Everything left in client.ex switches its internal calls to
  `Transport.*`/`Errors.*`.
- **Wave 2 — `AuthPreflight` + `StatePolicy` (~255 lines).** Depends only on Wave 1.
  `preflight_auth/0|1` and `format_auth_preflight_error/1` wrappers keep the
  `function_exported?` probes in `Tracker.auth_preflight/0` working. Remaining client.ex code
  switches `normalize_state`/terminal predicates to `StatePolicy`.
- **Wave 3 — `Issues` + `DependenciesApi` + `Teams` (~345 lines).** Pure REST domains with no
  review-thread entanglement. `Aiur.GitHub.IssueDependencies` and `Aiur.GitHub.CodeOwners` keep
  calling through the facade (no caller edits this wave).
- **Wave 4 — `RepoEvents` + `Comments` + `PullRequests` (~400 lines).** Completes the REST surface.
  `fetch_classified_*` keep their `Aiur.Codeowners` calls verbatim. `client_events_test.exs`
  (events, dependencies, labeled-PR pagination) pins this wave through the facade.
- **Wave 5 — `BotIdentity` + `ReviewThreads` core (~370 lines).** Moves the GraphQL read path,
  thread classification, and agent-identity resolution. `fetch_unaddressed_pr_review_thread_comments/2`
  becomes a wrapper. The reply/resolve loops still live in client.ex this wave and call
  `ReviewThreads.fetch_review_thread/3` + `BotIdentity.*`.
- **Wave 6 — `ReviewThreads.Reply` (~240 lines).** Moves the mutation-once/verify-retry loop intact
  (including `sleep_fun`/`attempts`/`retry_delay_ms` opts handling). `dynamic_tool.ex`'s
  `&GitHubClient.reply_to_review_thread/3` default keeps resolving to the wrapper.
- **Wave 7 — `ReviewThreads.Resolution` + `ReviewThreads.ResolutionPolicy` (~350 lines).** Moves the
  TOCTOU pre/post-verify + unresolve-compensation machinery and its pure policy; error-tuple shapes
  preserved byte-for-byte (tests assert on them).
- **Wave 8 — `IssueState` + `HumanReviewGate` (~360 lines).** Last, because it composes
  `PullRequests`, `ReviewThreads`, `BotIdentity`, and `StatePolicy`. After this wave client.ex is a
  ~130-line facade and the original 2,597-line body is gone.
- **Wave 9 (optional, not serialized on client.ex; parallel per-caller tickets).** Migrate direct
  callers (`orchestrator.ex`, `events/github_firehose.ex`, `events/github_comments_poller.ex`,
  `codex/dynamic_tool.ex`, `github/issue_dependencies.ex`, `github/code_owners.ex`) to the domain
  modules. The facade itself must remain indefinitely as the `:github_client_module` contract
  surface unless that config seam is redesigned in a separate ticket.

---

## 4. Risks — semantics that must be preserved verbatim

This file sits inside hotspot #1 of `docs/refactor/research-history-hotspots.md` ("GitHub event
ingestion & comment→wake/rework pipeline", ~35 incidents), and that doc's characterization list item
3 names exactly this file: "`active_states` honoring, review-thread reply/resolve/verify flows,
error taxonomy (transient vs terminal), token resolution order."

1. **Facade/behaviour contract.** `Application.get_env(:aiur, :github_client_module, Client)`
   (tracker.ex:101) plus `function_exported?` arity probes (tracker.ex:39–40,
   orchestrator.ex:2780) mean the wrappers must preserve every public name, arity **including
   default-arg zero/one-arity variants**, and return shape. Use explicit wrapper functions, not
   `defdelegate`, so default args survive.
2. **Token resolution order (regression chain PR #559 → #579 → #582).** `require_token/0`
   (config-only) vs `require_token/1` (opts `:token` → literal `"test-gh-token"` when a
   `request_fun` is injected → config). Which public function uses which arity is behaviorally
   significant (e.g. `create_comment`, `update_issue_state`, `add/remove_label`, issue fetches,
   dependencies use `/0`; events, PR fetches, comments streams, review threads use `/1`). Do NOT
   unify them; move both to `Transport` and keep per-domain call sites byte-identical. The
   persistent_term token cache (`{Aiur.GitHub.Config, :resolved_token}`) that tests reset is in
   `Config`, untouched.
3. **Error taxonomy is a cross-module wire format.** `{:github, classification, detail}` vs
   `{:github_api_status, status}`: `github_status_error/1` escalates to the taxonomy **only** when
   rate-limited (PR #683: GraphQL `RATE_LIMITED` misclassified as a rework trigger);
   `Aiur.GitHub.Connectivity` backoff keys off these classifications; `retryable_github_error?/1`
   and `retryable_review_thread_verification_error?/1` gate retry loops. Any change to which
   endpoint returns which shape is a behavior change.
4. **Resolve TOCTOU compensation (PR #682, #679).** Order is sacred: fetch+pre-verify ("is my
   terminal reply still the latest bot comment, thread unresolved, reviewer authoritative") →
   resolve mutation → **post**-verify still-latest → on mismatch, unresolve and return the enriched
   error (`add_unresolve_verification`/`add_unresolve_failure`). Tests at
   github_client_test.exs:916–1231 assert the exact tuples
   (`:review_thread_resolution_precondition_failed`, `:post_resolve_latest_comment_*`,
   `:review_thread_resolution_not_permitted` with the token-guidance string).
5. **Reply is mutation-once, verify-with-retry.** After a successful mutation, only verification
   retries (linear backoff `retry_delay_ms * attempt` via injectable `sleep_fun`); a retry must
   never re-post the reply (test "retries verification without posting duplicate replies",
   github_client_test.exs:779). Transport-level failures of the mutation itself retry up to
   `attempts` (default 3).
6. **Guard/filter semantics (hotspot theme #10: every skip/cap clipped a legit case once).**
   `unaddressed_thread_comment/2` only surfaces unresolved threads whose latest comment is
   authoritative, but unresolved **agent** replies are re-surfaced with
   `"review_thread_resolution_required" => true` (feeds the poller rework loop — PR #677 seam);
   `open_pull_request_or_nil/1` maps closed/merged→nil (legacy-path routing);
   `fetch_open_pull_request/2` maps 404→`{:ok, nil}` not error; label pagination follows
   `Link rel=next` so page-2 watched PRs aren't dropped; `fetch_repo_events` preserves the prior
   etag when GitHub omits the header on 200 (caching-proxy note at L356–361); `remove_label` and
   `delete_issue_label` treat 404 as success (idempotency) while `add_issue_label` accepts only
   200/201 and `add_label` accepts 200..299 — keep the two add variants distinct.
7. **State-machine double-read.** `add_active_issue_label/2` re-GETs the issue between removing old
   labels and adding the new active label, and removes-instead-of-adds if the issue closed in that
   window (test "active label add rechecks issue state after stale label removal",
   github_client_test.exs:1541). This is a deliberate race guard; do not "simplify" the second GET
   away.
8. **Timing/process semantics.** The only sleep is `sleep_review_thread_retry/2` (injectable);
   there is no GenServer/ETS state in this file — all state lives in the caller's opts, so the
   decomposition is process-safe. Preserve `Logger` messages verbatim where operators grep them
   (`"GitHub review thread ... mutation response"`, `"GitHub API request failed status="`), and the
   `connect_options: [timeout: 30_000]` on every Req call.
9. **`preflight_auth` diagnostics.** Never log/return token material (test at
   github_client_test.exs:221); check order rate_limit → repository → issues halts on first failure;
   `default_gh_auth_status_fun/0` shells out to `gh auth status` with `GITHUB_TOKEN` env removed.

**Existing pinning tests** (all through the facade; keep green every wave):
`src/test/aiur/github_client_test.exs` (1,774 lines: issues/preflight/comments/PRs/review-thread
reply+resolve/update_issue_state/human-review gate/taxonomy),
`src/test/aiur/github/client_events_test.exs` (212 lines: repo events etag/poll-interval,
dependencies API version header, labeled-PR pagination),
`src/test/aiur/github_auth_preflight_test.exs` (orchestrator halts on preflight failure; formatter
fallback), plus indirect pins via `orchestrator_deactivate_test.exs` (fake `:github_client_module`
modules), `code_owners_test.exs` (`fetch_team_members`), and the events-poller/firehose suites.

**Missing characterization coverage (add before the wave that moves the code):**
- `fetch_recent_repo_review_comments/1` and `fetch_recent_repo_issue_comments/1` — the repo-wide
  comment streams (since-cursor query shape, Link pagination, taxonomy on failure) have **no direct
  tests**; they are the wake-pipeline entry points (PR #668→#673→#675 regression seam). Add before
  Wave 4.
- `require_token/1` opts/`"test-gh-token"`/config precedence — untested directly; pin before Wave 1.
- `fetch_issue_comments/2`, `fetch_pull_request_review_comments/2`, `fetch_pull_request_changed_paths/2`,
  `fetch_issue_raw/2` — only exercised indirectly; cheap direct pins before Waves 3–4.
- `header/2` map-headers clause and `poll_interval/1` non-integer fallback — trivial pure pins
  before Wave 1.
- `verify_human_review_ready/2` non-PR (`{:ok, nil}`) and PR-without-number branches — partially
  covered at github_client_test.exs:1305–1499; add the `{:ok, nil}` branch pin before Wave 8.

Test-isolation caution (hotspot #2): github_client_test.exs mutates `GITHUB_TOKEN` env and the
persistent_term token cache in `setup`; keeping all characterization tests pointed at the facade
(not the new modules) during the waves avoids duplicating that global-state handling and the
associated flake class.
