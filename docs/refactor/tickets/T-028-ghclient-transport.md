# T-028: github client wave 1: Transport, Errors, AuthPreflight, StatePolicy, BotIdentity

**Phase:** 3
**Depends-on:** None
**Labels:** `agent:todo` `refactor` `phase:3` `complexity:3`

## Problem / context

`src/lib/aiur/github/client.ex` is a 2,597-line god module (`Aiur.GitHub.Client`)
that mixes a single HTTP/GraphQL transport, the error taxonomy, startup auth
preflight, the label-encoded issue-state policy, bot-identity resolution, and a
dozen REST/GraphQL domains. It sits inside hotspot #1 of
`docs/refactor/research-history-hotspots.md` ("GitHub event ingestion &
comment→wake/rework pipeline", ~35 incidents) and its behaviors are named
verbatim in that doc's characterization list item 3: "error taxonomy (transient
vs terminal), token resolution order." The full decomposition plan and the
binding module name-map are in `docs/refactor/research-arch/giant-client.md`.

This ticket is **Wave 1 of 3** for that file. It extracts the five foundational
modules every other domain module will depend on — `Aiur.GitHub.Transport`,
`Aiur.GitHub.Errors`, `Aiur.GitHub.AuthPreflight`, `Aiur.GitHub.StatePolicy`,
`Aiur.GitHub.BotIdentity` — by **moving code verbatim** out of `client.ex` and
leaving `client.ex` as a facade that delegates. No other `github/client.ex`
domain module (Issues, Comments, PullRequests, ReviewThreads, IssueState, …) is
touched here; those are Waves 2–3 (T-029, T-030). Public function signatures and
observable behavior must be unchanged: `Aiur.GitHub.Tracker` resolves the client
via `Application.get_env(:aiur, :github_client_module, Client)` and calls its
function surface directly, and `orchestrator.ex` probes arities with
`function_exported?`, so the facade contract is load-bearing
(`giant-client.md` §risk 1).

## Scope (exact)

Work strictly top-down: create the new module, **cut** the named code out of
`client.ex` and **paste it verbatim** (bodies unchanged), make the moved helpers
`public` functions on the new module (they are called from code that remains in
`client.ex` this wave), add `@moduledoc` + `@spec` on every public def, then
replace each moved call site inside `client.ex` with a module-qualified call
(`Transport.foo(...)`, `Errors.foo(...)`, etc.). Do **not** rewrite logic, rename
functions except where explicitly stated, or change any tuple/return shape.

All new files live under `src/lib/aiur/github/`. Add `alias Aiur.GitHub.{Transport,
Errors, AuthPreflight, StatePolicy, BotIdentity}` (plus existing aliases) to
`client.ex` so the qualified calls stay short.

### 1. `Aiur.GitHub.Transport` — `src/lib/aiur/github/transport.ex`

Move these, verbatim, and make each a **public** function:

- `@base_url` (client.ex:9) and `@graphql_url` (client.ex:10) → expose as
  `base_url/0` and `graphql_url/0` (module attributes may stay private inside
  Transport; other modules that need the URLs call `Transport.base_url/0` /
  `Transport.graphql_url/0`).
- `parse_repo/0` (2397-2408), `require_token/0` (2410-2415), `require_token/1`
  (2417-2429) — **keep both arities distinct and byte-identical**; the `/1`
  variant's `opts[:token] → "test-gh-token" (when :request_fun present) → config`
  order is the #559→#579→#582 regression chain (`giant-client.md` §risk 2).
- `default_request_fun/1` — all four method clauses (2431-2459), including the
  `connect_options: [timeout: 30_000]` on every clause and the `If-None-Match`
  etag injection on the `:get` clause.
- `github_headers/2` — both clauses (2479-2493): the `api_version` override and
  the default `"2022-11-28"`.
- `github_graphql/4` (1925-1941) — the GraphQL POST with the
  `{:error, {:github_graphql_errors, errors}}` extraction on a 200 body
  containing `"errors"`. Its non-200 branch calls `github_status_error/1`, which
  moves to `Errors`; change that call to `Errors.github_status_error/1`. Its
  transport-error branch calls `classify_error/1`; change to
  `Errors.classify_error/1`.
- `fetch_json_list/3` (1209-1220), `parse_next_page_url/1` (470-482,
  `Link rel="next"` pagination), `maybe_put_query/3` (1228-1229).
