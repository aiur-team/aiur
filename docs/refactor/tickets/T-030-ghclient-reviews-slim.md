# T-030: github client wave 3: ReviewThreads + gates; slim

**Phase:** 3
**Depends-on:** T-029
**Labels:** `agent:todo` `refactor` `phase:3` `complexity:3`

## Problem / context

`src/lib/aiur/github/client.ex` began this refactor at 2,597 lines — a single
module holding the entire GitHub tracker surface. It sits inside the repo's #1
regression hotspot ("GitHub event ingestion & comment→wake/rework pipeline",
~35 incidents; `docs/refactor/research-history-hotspots.md` row 1), and its
review-thread resolve/reply machinery is the exact seam of the
#634→#642→#677→#682→#683 fix-of-fix chain. The decomposition plan and binding
name map are in `docs/refactor/research-arch/giant-client.md`.

T-028 extracted the foundation (`Transport`, `Errors`, `AuthPreflight`,
`StatePolicy`, `BotIdentity`) and T-029 extracted the plain REST domains
(`Issues`, `Comments`, `PullRequests`, `RepoEvents`, `DependenciesApi`,
`Teams`). This is the **final client wave**: extract the review-thread cluster
(`Aiur.GitHub.ReviewThreads` + `.Reply`, `.Resolution`, `.ResolutionPolicy`),
the human-review readiness gate (`Aiur.GitHub.HumanReviewGate`), and the
label-encoded issue-state writes (`Aiur.GitHub.IssueState`) — then slim
`Aiur.GitHub.Client` to a thin facade. After this wave the original ~2,597-line
body is gone and `client.ex` is a wrapper-only facade.

The facade must survive permanently: `Aiur.GitHub.Tracker.client_module/0`
resolves `Application.get_env(:aiur, :github_client_module, Client)` and calls
the Client function surface directly; `orchestrator.ex` probes
`function_exported?(client, :verify_human_review_ready, 1)` and
`preflight_auth/0` vs `/1` arities (research-arch/giant-client.md risk 1,
FI-GH-011, FI-GH-033); `codex/dynamic_tool.ex` defaults to
`&GitHubClient.reply_to_review_thread/3` and
`&GitHubClient.resolve_review_thread/2`; test fakes implement the same surface.
So every extracted body is replaced by an **explicit one-line wrapper** (never
`defdelegate`, so default-arg arities survive) and all existing tests keep
passing unmodified through the facade.

## Scope (exact)

**Binding name map:** `docs/refactor/research-arch/giant-client.md` §2, rows
12–17 and the retained-facade row. Module names, file paths, and
function-to-module assignments below are taken verbatim from that table and are
**not negotiable**. `docs/refactor/research-arch/giant-client.md` §4 (Risks)
names the semantics that must be preserved verbatim — read it before writing a
line.

**Line numbers cannot be trusted this wave.** T-028 and T-029 already moved
~1,300 lines out of `client.ex`, so every line range in the research doc and
below has shifted. **Locate every function by name and arity**, never by line
number. The parenthetical line ranges below are the *pre-refactor* census from
the research doc, given only to identify which body is which.

**Decomposition-wave rules (apply to every extraction in this ticket):**

- Move code **verbatim** — extract, do not rewrite. Do not reformat beyond what
  `mix format` does, do not rename variables, do not "improve", do not
  collapse clauses, do not re-scope a `with`.
- Public function **signatures and observable behavior are unchanged**. Names,
  arities (including default-arg zero/one-arity variants), return-tuple shapes,
  and `Logger` message strings stay byte-identical.
- The parent `Aiur.GitHub.Client` **delegates** to the extracted modules via
  explicit one-line wrappers (NOT `defdelegate`), so every existing caller
  keeps working.
- A `defp` that moves out becomes a `def` (`@doc false` where it was private)
  in its new module.
- Every new module gets a `@moduledoc` (2–4 sentences derived from the
  responsibility sentence in the name-map row) and an `@spec` on every public
  `def` (`mix specs.check` enforces this).
- Every new module gets its own test file (see step 8). New modules are **NOT**
  coverage-exempt — do not add them to `ignore_modules` in `src/mix.exs`; the
  85% coverage threshold enforces that tests exist.
- After every sub-step: `mix compile --warnings-as-errors` and the full
  `mix test` pass. Commit each sub-step separately.