- `header/2` — **both** the list clause and the map clause (2561-2583).
- `poll_interval/1` (2585-2596, default 60).

Note: `Errors` (below) calls `Transport.header/2`, and `Transport.github_graphql/4`
calls `Errors.github_status_error/1`. These mutual **runtime** references are
fine in Elixir (no compile cycle). Keep `header/2` in `Transport` per the name
map; do not duplicate it.

### 2. `Aiur.GitHub.Errors` — `src/lib/aiur/github/errors.ex`

Move verbatim and make public:

- `@type classification` (151-157) and its `@typedoc` → declare in `Errors` and
  re-export the type from the facade (see step 6).
- `classify_error/1` — both clauses (159-181, currently the only **public**
  function in this group).
- `classify_transport/1` (183-188), `classify_transport_reason/1` (190-204),
  `classify_status/2` (206-231), `github_status_error/1` (233-239),
  `response_message/1` (241-242), `retry_after/1` (244-257),
  `rate_limit_poll_interval/1` (259-272).
- `rate_limited_response?/2` (1061-1066), `rate_limit_remaining/1` (1068-1084),
  `rate_limit_reset/1` (1086-1096), `rate_limit_body_remaining/1` (1098-1108),
  `rate_limit_message?/1` (1110-1116).
- `retryable_github_error?/1` (1877-1881).
- The rate-limit helpers call `header/2`; change those to `Transport.header/2`.
- Preserve the exact classification atoms (`:dns | :timeout | :tls | :transport |
  :auth | :rate_limited | :http`) and the `{:github, class, detail}` vs
  `{:github_api_status, status}` split byte-for-byte — `Aiur.GitHub.Connectivity`
  keys off these (`giant-client.md` §risk 3; FI-GH-010).

### 3. `Aiur.GitHub.AuthPreflight` — `src/lib/aiur/github/auth_preflight.ex`

Move verbatim and make public:

- Public: `preflight_auth/1` (119-131, has a default arg so it exports **both**
  `/0` and `/1` — preserve that), `format_auth_preflight_error/1` (143-149, both
  clauses).
- Private helpers: `finalize_preflight_result/2` (133-141), `preflight_checks/2`
  (909-918), `run_preflight_checks/5` (920-927), `run_preflight_check/5`
  (929-961), `auth_diagnostic/6` (963-973), `auth_failure_reason/2` (975-982),
  `enrich_auth_diagnostic/2` (984-990), `safe_gh_auth_status/1` (992-1002),
  `diagnostic_message/2` (1004-1019), `human_auth_reason/1` (1021-1045),
  `reset_suffix/1` (1047-1048), `human_gh_keyring_status/1` (1050-1059),
  `default_gh_auth_status_fun/0` (2461-2477).
- `preflight_auth/1` calls `parse_repo/0` and `require_token/0`; change to
  `Transport.parse_repo/0` and `Transport.require_token/0`. It uses
  `default_request_fun/1` as the default `:request_fun`; change to
  `&Transport.default_request_fun/1`.
- `run_preflight_check/5`, `auth_diagnostic/6`, and `auth_failure_reason/2` call
  `rate_limited_response?/2`, `rate_limit_remaining/1`, `rate_limit_reset/1`;
  change these to `Errors.rate_limited_response?/2` etc.
- Preserve: check order rate_limit → repository → issues halting on first
  failure; never log or return token material (`giant-client.md` §risk 9;
  FI-GH-003).

### 4. `Aiur.GitHub.StatePolicy` — `src/lib/aiur/github/state_policy.ex`

Move verbatim and make public:

- `normalize_state/1` (2390-2395), `human_review_target_state?/1` (2149),
  `active_target_state?/1` (2315-2317), `terminal_state_label?/2` (2319-2323),
  `terminal_state_name?/1` (2325-2327).
- **Add one new public function** `state_label/2`, defined exactly as:
  ```elixir
  @spec state_label(String.t(), String.t()) :: String.t()
  def state_label(prefix, state_name), do: "#{prefix}:#{normalize_state(state_name)}"
  ```
  Then replace the two inline construction sites in `client.ex`:
  - line 1149 `"#{prefix}:#{normalize_state(&1)}"` → `StatePolicy.state_label(prefix, &1)`
  - line 2058 `"#{update_context.prefix}:#{normalize_state(state_name)}"` →
    `StatePolicy.state_label(update_context.prefix, state_name)`
- Replace every remaining reference in `client.ex` to the moved predicates /
  `normalize_state` with the `StatePolicy.`-qualified call, keeping the
  surrounding expression byte-identical. Specifically the inline terminal checks
  at line 2291 (`normalize_state(state_name) in ["done", "cancelled", "canceled"]`
  → `StatePolicy.normalize_state(state_name) in ["done", "cancelled",
  "canceled"]`) and any others surfaced by the grep in Acceptance.

### 5. `Aiur.GitHub.BotIdentity` — `src/lib/aiur/github/bot_identity.ex`

Move verbatim and make public:

- `@viewer_login_query` (78-84).
- `review_thread_bot_account/3` (1825-1835) → **rename to `bot_account/3`** on the
  new module. Update its three call sites in `client.ex` (lines 1626, 1767, 2109)
  to `BotIdentity.bot_account(...)` with the same arguments.
- `fetch_authenticated_viewer_login/2` (1837-1851), `normalize_optional_binary/1`
  (1853-1860, both clauses), `codeowners_classification_opts/1` (2012-2028),
  `agent_login?/2` (2042-2049, both clauses).
- `bot_account/3` and `fetch_authenticated_viewer_login/2` call `github_graphql/4`
  and `GitHub.Config.bot_account/0`; change the first to
  `Transport.github_graphql/4`, leave the `GitHub.Config.bot_account/0` call as-is.
- Update the remaining `normalize_optional_binary/1` call sites in `client.ex`
  (there are 5 total occurrences; 3 are call sites in the review-thread code that
  stays in `client.ex`) to `BotIdentity.normalize_optional_binary/1`.
- Resolution order opts[:bot_account] → `github.bot_account` config → GraphQL
  `viewer { login }` must be preserved (FI-GH-032).

### 6. Facade (`Aiur.GitHub.Client`, retained)

- Keep `client.ex` as the facade. Its public functions `preflight_auth/1`
  (exporting `/0` and `/1`), `format_auth_preflight_error/1`, and
  `classify_error/1` become **explicit one-line wrapper functions** (NOT
  `defdelegate`, so the default-arg `/0` arity survives — `giant-client.md`
  §risk 1) that call `AuthPreflight.*` / `Errors.*`.
- Re-export the classification type: `@type classification :: Errors.classification()`.
- All other public functions on the facade are unchanged in this wave.
- The moved private helpers are consumed internally by domain code that stays in
  `client.ex`; those internal call sites become module-qualified calls per the
  steps above.

## Files

- Create:
  - `src/lib/aiur/github/transport.ex`
  - `src/lib/aiur/github/errors.ex`
  - `src/lib/aiur/github/auth_preflight.ex`
  - `src/lib/aiur/github/state_policy.ex`
  - `src/lib/aiur/github/bot_identity.ex`
- Modify:
  - `src/lib/aiur/github/client.ex`
- Test:
  - `src/test/aiur/github/transport_test.exs`
  - `src/test/aiur/github/errors_test.exs`
  - `src/test/aiur/github/auth_preflight_test.exs`
  - `src/test/aiur/github/state_policy_test.exs`
  - `src/test/aiur/github/bot_identity_test.exs`

## Out of scope

- Any other domain concern in `client.ex` (Issues, Comments, PullRequests,
  RepoEvents, DependenciesApi, Teams, ReviewThreads, ReviewThreads.Reply/
  Resolution/ResolutionPolicy, HumanReviewGate, IssueState). Those are T-029/T-030.
- `src/lib/aiur/github/config.ex` — the `:persistent_term` token cache
  (`{Aiur.GitHub.Config, :resolved_token}`) and `Config.repo/0`/`token/0` stay
  untouched (`giant-client.md` §risk 2).
- `src/lib/aiur/github/connectivity.ex`, `tracker.ex`, `code_owners.ex`,
  `issue_dependencies.ex`, `labels.ex` — no edits.
- Migrating direct callers (`orchestrator.ex`, `events/*.ex`,
  `codex/dynamic_tool.ex`) off the facade onto the new modules (that is the
  optional Wave 9, a separate ticket). All external callers keep calling the
  facade.