- Dependency direction is strictly downward: `Client` facade → domain modules →
  (`BotIdentity` | `StatePolicy`) → (`Transport` | `Errors`) →
  `Aiur.GitHub.Config`. Nothing under `Aiur.GitHub.*` may call back into the
  facade. `Aiur.Codeowners` (top-level) is a sideways dependency, unchanged.

Execute as four serialized sub-steps in this order (research doc §3, waves
5–8). Where a moved body calls a helper already extracted by T-028/T-029
(`Transport.*`, `Errors.*`, `BotIdentity.*`, `StatePolicy.*`, `PullRequests.*`,
`Issues.*`), keep the exact call as the post-T-029 facade leaves it.

### Step 1 (wave 5): `Aiur.GitHub.ReviewThreads` (core read path)

1. Create `src/lib/aiur/github/review_threads.ex` — module
   `Aiur.GitHub.ReviewThreads`. Move verbatim, as `def` (`@doc false`) where
   private, these functions and attributes (research doc §2 row 12; census §J
   read path + §A GraphQL docs):
   `fetch_unaddressed_pr_review_thread_comments/2` (public entry, keep
   `\\ []` default), `normalize_pr_number/1`,
   `fetch_unaddressed_review_thread_pages/8`,
   `continue_unaddressed_review_thread_pages/8`, `review_threads_page/1`,
   `unaddressed_thread_comments/2`, `unaddressed_thread_comment/2`,
   `thread_comments/1`, `classify_thread_comment/3`,
   `normalize_thread_comment/2`, `thread_ownership_context/2`,
   `unresolved_agent_review_thread_reply?/2`,
   `mark_review_thread_resolution_required/1`, `fetch_review_thread/3`,
   `review_thread_from_body/1`, `normalize_verified_thread_comment/1`, and the
   module attributes `@unaddressed_review_threads_query` and
   `@review_thread_query` (the GraphQL heredocs). `ReviewThreads` aliases
   `Aiur.GitHub.{Transport, Errors, BotIdentity}` and `Aiur.Codeowners`; every
   `Transport.*` / `Errors.*` / `BotIdentity.*` / `Codeowners.*` call moves
   unchanged. `fetch_review_thread/3` stays public here because
   `.Resolution` and `.Reply` (steps 2–3) call it.
2. In `client.ex`: delete the moved bodies; replace the public
   `fetch_unaddressed_pr_review_thread_comments/2` with a one-line wrapper
   `def fetch_unaddressed_pr_review_thread_comments(pr_number, opts \\ []), do:
   ReviewThreads.fetch_unaddressed_pr_review_thread_comments(pr_number, opts)`
   (keep its `@spec`). The reply/resolve/gate bodies still resident in
   `client.ex` this sub-step now call `ReviewThreads.fetch_review_thread/3`.

**Preserve verbatim (research doc §4 risk 6, FI-GH-029):**
`unaddressed_thread_comment/2` only surfaces unresolved threads whose latest
comment is CODEOWNERS-authoritative, **but** an unresolved thread whose latest
comment is the agent's own reply is re-surfaced with
`"review_thread_resolution_required" => true`. Do not simplify either branch.

### Step 2 (wave 6): `Aiur.GitHub.ReviewThreads.Reply`

3. Create `src/lib/aiur/github/review_threads/reply.ex` — module
   `Aiur.GitHub.ReviewThreads.Reply`. Move verbatim (research doc §2 row 13;
   census §J reply loop + §A reply mutation):
   `reply_to_review_thread/3` (public entry, keep `\\ []` default),
   `do_reply_to_review_thread/7`, `retry_review_thread_reply/3`,
   `verify_after_review_thread_reply/2`, `build_review_thread_retry_context/7`,
   `add_review_thread_reply/4`, `verify_review_thread_reply/5`,
   `verify_latest_review_thread_comment/6`, `latest_comment_author_mismatch/2`,
   `latest_comment_body_mismatch/2`,
   `retryable_review_thread_verification_error?/1`,
   `sleep_review_thread_retry/2`, `normalize_review_thread_id/1`,
   `normalize_review_thread_reply_body/1`, `normalize_positive_integer/2`,
   `normalize_non_negative_integer/2`, and the attribute
   `@reply_review_thread_mutation`. `Reply` aliases
   `Aiur.GitHub.{Transport, Errors, ReviewThreads}`; the verify path calls
   `ReviewThreads.fetch_review_thread/3`.