- Editing any existing test file, including
  `src/test/aiur/github_client_test.exs`,
  `src/test/aiur/github/client_events_test.exs`,
  `src/test/aiur/github_auth_preflight_test.exs`, and any file under
  `src/test/aiur/regression/`.
- The `mix.exs` `ignore_modules` list except as noted (do **not** add the five
  new modules to it — they must earn coverage via their own tests).
- Merging/splitting `require_token/0` and `/1`, or "simplifying" any of the
  verbatim-moved bodies.

## Inventory-IDs

Features implemented by the code these files move (from
`docs/refactor/feature-inventory/gh.md`):

- **FI-GH-002** — per-call token requirement + `"test-gh-token"` seam
  (`require_token/1`) → `Transport`.
- **FI-GH-008** — GitHub request defaults (headers, 30s timeout, etag,
  case-insensitive `header/2`) → `Transport`.
- **FI-GH-009** — GraphQL helper error surface (`github_graphql/4`) → `Transport`
  (+ `Errors.github_status_error/1`).
- **FI-GH-010** — GitHub error taxonomy (`classify_error/1`, rate-limit signals,
  `retryable_github_error?/1`) → `Errors`.
- **FI-GH-003** — GitHub auth preflight (`preflight_auth/1`, diagnostics, gh
  keyring status) → `AuthPreflight`.
- **FI-GH-012** — candidate issue fetch state-name normalization (`normalize_state`)
  → `StatePolicy`.
- **FI-GH-015** — `update_issue_state` label swap (state-label construction,
  active/terminal predicates) → `StatePolicy` (`state_label/2`, predicates).
- **FI-GH-016** — terminal state closes issue (`terminal_state_name?/1`) →
  `StatePolicy`.
- **FI-GH-032** — bot identity resolution (config or viewer login) → `BotIdentity`.

## Characterization-tests

These must pass **UNMODIFIED**:

- `src/test/aiur/regression/github_ingestion_test.exs` (created by T-008 —
  "Characterization: GitHub ingestion & wake/rework"; pins the token-env seam and
  the ingestion pipeline that consumes this client through the facade).

Existing facade pinning tests that must also stay green every commit (do not
edit): `src/test/aiur/github_client_test.exs`,
`src/test/aiur/github/client_events_test.exs`,
`src/test/aiur/github_auth_preflight_test.exs`,
`src/test/aiur/github/connectivity_test.exs`,
`src/test/aiur/github/code_owners_test.exs`,
`src/test/aiur/orchestrator_deactivate_test.exs`,
`src/test/aiur/tracker_github_test.exs`.

## Acceptance criteria

All greps run from `src/`.

1. The five modules exist at the exact paths:
   `grep -l "defmodule Aiur.GitHub.Transport do" lib/aiur/github/transport.ex`,
   `grep -l "defmodule Aiur.GitHub.Errors do" lib/aiur/github/errors.ex`,
   `grep -l "defmodule Aiur.GitHub.AuthPreflight do" lib/aiur/github/auth_preflight.ex`,
   `grep -l "defmodule Aiur.GitHub.StatePolicy do" lib/aiur/github/state_policy.ex`,
   `grep -l "defmodule Aiur.GitHub.BotIdentity do" lib/aiur/github/bot_identity.ex`
   each print their path.
2. The moved concerns no longer live in the facade — each grep on
   `lib/aiur/github/client.ex` returns **nothing**:
   - `grep -n "defp classify_transport" lib/aiur/github/client.ex`
   - `grep -n "defp default_request_fun" lib/aiur/github/client.ex`
   - `grep -n "defp github_headers" lib/aiur/github/client.ex`
   - `grep -n "defp github_graphql" lib/aiur/github/client.ex`
   - `grep -n "defp preflight_checks" lib/aiur/github/client.ex`
   - `grep -n "defp run_preflight_check" lib/aiur/github/client.ex`
   - `grep -n "defp normalize_state" lib/aiur/github/client.ex`
   - `grep -n "defp review_thread_bot_account" lib/aiur/github/client.ex`
   - `grep -n "defp rate_limited_response" lib/aiur/github/client.ex`
3. No inline `state_label` construction remains:
   `grep -n ':#{normalize_state' lib/aiur/github/client.ex` returns nothing.