4. In `client.ex`: delete the moved bodies; replace
   `reply_to_review_thread/3` with a one-line wrapper to
   `ReviewThreads.Reply.reply_to_review_thread/3` (keep its `@spec`).

**Preserve verbatim (research doc §4 risk 5, FI-GH-030):** reply is
**mutation-once, verify-with-retry**. After a successful mutation, only
verification retries (linear backoff `retry_delay_ms * attempt` via the
injectable `sleep_fun`); a retry must **never** re-post the reply.
Transport-level failures of the mutation itself retry up to `attempts`
(default 3). The `attempts` / `retry_delay_ms` / `sleep_fun` opts handling
moves byte-for-byte. Pinned by github_client_test.exs:779 ("retries
verification without posting duplicate replies").

### Step 3 (wave 7): `Aiur.GitHub.ReviewThreads.Resolution` + `.ResolutionPolicy`

5. Create `src/lib/aiur/github/review_threads/resolution.ex` — module
   `Aiur.GitHub.ReviewThreads.Resolution`. Move verbatim (research doc §2 row
   14; census §J resolve/unresolve + §A resolve/unresolve mutations):
   `resolve_review_thread/2` (public entry, keep `\\ []` default),
   `do_resolve_review_thread/5`, `verify_review_thread_after_resolution/6`,
   `resolve_review_thread_mutation/3`, `unresolve_review_thread_mutation/3`,
   `unresolve_review_thread_after_post_resolution_failure/4`,
   `verify_resolved_review_thread/3`, `verify_unresolved_review_thread/2`,
   `classify_review_thread_resolution_errors/2`,
   `review_thread_resolution_permission_error?/1`,
   `typed_permission_error?/1`, `known_pat_permission_message?/1`,
   `add_unresolve_verification/2`, `add_unresolve_failure/2`,
   `normalize_review_thread_terminal_reply_body/1`, and the attributes
   `@resolve_review_thread_mutation` and `@unresolve_review_thread_mutation`.
   `Resolution` aliases
   `Aiur.GitHub.{Transport, Errors, ReviewThreads, ReviewThreads.ResolutionPolicy, ReviewThreads.Reply, BotIdentity}`;
   it calls `ReviewThreads.fetch_review_thread/3`,
   `ResolutionPolicy.*` (below), and `Reply.normalize_review_thread_id/1` for
   the id normalization (or move a private copy — see note). If
   `resolve_review_thread/2` used `normalize_review_thread_id/1` (now in
   `.Reply`), call `Reply.normalize_review_thread_id/1`; do not duplicate the
   body.
6. Create `src/lib/aiur/github/review_threads/resolution_policy.ex` — module
   `Aiur.GitHub.ReviewThreads.ResolutionPolicy`. Move verbatim (research doc §2
   row 15; census §J pure verification policy):
   `verify_review_thread_resolution_ready/5`,
   `verify_review_thread_resolution_still_latest/5`,
   `verify_review_thread_resolution_latest_reply/7` and `/8`,
   `resolution_reason/2`, `resolution_precondition_failed/3`,
   `review_thread_authoritative_comment?/2`,
   `normalize_thread_for_comment_context/1`. `ResolutionPolicy` aliases
   `Aiur.Codeowners`; it is pure (map in → verdict out), no `Transport` calls.
7. In `client.ex`: delete the moved bodies; replace `resolve_review_thread/2`
   with a one-line wrapper to
   `ReviewThreads.Resolution.resolve_review_thread/2` (keep its `@spec`).

**Preserve verbatim (research doc §4 risk 4, FI-GH-031) — the resolve TOCTOU
semantics of #679/#682:** the order is sacred:
fetch + **pre-verify** (terminal reply still latest bot comment, thread
unresolved, latest non-agent reviewer comment CODEOWNERS-authoritative for the
thread path) → **resolve** mutation → **post-verify** still-latest → on mismatch
**unresolve** (compensating rollback) and return the enriched error via
`add_unresolve_verification` / `add_unresolve_failure`. Error tuples are a wire
format asserted byte-for-byte by github_client_test.exs (resolve suite around
lines 916–1231): `:review_thread_resolution_precondition_failed`,
`:post_resolve_latest_comment_author_mismatch`,
`:review_thread_resolution_not_permitted` (with the exact token-guidance
string). FORBIDDEN / INSUFFICIENT_SCOPES / PAT errors classify as
`:review_thread_resolution_not_permitted`. Do not reorder, merge, or drop a
verification phase.

### Step 4 (wave 8): `Aiur.GitHub.HumanReviewGate` + `Aiur.GitHub.IssueState`; slim facade

8. Create `src/lib/aiur/github/human_review_gate.ex` — module
   `Aiur.GitHub.HumanReviewGate`. Move verbatim (research doc §2 row 16; census
   §K human-review readiness gate): `verify_human_review_ready/2` (public
   entry, keep `\\ []` default), `verify_human_review_review_threads_clear/2`,
   `verify_issue_review_threads_clear/1`, `verify_pr_review_threads_clear/3`.
   `HumanReviewGate` aliases
   `Aiur.GitHub.{Transport, Errors, PullRequests, ReviewThreads, BotIdentity, StatePolicy}`;
   the PR discovery + unaddressed-thread checks move unchanged.
9. Create `src/lib/aiur/github/issue_state.ex` — module
   `Aiur.GitHub.IssueState`. Move verbatim (research doc §2 row 17; census §K
   state-machine writes): `update_issue_state/3`, `add_label/3`,
   `remove_label/3` (public entries, keep `\\ []` defaults and the
   `when is_binary(...)` guards), `do_update_issue_state/2`,
   `apply_issue_state_update/4`, `swap_labels/4`,
   `swap_and_maybe_close_issue/4`, `add_state_label/3`,
   `add_active_issue_label/2`, `remove_state_labels/7`,
   `remove_active_state_labels/7`, `delete_issue_label/6`, `add_issue_label/6`,
   `maybe_close_issue/4`, `closed_issue?/1`. `IssueState` aliases
   `Aiur.GitHub.{Transport, Errors, StatePolicy, HumanReviewGate}` and
   `Aiur.GitHub.Config`; the human-review gate call
   (`verify_human_review_ready` / `verify_issue_review_threads_clear`) invoked
   from the human-review target-state branch calls `HumanReviewGate.*`, and
   terminal/active/normalize predicates call `StatePolicy.*` exactly as the
   post-T-028 facade leaves them.
10. In `client.ex`: delete the moved bodies; replace `verify_human_review_ready/2`,
    `update_issue_state/3`, `add_label/3`, `remove_label/3` with one-line
    wrappers to `HumanReviewGate.verify_human_review_ready/2`,
    `IssueState.update_issue_state/3`, `IssueState.add_label/3`,
    `IssueState.remove_label/3` respectively (keep each `@spec` and each
    default-arg/guard-preserving arity). Delete any aliases and module
    attributes your moves orphaned. Leave everything else untouched.

**Preserve verbatim (research doc §4 risks 6–7, FI-GH-015/016/017/033):**
`add_active_issue_label/2` **re-GETs the issue between removing old labels and
adding the new active label** and removes-instead-of-adds if the issue closed
in that window — a deliberate race guard (pinned github_client_test.exs:1541
"active label add rechecks issue state after stale label removal"); do not
remove the second GET. `remove_label` and `delete_issue_label` treat 404 as
success (idempotency) while `add_issue_label` accepts only 200/201 and
`add_label` accepts 200..299 — keep the two add variants distinct. Terminal
target states (done/cancelled/canceled, both spellings) PATCH the issue closed;
non-terminal states never touch open/closed. The human-review gate blocks the
human-review transition while the ticket's open `aiur/<issue>` PR has
unaddressed/unresolved review threads and returns
`{:error, {:unverified_review_threads, %{...}}}`; no open PR passes.

**Slimmed facade ceiling.** After Step 4, `client.ex` is a wrapper-only facade:
`@moduledoc`, aliases, the `@type classification` re-export (delegating to
`Errors`), and explicit one-line `@spec`-bearing wrappers for the full current
public surface. It must be **≤ 200 physical lines** (`wc -l
src/lib/aiur/github/client.ex`), target ~130. The public functions this wave
wraps are: `fetch_unaddressed_pr_review_thread_comments/2`,
`reply_to_review_thread/3`, `resolve_review_thread/2`,
`verify_human_review_ready/2`, `update_issue_state/3`, `add_label/3`,
`remove_label/3` (the T-028/T-029 wrappers already exist and stay).

### Tests for the new modules (new modules are NOT coverage-exempt)

11. Create one test file per extracted module under
    `src/test/aiur/github/` (`async: true` where the module is pure —
    `ReviewThreads`, `.Reply`, `.Resolution` inject `request_fun`/`sleep_fun`
    and touch no global state, so async is fine; `IssueState` and
    `HumanReviewGate` likewise inject `request_fun`). Every test drives the
    module's public functions with injected `request_fun` (and `sleep_fun` for
    Reply) stubs — copy the stub shapes already used in
    `src/test/aiur/github_client_test.exs`. Required coverage per file (add
    more if trivial, never fewer):
    - `review_threads_test.exs` (`Aiur.GitHub.ReviewThreadsTest`):
      `fetch_unaddressed_pr_review_thread_comments/2` returns only unresolved
      threads' latest comments, CODEOWNERS-classified; an agent-authored latest
      comment comes back `authoritative: true` AND
      `review_thread_resolution_required: true` (FI-GH-029); GraphQL cursor
      pagination across two pages; `normalize_pr_number/1` on string and
      integer input.
    - `reply_test.exs` (`Aiur.GitHub.ReviewThreads.ReplyTest`): a verified
      first-try reply returns `{:ok, _}`; a verify mismatch then match retries
      verification **without** a second mutation POST (assert exactly one
      `addPullRequestReviewThreadReply` request via a counting stub —
      no-duplicate-reply invariant); a retryable transport error on the
      mutation retries the mutation up to `attempts`; final verify failure
      returns `{:review_thread_reply_not_verified, ...}`; `sleep_fun` is
      injectable and called with the linear backoff (FI-GH-030).
    - `resolution_test.exs` (`Aiur.GitHub.ReviewThreads.ResolutionTest`): a
      clean resolve returns `{:ok, _}`; a reviewer comment landing between
      pre-verify and post-verify triggers a compensating unresolve and returns
      the enriched `:review_thread_resolution_precondition_failed` /
      `:post_resolve_latest_comment_author_mismatch` tuple; a FORBIDDEN
      mutation classifies as `:review_thread_resolution_not_permitted` with the
      token-guidance string (FI-GH-031, TOCTOU #679/#682).
    - `resolution_policy_test.exs`
      (`Aiur.GitHub.ReviewThreads.ResolutionPolicyTest`): pure-function pins on
      `verify_review_thread_resolution_ready/5` (unresolved + bot terminal
      reply latest + authoritative reviewer → `:ok`; already-resolved →
      precondition failure; non-bot latest comment → precondition failure) and
      `review_thread_authoritative_comment?/2`.
    - `human_review_gate_test.exs` (`Aiur.GitHub.HumanReviewGateTest`):
      `verify_human_review_ready/2` returns `:ok` when the canonical
      `aiur/<issue>` PR has zero unaddressed thread comments;
      `{:error, {:unverified_review_threads, %{...}}}` when it has some; the
      no-open-PR branch (`{:ok, nil}`) resolves to a pass (FI-GH-033).
    - `issue_state_test.exs` (`Aiur.GitHub.IssueStateTest`): `update_issue_state/3`
      removes all `<prefix>:*` labels and adds the single new one; a terminal
      target closes the issue; the closed-issue active-target branch strips
      active labels and does NOT add the new one; `add_active_issue_label/2`
      re-checks closed-ness between removal and add (stale-label race, #GH-015);
      `add_label/3` accepts 200..299, `remove_label/3` treats 404 as success
      (FI-GH-015/016/017).
12. Do **not** add any of the six new modules
    (`Aiur.GitHub.ReviewThreads`, `.ReviewThreads.Reply`,
    `.ReviewThreads.Resolution`, `.ReviewThreads.ResolutionPolicy`,
    `.HumanReviewGate`, `.IssueState`) to `ignore_modules` in `src/mix.exs`.
    Do not remove `Aiur.GitHub.Client` from it either (that is not this
    ticket).

## Files

- Create:
  - `src/lib/aiur/github/review_threads.ex`
  - `src/lib/aiur/github/review_threads/reply.ex`
  - `src/lib/aiur/github/review_threads/resolution.ex`
  - `src/lib/aiur/github/review_threads/resolution_policy.ex`
  - `src/lib/aiur/github/human_review_gate.ex`
  - `src/lib/aiur/github/issue_state.ex`
  - `src/test/aiur/github/review_threads_test.exs`
  - `src/test/aiur/github/reply_test.exs`
  - `src/test/aiur/github/resolution_test.exs`
  - `src/test/aiur/github/resolution_policy_test.exs`
  - `src/test/aiur/github/human_review_gate_test.exs`
  - `src/test/aiur/github/issue_state_test.exs`
- Modify: `src/lib/aiur/github/client.ex`
- Test: the 6 new test files above; existing pins run unchanged (see
  Characterization-tests).

## Out of scope

- `src/lib/aiur/github/transport.ex`, `errors.ex`, `auth_preflight.ex`,
  `state_policy.ex`, `bot_identity.ex` (T-028) and `issues.ex`, `comments.ex`,
  `pull_requests.ex`, `repo_events.ex`, `dependencies_api.ex`, `teams.ex`
  (T-029) — call them, never edit them.
- The T-028/T-029 facade wrappers already in `client.ex` (issues, comments,
  PRs, events, dependencies, teams, preflight, error taxonomy) — leave them
  byte-identical; this ticket only adds the seven review/gate/state wrappers
  and deletes the bodies they replace.
- Wave 9 (research doc §3): migrating direct callers (`orchestrator.ex`,
  `events/*`, `codex/dynamic_tool.ex`, `github/issue_dependencies.ex`,
  `github/code_owners.ex`) off the facade onto the domain modules — a separate
  future ticket. Every caller keeps calling through `Aiur.GitHub.Client` this
  wave; make NO caller edits.
- The `:github_client_module` config seam / `Aiur.GitHub.Tracker` — the facade
  contract stays; do not redesign it.
- `Aiur.GitHub.Config` and its `{Aiur.GitHub.Config, :resolved_token}`
  persistent_term token cache — untouched; token resolution stays in
  `Transport` (T-028).
- `Aiur.GitHub.Labels` (label *definitions* for `aiur init`) — distinct from
  `IssueState`'s per-issue label attach/detach; do not touch.
- `Aiur.GitHub.IssueDependencies` (graph/BFS policy) — distinct from
  `DependenciesApi`; do not touch.
- Any existing test file under `src/test/aiur/` — must pass unmodified; do not
  edit or reformat. Everything under `src/test/aiur/regression/` and
  `src/test/fixtures/` is read-only.
- `Aiur.Codeowners` — consumed, never modified.

## Inventory-IDs

Files in this ticket implement/touch, from
`docs/refactor/feature-inventory/gh.md`:

- FI-GH-029 — Unaddressed review-thread comment extraction (GraphQL) → `ReviewThreads`
- FI-GH-030 — Verified review-thread reply with retry → `ReviewThreads.Reply`
- FI-GH-031 — Guarded review-thread resolution with rollback (TOCTOU #679/#682) → `ReviewThreads.Resolution` + `.ResolutionPolicy`
- FI-GH-033 — human-review gate on unaddressed review threads → `HumanReviewGate`
- FI-GH-015 — update_issue_state label-swap lifecycle → `IssueState`
- FI-GH-016 — Terminal state closes the issue → `IssueState`
- FI-GH-017 — add_label / remove_label primitives → `IssueState`
- FI-GH-011 — Tracker behaviour adapter with swappable client (the facade
  contract the wrappers preserve) → retained `Aiur.GitHub.Client`

Consumed but owned elsewhere (not re-implemented here): FI-GH-032 (bot identity
resolution) lives in `Aiur.GitHub.BotIdentity` (T-028); FI-GH-002 (per-call
token seam) and FI-GH-010 (error taxonomy) live in `Transport`/`Errors`
(T-028). This wave calls them unchanged.

## Characterization-tests

The Phase-1 regression file that guards this area is
`src/test/aiur/regression/github_ingestion_test.exs` (T-008) — it exercises the
GitHub client surface through injected `request_fun` stubs at the
Publisher/Exchange boundary and must pass **unmodified**.

The byte-level pins for the review-thread reply/resolve, human-review gate, and
issue-state machinery are the pre-existing facade suites (not under
`regression/`, but they must stay green every sub-step and must **not** be
edited):
`src/test/aiur/github_client_test.exs` (issues/preflight/comments/PRs/
review-thread reply+resolve/update_issue_state/human-review gate/taxonomy;
resolve tuples asserted ~916–1231, no-duplicate-reply at :779, active-label
recheck at :1541), `src/test/aiur/github/client_events_test.exs`,
`src/test/aiur/github_auth_preflight_test.exs`,
`src/test/aiur/orchestrator_deactivate_test.exs` (fake
`:github_client_module` modules exercising `verify_human_review_ready`), and
`src/test/aiur/github/code_owners_test.exs`. If any of these fails, your change
is wrong — fix the code, never the test.

## Acceptance criteria

Mechanically checkable (run from repo root unless noted):

- All six new lib modules exist at their exact paths:
  `test -f src/lib/aiur/github/review_threads.ex`,
  `.../review_threads/reply.ex`, `.../review_threads/resolution.ex`,
  `.../review_threads/resolution_policy.ex`, `.../human_review_gate.ex`,
  `.../issue_state.ex` — all present. Module names match:
  `grep -c "defmodule Aiur.GitHub.ReviewThreads do" src/lib/aiur/github/review_threads.ex` → 1;
  `grep -c "defmodule Aiur.GitHub.ReviewThreads.Reply do" src/lib/aiur/github/review_threads/reply.ex` → 1;
  `grep -c "defmodule Aiur.GitHub.ReviewThreads.Resolution do" src/lib/aiur/github/review_threads/resolution.ex` → 1;
  `grep -c "defmodule Aiur.GitHub.ReviewThreads.ResolutionPolicy do" src/lib/aiur/github/review_threads/resolution_policy.ex` → 1;
  `grep -c "defmodule Aiur.GitHub.HumanReviewGate do" src/lib/aiur/github/human_review_gate.ex` → 1;
  `grep -c "defmodule Aiur.GitHub.IssueState do" src/lib/aiur/github/issue_state.ex` → 1.
- Facade slimmed: `wc -l src/lib/aiur/github/client.ex` → **≤ 200** (target ~130).
- The removed concerns no longer have live implementations in the facade —
  each of these prints `0`:
  `grep -c "defp do_resolve_review_thread\|def do_resolve_review_thread" src/lib/aiur/github/client.ex`;
  `grep -c "defp do_reply_to_review_thread\|def do_reply_to_review_thread" src/lib/aiur/github/client.ex`;
  `grep -c "defp do_update_issue_state\|def do_update_issue_state" src/lib/aiur/github/client.ex`;
  `grep -c "defp verify_issue_review_threads_clear\|def verify_issue_review_threads_clear" src/lib/aiur/github/client.ex`;
  `grep -c "defp add_active_issue_label\|def add_active_issue_label" src/lib/aiur/github/client.ex`;
  `grep -c "@resolve_review_thread_mutation" src/lib/aiur/github/client.ex`;
  `grep -c "@unaddressed_review_threads_query" src/lib/aiur/github/client.ex`.
- The seven public wrappers exist and delegate (each prints ≥ 1):
  `grep -c "ReviewThreads.fetch_unaddressed_pr_review_thread_comments" src/lib/aiur/github/client.ex`;
  `grep -c "ReviewThreads.Reply.reply_to_review_thread" src/lib/aiur/github/client.ex`;
  `grep -c "ReviewThreads.Resolution.resolve_review_thread" src/lib/aiur/github/client.ex`;
  `grep -c "HumanReviewGate.verify_human_review_ready" src/lib/aiur/github/client.ex`;
  `grep -c "IssueState.update_issue_state" src/lib/aiur/github/client.ex`;
  `grep -c "IssueState.add_label" src/lib/aiur/github/client.ex`;
  `grep -c "IssueState.remove_label" src/lib/aiur/github/client.ex`.
- No `defdelegate` in the facade (default-arg arities require explicit
  wrappers): `grep -c "defdelegate" src/lib/aiur/github/client.ex` → 0.
- Every new lib file has a moduledoc: `grep -c "@moduledoc" <file>` → 1 for
  each of the six; and each public `def` has an `@spec`
  (`grep -c "@spec" <file>` ≥ 1 mechanically; reviewer spot-checks 1:1).
- New modules are NOT coverage-exempt:
  `grep -c "Aiur.GitHub.ReviewThreads\b\|Aiur.GitHub.HumanReviewGate\|Aiur.GitHub.IssueState" src/mix.exs`
  → 0 (none added to `ignore_modules`).
- Six new test files exist under `src/test/aiur/github/` and
  `mix test test/aiur/github/review_threads_test.exs test/aiur/github/reply_test.exs test/aiur/github/resolution_test.exs test/aiur/github/resolution_policy_test.exs test/aiur/github/human_review_gate_test.exs test/aiur/github/issue_state_test.exs`
  (from `src/`) passes, 0 failures.
- File-size norms (verbatim comment-bearing moves; research doc §2 judges three
  files cohesive above the 200 norm, so per-file ceilings are stated
  explicitly): `wc -l` prints ≤ **110** for `human_review_gate.ex`, ≤ **170**
  for `resolution_policy.ex`, ≤ **200** for `resolution.ex`, ≤ **240** for
  `reply.ex`, ≤ **240** for `issue_state.ex`, ≤ **260** for
  `review_threads.ex`. New code you author (wrappers, accessors, test helpers)
  keeps functions ≤ 20 logic lines; moved functions keep their exact current
  bodies — do not rewrite a moved function to satisfy a line norm.
- Full suite green after every sub-step commit (`mix test`, 0 failures, no
  skips). The existing facade suites named in Characterization-tests pass
  unmodified: `git diff --name-only origin/v2...HEAD` lists none of them (and
  nothing under `src/test/aiur/regression/` or `src/test/fixtures/`).

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

- Run every grep in Acceptance criteria verbatim; all must match.
- Confirm the diff shows moved bodies **verbatim**:
  `git diff --color-moved=dimmed-zebra origin/v2...HEAD -- src/lib/aiur/github/`
  renders the extractions as moved blocks, not rewrites.
- Check FI-GH-031 (TOCTOU #679/#682): the resolve suite in
  `github_client_test.exs` (~lines 916–1231) passes with the exact tuples
  `:review_thread_resolution_precondition_failed`,
  `:post_resolve_latest_comment_author_mismatch`,
  `:review_thread_resolution_not_permitted` (token-guidance string intact);
  and the pre-verify → resolve → post-verify → unresolve order is preserved in
  `resolution.ex` (read `do_resolve_review_thread/5` +
  `verify_review_thread_after_resolution/6`).
- Check FI-GH-030: `github_client_test.exs:779` ("retries verification without
  posting duplicate replies") passes — the mutation is POSTed exactly once
  across verify retries.
- Check FI-GH-015: `github_client_test.exs:1541` ("active label add rechecks
  issue state after stale label removal") passes — `add_active_issue_label/2`
  still re-GETs the issue before adding the active label.
- Check FI-GH-033: `verify_human_review_ready/2` remains exported at arity 1
  from `Aiur.GitHub.Client` (the orchestrator's `function_exported?` probe):
  `cd src && mix run -e 'Code.ensure_loaded(Aiur.GitHub.Client); IO.puts(function_exported?(Aiur.GitHub.Client, :verify_human_review_ready, 1))'`
  → `true`; `orchestrator_deactivate_test.exs` green.
- Check the facade contract (FI-GH-011): `preflight_auth/0` and `/1` both stay
  exported (T-028 wrappers untouched), and `mix test test/aiur/tracker_github_test.exs`
  is green.
- Confirm no direct caller was migrated this wave: `git diff --name-only
  origin/v2...HEAD` contains no `orchestrator.ex`, `events/`, `dynamic_tool.ex`,
  `issue_dependencies.ex`, or `code_owners.ex` change.

## Executor rules (do not skip)
- Work only on your pre-created branch `aiur/<issue-number>`; the PR base is `v2`. PR description starts `Closes #<issue-number>`.
- Commits: 3-7 word imperative messages. Never mention AI, models, or tools in commits or the PR description.
- Behavior-preserving: no feature or API changes beyond the stated Scope.
- If completing this ticket seems to require editing any file not listed in Files, stop: comment the blocker on the issue instead of touching the file.
- If any test under `src/test/aiur/regression/` fails, your change is wrong. Never edit those tests. Comment on the issue, emit `emit_alert` with `needs_attention: true`, and end your turn without opening a PR.
- Never run `aiurdev --test` or `--test3`. Verification is the Agent gate above, only.