4. `classify_error/1`, `preflight_auth`, and `format_auth_preflight_error/1`
   still exist on the facade as thin wrappers:
   `grep -n "def classify_error" lib/aiur/github/client.ex`,
   `grep -n "def preflight_auth" lib/aiur/github/client.ex`, and
   `grep -n "def format_auth_preflight_error" lib/aiur/github/client.ex` each
   print exactly one `def` line; none of the three uses `defdelegate`
   (`grep -n "defdelegate" lib/aiur/github/client.ex` returns nothing).
5. `lib/aiur/github/client.ex` line count is reduced to **≤ 2050** (from 2,597):
   `test $(wc -l < lib/aiur/github/client.ex) -le 2050`.
6. Each new file is **≤ 200 lines**, except `auth_preflight.ex` which is
   **≤ 215** (the diagnostic-message construction is one cohesive concern that
   must not be split mid-invariant per `giant-client.md` §risk 9). Check:
   `for f in transport errors state_policy bot_identity; do test $(wc -l < lib/aiur/github/$f.ex) -le 200; done`
   and `test $(wc -l < lib/aiur/github/auth_preflight.ex) -le 215`.
7. Every public def in each new module has an `@spec` (enforced by
   `mix specs.check`, part of `mix credo --strict` via the `lint` alias) and each
   new module has a `@moduledoc` string:
   `for f in transport errors auth_preflight state_policy bot_identity; do grep -q "@moduledoc" lib/aiur/github/$f.ex; done`.
8. New code obeys the ≤ 20-logic-line-per-function norm (`state_label/2` and any
   glue). Functions **moved verbatim** keep their current shape — behavior
   preservation outranks the line norm for moved bodies.
9. The five new modules are **not** added to the `ignore_modules` list in
   `mix.exs`: `grep -n "Aiur.GitHub.Transport\|Aiur.GitHub.Errors\|Aiur.GitHub.AuthPreflight\|Aiur.GitHub.StatePolicy\|Aiur.GitHub.BotIdentity" mix.exs`
   returns nothing. Each therefore counts toward the 85% coverage threshold and
   must have its own test file (the five under `Test` above exist and exercise
   each module's public functions).
10. The repo compiles and the full suite passes (see Verification).

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
- **Facade contract intact:** `Aiur.GitHub.Tracker.auth_preflight/0` still resolves
  `preflight_auth/0` **and** `/1` via `function_exported?`
  (`src/test/aiur/tracker_github_test.exs` green), and
  `orchestrator_deactivate_test.exs` fake `:github_client_module` modules still
  satisfy the surface — both suites pass unmodified.
- **Token resolution order preserved:** spot-check that opts-token functions still
  route through `Transport.require_token/1` (`opts[:token]` → `"test-gh-token"`
  when `:request_fun` present → config) and config-only functions through
  `require_token/0`; `github_client_test.exs` token cases pass (FI-GH-002).
- **Error taxonomy wire format unchanged:** `classify_error/1` returns the same
  `{:github, class, detail}` atoms and `github_status_error/1` still escalates to
  the taxonomy only when rate-limited; `client_events_test.exs` and
  `connectivity_test.exs` pass (FI-GH-010).
- **Preflight leaks no token material and halts on first failure order
  rate_limit→repo→issues:** `github_auth_preflight_test.exs` passes (FI-GH-003).
- **Bot identity fallback chain:** opts → config → viewer login still resolves;
  the review-thread verification cases in `github_client_test.exs` pass (FI-GH-032).
- **Coverage:** `mix test --cover` shows the five new modules at/above the 85%
  threshold (they are not in `ignore_modules`).
- Confirm `git diff` touches only the six source files in `Files` plus the five
  new test files — no unrelated edits, no changes under
  `src/test/aiur/regression/`.

## Executor rules (do not skip)
- Work only on your pre-created branch `aiur/<issue-number>`; the PR base is `v2`. PR description starts `Closes #<issue-number>`.
- Commits: 3-7 word imperative messages. Never mention AI, models, or tools in commits or the PR description.
- Behavior-preserving: no feature or API changes beyond the stated Scope.
- If completing this ticket seems to require editing any file not listed in Files, stop: comment the blocker on the issue instead of touching the file.
- If any test under `src/test/aiur/regression/` fails, your change is wrong. Never edit those tests. Comment on the issue, emit `emit_alert` with `needs_attention: true`, and end your turn without opening a PR.
- Never run `aiurdev --test` or `--test3`. Verification is the Agent gate above, only.
