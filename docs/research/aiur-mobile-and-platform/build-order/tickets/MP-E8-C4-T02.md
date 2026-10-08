---
ticket_id: MP-E8-C4-T02
feature_id: MP-E8
chunk_id: MP-E8-C4
bucket: 2-platform
title: One-time history backfill (about 42-45 GraphQL points)
status: blocked
blocked_by: [DESIGN-E8, MP-E8-C4-T01]
complexity: 4
design_gate: DESIGN-E8
owns_edge_cases: [EC-32, EC-31]
base_sha: 58854d4c8
researched: 2026-10-08
---

# MP-E8-C4-T02 — One-time history backfill

> Code is cited at `origin/main` `58854d4c8` (`aiur-worktrees/runtime/src`).
> Paths marked PROPOSED do not exist yet. **Read
> `website/docs-app/apis/github.md` before you start** (AGENTS.md "Auth").

## Identity and outcome

- Bucket 2, feature MP-E8 (continuous build history home page), chunk C4
  (durable history store), ticket T02.
- **User value:** the home page can show every past ticket of the repository,
  not only the last 72 hours that `ResourceStore` keeps
  (`lib/aiur/github/resource_store.ex:264` `@retention_ms 72 * 60 * 60 * 1000`).
  Without this ticket the history side of the page is empty for every ticket
  closed before the store started.
- **Deliverable:**
  1. PROPOSED `src/lib/aiur/build_order/history/backfill.ex`: a daemon-owned,
     supervised process that reads every issue of the configured repository
     once, with one paged GraphQL query, and writes the rows into the C4-T01
     `Aiur.BuildOrder.History` store through `History.apply/2`.
  2. PROPOSED `src/lib/aiur/build_order/history/backfill_query.ex`: the query
     text and a pure normalizer from one GraphQL page to C4-T01 events.
  3. The resume checkpoint, stored **inside** the History file through the
     C4-T01 `checkpoint: {:backfill, map}` option, so rows and checkpoint land
     in one write (EC-31). No second state file.
  4. Pacing, a reserve and an hourly point cap, so the job never competes with
     dispatch for GraphQL budget (EC-32).
  5. `History.mark_complete/1` after the last page, and a `Backfill.status/0`
     read that says exactly where the backfill is. "Not finished" is never
     shown as "finished" or as "no history".
  6. Values for the C4-T01 row fields `node_id`, `updated_at`,
     `last_closed_at`, `in_progress_at`, `sub_issues_added`, `labels_complete`,
     `blocked_by_complete`, `timeline_complete` and the `actor` key on
     `label_events` items (C6-T02 request). C4-T01's version-1 row already has
     them; this ticket adds no row field.
  7. One new caller, `build_order_history_backfill`, in `aiur github-cost`.
  8. One paragraph in `website/docs-app/apis/github.md` for the new spend.
- **Non-goals:**
  - No steady-state reads. After the backfill completes, C4-T03 keeps History
    current from existing feeds. This ticket adds no recurring poll.
  - No start or end derivation (C4-T04), no edge or children index (C4-T05), no
    epic or feature resolution (C5, C6), no rendering (C8, C9).
  - No issue bodies and no PR file lists (see "Interface mismatches", item 6).
  - No new config key and no new CLI command.

## Dependencies and blockers

- **Blocked by DESIGN-E8** (the owner gate for every MP-E8 ticket). This ticket
  draws no pixels. Its only visible effect is the "history incomplete" state,
  which C9-T13 renders with the S-9 default (`.bd-mk.empty` marker,
  "unavailable" copy and the age; `owner-design-tasks/DESIGN-E8.md:109`).
- **Blocked by MP-E8-C4-T01** (the `Aiur.BuildOrder.History` store). This ticket
  uses the C4-T01 interface as that ticket specifies it (C4-T01 §4.3, §4.4).
  Settled 2026-10-08: the names below are final (no `History.status/0`, no
  `History.apply_rows/2`, no separate backfill file).
  - `History.apply(events, checkpoint: {:backfill, map}) ::
    {:ok, %{generation, changed}} | {:error, reason}`. An event is
    `%{number, observed_at, source: :backfill, fields: %{...}}`; a field absent
    from `fields` means "no information". Every event is validated first; any
    invalid event rejects the whole call (`{:error, {:invalid_event, i, r}}`).
  - Merge rule (C4-T01 §4.2): G fields are ordered by `updated_at`, then
    `observed_at`; an older event only fills `:unknown`; signals are
    earliest/latest; `label_events`, `sub_issues_added` and `sources` are
    unions; an unchanged merge is a no-op.
  - `History.health/1 :: ProviderHealth` with `complete?` and `failure`
    (`:backfill_pending`, `:history_corrupt`, `:history_rebuilding`,
    `:version_unsupported`, `:repository_mismatch`, `:state_dir_unavailable`,
    `:history_not_running`).
  - `History.checkpoint(:backfill, opts) :: {:ok, map | nil} | {:error, health}`.
  - `History.mark_complete/1`, `History.flush/1`.
  - On a corrupt file C4-T01 quarantines it, clears the `backfill` checkpoint,
    persists status `rebuilding`, **accepts writes**, and stays unavailable
    until this ticket calls `mark_complete/1` (C4-T01 §6). This ticket must
    therefore run, not wait, in that state.
- Shared contract: none (MP-E8 owns no contract; `tickets/CONTRACT-REQUESTS.md`).
- Shared code with C4-T03: the GraphQL issue-node parser PROPOSED
  `Aiur.BuildOrder.History.IssueNode.from_graphql/1` (C4-T03 "Shared code with
  C4-T02"). Whichever ticket merges first creates it; this ticket adds the
  timeline fields in `BackfillQuery`, not in `IssueNode`.
- Unresolved research: the exact point cost of the combined query is measured
  in this ticket (step 9). The plan's "about 30 points" came from separate
  1-point page shapes (baseline.md:344-350). The combined query is predicted
  at 3 points a page (see "Chosen design", cost).
- **May run concurrently with** C4-T03 (feed; different files, same store
  interface) and every C5-C7 ticket.
- **Successors:** C4-T04 (start and end), C4-T05 (edges and children index),
  C6-T02 (`label_events` with `actor`), C6-T03 (Build Order root join times),
  C8-T04 (`Backfill.status/0`), C13-T01 (export; see "Interface mismatches").

## Verified starting point (`58854d4c8`)

**GraphQL request path (reuse, do not copy):**

- `lib/aiur/build_order/github_graph/request.ex:6-21` `Request.page/4`: needs a
  state map with `request_fun`, `calls`, `pages`, `page_budget`, `call_budget`,
  `rate_limit`; enforces the two budgets (`:8-12`); calls
  `Transport.github_graphql_response/5` with `caller: caller(query)` (`:17`);
  returns `{:ok, body, state}` or `{:error, reason, state}`.
- `request.ex:27-33` `caller/1` maps the operation name to the billed caller.
  An unknown name falls back to `:build_order_graph` (`:31`). **A new operation
  name must get its own clause**, or the backfill is billed to the Build Order
  graph row and `aiur github-cost` cannot separate it (#2084 comment `:23-26`).
- `request.ex:35-75` `observe/3`, `query_cost/2`: copy the body's
  `rateLimit.cost`, `remaining`, `limit` and `resetAt` (an ISO string) into
  `state.rate_limit`. With a fresh state per page, `cost` is that page's cost.
- `lib/aiur/github/transport.ex:605-612` `github_graphql_response/5`: prices the
  document with `GraphQLCost.check/2` before sending; `:614-623` instruments it
  and stamps the caller (`:769-776` `put_caller/2`, atom to string).
- `transport.ex:646-649` `validate_graphql_response/1`: a local budget hold
  comes back **raw** as `{:error, {:aiur, :locally_held, hold}, nil}` (`:647`);
  other transport errors go through `Errors.classify_error/1` (`:648`).
- `transport.ex:664-668` a 200 body with `errors` becomes
  `Errors.graphql_error(response)` (`lib/aiur/github/graphql_errors.ex:6-12`):
  `{:github, :rate_limited | :permission, detail}` or the bare atom
  `:graphql_partial`. A page with `errors` never reaches the caller as `{:ok, …}`.
- `transport.ex:656-659` a non-200 status becomes
  `Errors.github_graph_status_error/1` (`lib/aiur/github/errors.ex:129-139`):
  401 `:auth`, 429 `:rate_limited`, 403 `:rate_limited` or `:permission`. Its
  `reset_at` is an ISO string or absent (`graphql_errors.ex:52-63`).
- `transport.ex:116-121` `default_request_fun/1`: credential selection, then the
  normal request path (read cache, quota, budget admission).
- `transport.ex:78-91` `require_token/1`: with a `:request_fun` option it always
  returns `"test-gh-token"` (`:85-88`). This ticket therefore takes the token
  through an injected `:token_fun` (default `&Transport.require_token/0`,
  `:70-76`), as `lib/aiur/build_order/ad_hoc_source.ex:98-103` does with
  `request_fun`, `token_fun` and `now_fun`. Otherwise the "no token" path is
  untestable.
- `lib/aiur/github/read_cache/policy.ex:273-286` `@callers`: a caller absent
  from this table is refused by the read cache (default deny). **Do not add**
  `build_order_history_backfill` to it: every page has a new cursor and must be
  fresh.
- `lib/aiur/github/graphql_cost.ex:105-106` ceiling 20,000 estimated points,
  100 nodes a point; `:252-256` `estimate/1` multiplies `first:` down the
  nesting; `:277` `check/2`.
- `lib/aiur/build_order/github_graph/queries.ex:8` the `rateLimit` selection;
  `:10-20` GitHub bills a nested connection per *parent*, measured #1766.
- `lib/aiur/build_order/github_graph/pager.ex:54-56, 72-74` `remember_total/2`
  fails a read with `:pagination_mismatch` when `totalCount` changes between
  pages. **Do not reuse `Pager`** for a repository-wide listing: a new issue
  opened during the backfill changes `totalCount` and would fail the run.

**Errors and holds:**

- `lib/aiur/github/errors.ex:189-215` `retryable_github_error?/1`: the one source
  of truth for transient versus permanent. True for `{:aiur, :locally_held, _}`
  (`:197`, `:205`), `{:github, kind, _}` with kind `:dns`, `:timeout`, `:tls`,
  `:transport`, `:rate_limited`, `:local_hold` (`:199-201`), 5xx (`:203`), and
  GraphQL errors of a transient type (`:211-213`, types at `:12-19`). False for
  `:graphql_partial`, `:auth`, `:permission` and anything else (`:215`).
- `errors.ex:75-91` the broker-timeout shape
  `{:github, :local_hold, %{reason: :github_budget_broker_timeout}}` (no
  `reset_at`).
- `lib/aiur/github/local_hold.ex:104-110` `LocalHold.run/2` **sleeps** in the
  caller; `:132-141` `wait_ms/2` uses the real clock and returns `:no_wait` for
  any hold longer than 60 s (`@max_wait_ms`, `:68`). Neither fits a GenServer
  with an injected clock, so this ticket computes its own delay from the
  hold's `reset_at` and reuses only `LocalHold.backoff_base_ms/0` (`:88-89`).
- `lib/aiur/build_order/graph_projection.ex:1150-1156` reads `reset_at` from both
  hold shapes (`{:aiur, :locally_held, %{reset_at: %DateTime{}}}` and
  `{:github, _, %{reset_at: %DateTime{}}}`). Same matching here.

**Identity and lifecycle:**

- `lib/aiur/github/config.ex:51-54, 64-69` `configured_repo/0`: the explicit
  `tracker.github.repo`, else the `origin` fallback (`:76`). This is the same
  source as `Config.repo/0` (`:24-30`), which C4-T01 uses for the store's
  `repository` (`lib/aiur/github/tracker.ex:14`). Using the same source means
  the store's `:repository_mismatch` check guards the backfill too.
- `lib/aiur/github/config.ex:310` `label_prefix/0` (default `agent`).
- `lib/aiur/config.ex:208-211` `tracker_kind/0` (calls `settings!/0`, can raise).
- `lib/aiur/build_order/lifecycle.ex:65-104` `Lifecycle.from_github/2`: state
  `OPEN`/`CLOSED`; reasons `COMPLETED`, `NOT_PLANNED`, `DUPLICATE`, `REOPENED`,
  nil → `:none`.
- `lib/aiur/build_order/bounded.ex:119-130` `Bounded.same_repository?/2` on
  `%{owner:, repository:}`. Repository refs in rows use this shape.

**Supervision and test gating:**

- `lib/aiur.ex:452-453` `{Aiur.BuildOrder.TicketHistoryProvider, …}` then
  `{Aiur.BuildOrder.AdHocSource, poll_on_start: Application.get_env(:aiur,
  :build_order_adhoc_poll?, true)}`. C4-T01 puts the `History` child just before
  `:452`; this ticket's child goes right after it, with the same
  `Application.get_env` gate shape.
- `config/config.exs:27` the `:test` block; `:66` sets
  `:build_order_adhoc_poll?` to `false`. This ticket adds its gate next to it.

**Policy (`website/docs-app/apis/github.md`):**

- `:294` opening or holding a page open costs zero API calls. The backfill
  therefore must not be triggered by a page view.
- `:338` GraphQL is a separate points budget; `:348-372` `aiur github-cost`
  ranks by caller; `:360` `SOURCE` is `reported` when the query carries
  `rateLimit { cost }`; `:375-400` the traps (a restart breaks reconciliation
  for the window).
- `:551-565` the agent `gh` wrapper does **not** refuse `gh api graphql`; it only
  does not share its answer (`:565`). The README row's reason ("the agent `gh`
  wrapper refuses GraphQL") is wrong. The real reasons this job is
  daemon-owned: the History store is daemon-private state under
  `decision_state_dir`, agents do not hold `GITHUB_TOKEN` (AGENTS.md "Auth",
  #2356), and the spend must be billed to one named daemon caller.

**Census facts (baseline.md:344-350, :368-375, measured 2026-10-06):** 1,344
issues (118 open, 1,226 closed: 1,165 completed, 61 not planned); 14 pages of
100; a page with `labels(30)` cost 1 point, a page with `timelineItems(first:50)`
cost 1 point; longest filtered timeline 51 items; 31 blocked issues with 73
`blocked_by` edges; 116 issues with a parent.

**Tests to model on:** `test/aiur/build_order/github_graph_test.exs` (stub
`request_fun` matching `%{body: %{"query" => query}}`, `:102`; queued
responses, `:328`). Store setup: C4-T01's own tests (History started per test
with a temp `state_dir` and a test server name).

## Chosen design

### The query (one document, one connection walk)

PROPOSED `BackfillQuery.query/0`. Operation name `AiurBuildOrderHistoryBackfill`.

```graphql
query AiurBuildOrderHistoryBackfill($owner: String!, $repo: String!, $cursor: String) {
  rateLimit { limit cost remaining resetAt }
  repository(owner: $owner, name: $repo) {
    issues(first: 100, after: $cursor, orderBy: {field: CREATED_AT, direction: ASC}) {
      totalCount
      pageInfo { hasNextPage endCursor }
      nodes {
        id number title state stateReason createdAt updatedAt closedAt
        parent { number repository { name owner { login } } }
        labels(first: 100) { totalCount nodes { name } }
        blockedBy(first: 100) { totalCount pageInfo { hasNextPage endCursor }
            nodes { number repository { name owner { login } } } }
        timelineItems(first: 100, itemTypes: [LABELED_EVENT, UNLABELED_EVENT,
            CONNECTED_EVENT, CLOSED_EVENT, SUB_ISSUE_ADDED_EVENT]) {
          pageInfo { hasNextPage }
          nodes {
            __typename
            ... on LabeledEvent { createdAt actor { login } label { name } }
            ... on UnlabeledEvent { createdAt actor { login } label { name } }
            ... on ConnectedEvent { createdAt subject { ... on PullRequest { number mergedAt } } }
            ... on ClosedEvent { createdAt closer { ... on PullRequest { number mergedAt } } }
            ... on SubIssueAddedEvent { createdAt subIssue { number repository { name owner { login } } } }
          }
        }
      }
    }
  }
}
```

Why this shape:

- **`orderBy CREATED_AT ASC`** makes the cursor stable: a new issue lands at the
  end, so a resumed run neither skips nor repeats a page.
- **No `states:` filter** returns open and closed issues. `repository.issues`
  never returns pull requests.
- **`first: 100` on `labels`, `blockedBy` and `timelineItems`** costs the same
  as a smaller `first:`, because these three are leaf connections (nothing
  inside them is a connection), and GitHub bills a nested connection per parent
  (`queries.ex:10-20`). This does not hold for a connection that has another
  connection inside it (`graphql_cost.ex` moduledoc: `reviewThreads(first: 100)`
  billed 35 against 8 at `first: 20`). `actor`, `label`, `subject`, `closer`,
  `subIssue` and `repository` are objects, not connections.
- **`SUB_ISSUE_ADDED_EVENT`** gives C6-T03 its join times
  (`SubIssueAddedEvent.createdAt`, baseline §4.1, verified on #2573) in the same
  connection, at no extra cost. The README row lists four item types; this one
  shares the connection.
- **`actor { login }`** on label events gives C6-T02 its `label:<login>` source
  (C6-T02 "Return to C4-T01/C4-T02 owners"). Object field, no extra cost.
- **`closer` on `ClosedEvent`** gives the merged PR's number and `mergedAt` for
  C4-T04's end without a REST `pulls` listing.
- **No overflow follow-up queries.** A timeline is read oldest first, so the
  first `in-progress` label is in the first 100 items whenever it exists. When
  `timelineItems.pageInfo.hasNextPage` is true, the row gets
  `timeline_complete: false` and the "latest wins" fields (`merged_at`,
  `pr_number`) are left out of the event (unknown), never set to `:none`. The
  longest filtered timeline in the census was 51 items, so this is expected to
  be zero rows. Same rule for `labels` with `totalCount > 100`
  (`labels_complete: false`).
- **`blockedBy` overflow is paged.** When `blockedBy.pageInfo.hasNextPage` is
  true, the page event carries the first 100 blockers with
  `blocked_by_complete: false`. The job then pages that issue's `blockedBy`
  with `AiurBuildOrderHistoryBackfillBlockedBy` (`issue(number:) { blockedBy(
  first: 100, after: $cursor) … }`, same caller clause, same pacing) and, on
  the last page, applies the full list with `blocked_by_complete: true`. The
  census maximum is far below 100 (73 edges over 31 issues), so this is
  expected to run zero times.

**Cost (prediction, measured in step 9):** per page, 1 (`issues`) + 100 × 3 leaf
connections = 301 requests → 3 points. This matches the census: one nested
connection per issue gave 101 requests and was billed 1 point
(baseline.md:344-349). 14 pages → **about 42 points**; with one or two retried
pages, about 45. `GraphQLCost.estimate/1` gives 100 + 3 × 10,000 = 30,100 nodes
(301 estimated points), under the 20,000 ceiling (`graphql_cost.ex:105`). The
plan's "about 30" figure is not used.

### Events (output of the normalizer)

`BackfillQuery.events(body, repo, prefix, observed_at)` is pure. It returns
`{:ok, events, page_info}` or `{:error, :invalid_backfill_page}` (no
`data.repository.issues`, or a node without an integer `number`). One C4-T01
event per issue: `%{number, observed_at, source: :backfill, fields: fields}`.
`observed_at` is the page's receive time from `now_fun`.

| Field | From | Rule |
| --- | --- | --- |
| `node_id` | `id` | GraphQL node id (C11-T02 reads closed-ticket bodies through it) |
| `updated_at` | `updatedAt` | `DateTime`; the G-field version (C4-T01 rules 1 and 6) |
| `title` | `title` | untrusted text; stored as data, escaped by the renderer (EC-30 belongs to C8/C9) |
| `lifecycle` | `state`, `stateReason` | `Lifecycle.from_github/2` (`lifecycle.ex:74-75`) |
| `created_at` | `createdAt` | `DateTime` |
| `closed_at` | `closedAt` | `DateTime`; open issue → `:none` |
| `last_closed_at` | `closedAt` | closed issue → `DateTime` (GitHub keeps the latest close); open issue → left out |
| `labels` | `labels.nodes[].name` | current labels (type and epic inputs, C5) |
| `parent` | `parent` | `%{owner, repository, number}`; null → `:none` |
| `blocked_by` | `blockedBy.nodes` | `[%{owner, repository, number}]`; a blocker in another repository keeps its owner and name (C4-T05 marks it `missing`); over 100 → paged (above) |
| `label_events` | `LabeledEvent`/`UnlabeledEvent` whose label starts with `feature:` or equals `"#{prefix}:in-progress"` | `[%{label, action: :labeled \| :unlabeled, at, actor}]`; `actor` is the login or `:unknown` (deleted user) |
| `in_progress_at` (NEW) | earliest `LabeledEvent` with label `"#{prefix}:in-progress"` | left out when none is found |
| `merged_at`, `pr_number` | latest `ClosedEvent.closer` that is a PR with `mergedAt`; else latest `ConnectedEvent.subject` with `mergedAt` | closed + timeline complete + none found → `:none`; open, or timeline incomplete → left out |
| `sub_issues_added` | `SubIssueAddedEvent` | `[%{ref: %{owner, repository, number}, at}]`; only roots have them; C6-T03 |
| `labels_complete`, `blocked_by_complete`, `timeline_complete` | `totalCount <= 100`; `not hasNextPage` | `false` means "may be missing items", never "no items" |

Other label events are dropped: they are the bulk of the timeline (every state
swap is an unlabel plus a label) and no consumer reads them. This keeps the
store near C4-T01's 0.4 MB estimate. `REOPENED_EVENT` is not read: no
successor uses it (C4-T04 sees a reopen through `closed_at` and
`last_closed_at`).

### Row fields this ticket adds to `History.Row`

None. C4-T01's version-1 row already has every field above, with its
sentinels, JSON encoding and merge classes: `in_progress_at` (earliest),
`sub_issues_added` (`[%{ref, at}]`, union on `{ref, at}`), the three
`*_complete` flags (G), and `actor :: String.t() | :unknown` on each
`label_events` item. The dedupe key for `label_events` stays
`{label, action, at}`, so a C4-T03 event without an actor and a backfill event
with one are one item; the one with a known actor wins.

`in_progress_at` is written through an interim `put_signals/2` helper in
`backfill_query.ex` (earliest wins). C4-T04 replaces it with `Timing.merge/3`
in its PR.

### The process

PROPOSED `Aiur.BuildOrder.History.Backfill`, a `GenServer` named by module,
started in `lib/aiur.ex` right after the C4-T01 `History` child, behind
`Application.get_env(:aiur, :build_history_backfill_enabled?, true)` (set to
`false` in the `config/config.exs` `:test` block, next to `:66`). Tests start
it under a test name with injected `:request_fun`, `:token_fun`, `:repo_fun`,
`:now_fun`, `:schedule_fun`, `:history` (server name of a temp C4-T01 store) and
`:tracker_kind_fun`.

State machine (`status/0` returns `{state, detail_map}`):

```text
init ─┬─ tracker kind != "github" (or settings raise) ─► :not_applicable  (no timer)
      ├─ configured_repo error ─────────────────────────► {:unavailable, %{reason}}
      ├─ token_fun error ───────────────────────────────► {:unavailable, %{reason: :missing_github_token}}
      └─ otherwise, after @start_delay_ms ──────────────► check
check ─┬─ health.complete? and checkpoint status "complete"
       │  and query_version == @query_version ─────────► {:complete, %{completed_at, issues, points}}
       ├─ failure :history_corrupt / :history_rebuilding ► {:running, …} from cursor nil
       ├─ any other :unavailable failure ──────────────► {:waiting_for_history, %{reason}}
       │                                                  (re-check every @history_retry_ms; zero requests)
       └─ otherwise ───────────────────────────────────► {:running, %{pages, issues, total, points}}
                                                          from the checkpoint cursor (nil if absent,
                                                          or if its query_version differs)
page ─┬─ ok ─────────────► History.apply(events, checkpoint: …) → pace → page
      │                    last page: mark_complete + flush → :complete
      ├─ hold / rate limit ► {:held, %{until, reason}} → same cursor at `until`
      ├─ transient error ──► retry with backoff, at most @max_retries in a row
      └─ permanent error ──► {:failed, %{reason, at}} (checkpoint kept, no timer)
```

The checkpoint map passed with each page (C4-T01 stores it in the same write
as the rows):

```elixir
%{"query_version" => 1, "status" => "running" | "complete",
  "cursor" => end_cursor, "pages" => 5, "issues" => 500, "points" => 15,
  "started_at" => "2026-10-08T10:00:00Z", "completed_at" => nil}
```

- `started_at` is set on the first page of a run and kept across resumes. It is
  the floor C4-T03 uses for its boot catch-up (`:backfill.started_at`; C4-T03's
  watermark is its own `:closed_since` checkpoint).
- The final page is applied with `"status" => "complete"`, then
  `History.mark_complete/1`, then `History.flush/1`. Only after `flush` returns
  `:ok` does `status/0` say `:complete`.
- A later release that changes the query bumps `@query_version`; the next boot
  re-runs once from cursor nil. The store stays `complete?: true` meanwhile,
  because its rows are still whole.

Constants (module attributes, one `ponytail:` comment naming the limit):

| Constant | Value | Why |
| --- | --- | --- |
| `@query_version` | 1 | Re-run once when the query changes. |
| `@start_delay_ms` | 60_000 | The boot listing and the first poll sweeps go first (restart cold-poll cost). |
| `@page_interval_ms` | 10_000 | 14 pages take about 2.5 minutes. |
| `@reserve_fraction` | 0.2 | If the last reported `remaining` is below 20 % of `limit`, hold until `resetAt`. |
| `@hourly_point_cap` | 300 | At most about 6 % of the 5,000-point hour. A 10k-issue repository (about 300 points) still finishes in about an hour. |
| `@max_retries` | 3 | Then `:failed`. |
| `@history_retry_ms` | 60_000 | Re-check a store that refuses writes. |

The first page has no `remaining` reading yet. It is sent anyway: it costs about
3 points and gives the reading. Unknown `remaining` is not treated as zero or
as full; it is treated as "send one page and look".

Write rate: one `History.apply/2` per page, so at most one store write per
10 s. C4-T01's default 2 s debounce (`flush_ms`) needs no change for this
ticket.

### Status read

`Backfill.status/0 :: {atom, map}`. `:complete` is the only value that means
"history is whole". C8-T04 (assembler) and C9-T13 (markers) must show every
other value as "history incomplete" with its age (S-9 default). A
`GenServer.call` that times out or a process that is not running returns
`{:unavailable, %{reason: :backfill_not_running}}`, never `:complete`.
Consumers that only need "is the store whole" read `History.health/1`
`complete?` (C4-T05, C13-T01), which this ticket sets through `mark_complete/1`.

## Implementation steps

1. `request.ex:27-33`: add
   `"AiurBuildOrderHistoryBackfill" -> :build_order_history_backfill` and
   `"AiurBuildOrderHistoryBackfillBlockedBy" -> :build_order_history_backfill`
   to `caller/1`. Do not touch `read_cache/policy.ex`.
2. No `row.ex` change: the fields are in C4-T01's version 1. Add the interim
   `put_signals/2` for `in_progress_at` (C4-T04 replaces it with
   `Timing.merge/3`).
3. `IssueNode.from_graphql/1`: reuse it if C4-T03 has merged; else create it
   with the issue-level fields (`number`, `title`, `lifecycle`, `created_at`,
   `closed_at`, `labels`, `parent`, `blocked_by`, the two `*_complete` flags).
4. PROPOSED `lib/aiur/build_order/history/backfill_query.ex`: `query/0`,
   `variables/3` (`owner`, `repo`, `cursor`), `events/4`, and the `blockedBy`
   follow-up query and its normalizer. Pure; no process, no I/O. Uses
   `IssueNode` for issue fields and adds the timeline fields.
5. PROPOSED `lib/aiur/build_order/history/backfill.ex`: the GenServer above.
   Each page:

   ```elixir
   state = %{request_fun: rf, calls: 0, pages: 0, page_budget: 1, call_budget: 1, rate_limit: %{}}
   case Request.page(state, token, BackfillQuery.query(), BackfillQuery.variables(owner, repo, cursor)) do
     {:ok, body, %{rate_limit: rl}} ->
       with {:ok, events, info} <- BackfillQuery.events(body, repo_ref, prefix, now_fun.()),
            {:ok, _} <- History.apply(events, server: history, checkpoint: {:backfill, advance(cp, info, events, rl)}) do
         schedule_next(rl, info)          # pace, reserve, hourly cap, or finish
       end
     {:error, reason, %{rate_limit: rl}} -> handle_error(reason, rl)
   end
   ```

   `page_budget`/`call_budget` of 1 make each `Request.page/4` call one HTTP
   request; the loop is the GenServer's, not `Request`'s. The hourly cap sums
   `cost` per page over a 60-minute window kept in the process state (rebuilt
   as empty at boot; the reserve check covers spend from before a restart).
   All delays go through `schedule_fun` (default `Process.send_after/3`); the
   process never sleeps.
6. `handle_error/2` (delays computed from `now_fun`, never the real clock):
   - `{:aiur, :locally_held, %{reset_at: %DateTime{} = at}}` (the GraphQL hold
     shape, `transport.ex:647`) or `{:github, _, %{reset_at: %DateTime{} = at}}`
     → `{:held, %{until: at, reason: :local_hold}}`; next page at `at`, same
     cursor. Not counted as a retry.
   - `{:github, :local_hold, %{reason: :github_budget_broker_timeout}}` or a
     hold with no `reset_at` → back off `LocalHold.backoff_base_ms/0` doubled
     per consecutive retry; counts toward `@max_retries`.
   - `{:github, :rate_limited, detail}` → hold until `detail.reset_at` (ISO
     string, parsed), else `now + retry_after` seconds, else the last observed
     `rl.reset_at`, else the backoff. Never `:failed`.
   - `:graphql_partial` (200 with `errors` that GitHub did not classify) →
     retried with backoff up to `@max_retries`, then `:failed`. This is the one
     place this job retries beyond `Errors.retryable_github_error?/1`, because
     a heavy page can fail partially on a GitHub timeout (decision 9).
   - any other `Errors.retryable_github_error?/1` true → retry with backoff, at
     most `@max_retries` in a row, then `:failed`.
   - otherwise (`:auth`, `:permission`, 404, `{:graphql_cost_ceiling, _}`,
     `:invalid_backfill_page`, any `History.apply/2` error) → `{:failed, %{reason,
     at}}`, no timer. The checkpoint in the store is unchanged, so the next
     daemon start resumes from it.
   - A page with GraphQL `errors` is never partly applied (the transport never
     returns its `data`, `transport.ex:664-668`).
7. `lib/aiur.ex`: add the child right after the C4-T01 `History` child, behind
   the app-env gate. `config/config.exs` `:test` block: set
   `:build_history_backfill_enabled?` to `false`, next to `:66`.
8. Docs: `website/docs-app/apis/github.md`, after the "What Aiur polls" table
   (`:19-25`), one paragraph: "Once per repository, the daemon reads every issue
   for the build history (caller `build_order_history_backfill`, about 3 points
   per 100 issues, paced, held below 20 % remaining, at most 300 points an hour).
   It is a one-time read, not a poll. It resumes after a restart and does not
   run again once complete." No config or CLI page changes (no new key or flag).
9. **Measure** (AGENTS.md "A claimed saving must be measured"; this is a cost,
   not a saving, but the same evidence applies). On the dev daemon for
   aiur-team/aiur, after the run completes:
   - read `points`, `pages` and `issues` from `History.checkpoint(:backfill)`;
   - read the `build_order_history_backfill` row of `aiur github-cost`
     (`SOURCE` must be `reported`);
   - record the repository's `issues.totalCount` from the last page.

   The PR body states: "N issues, P pages, X GraphQL points (reported), measured
   <date> on aiur-team/aiur; prediction was 3 points per page." If X is more
   than 5 points per page, stop and report before merge: the cost model in this
   ticket is wrong.

## Non-happy paths

| # | Concrete input | Expected behaviour | Test |
| --- | --- | --- | --- |
| N1 | Daemon restarts after page 2 of 3 (store checkpoint `cursor: "c2"`, `status: "running"`) | First request after boot carries `cursor: "c2"`; pages 1-2 are not fetched again (EC-31) | T3 |
| N2 | Daemon killed after `apply` of page 2, before C4-T01's debounced flush | Rows and checkpoint of page 2 are both lost (one write); page 2 is fetched again; the second apply leaves no duplicate list items | T4 |
| N3 | Store `complete?: true`, checkpoint `status: "complete"`, `query_version: 1` | Zero requests at boot; status `:complete` | T5 |
| N4 | Page returns `{:error, {:aiur, :locally_held, %{reset_at: now+4s}}, nil}` | Status `{:held, %{until: now+4s}}`; no request before then; next request uses the same cursor (EC-32) | T6 |
| N5 | HTTP 403 with `x-ratelimit-remaining: 0`, `x-ratelimit-reset` in 20 min | Held until that time; checkpoint unchanged; never `:failed` | T7 |
| N6 | Page 1 reports `remaining: 900, limit: 5000` | Page 2 is scheduled at `resetAt`, not after 10 s | T8 |
| N7 | 300 points spent in the last 60 min | Next page held until the oldest spend leaves the window | T9 |
| N8 | HTTP 401 | Status `:failed`, exactly one request, no timer | T10 |
| N9 | HTTP 200 with `errors` and partial `data` (unclassified → `:graphql_partial`) | Nothing applied; retried 3 times; then `:failed` | T11 |
| N10 | Store failure `:repository_mismatch` (or `:version_unsupported`, `:state_dir_unavailable`, not running) | Zero requests; status `{:waiting_for_history, %{reason: …}}`; never `:complete` | T12 |
| N11 | Store failure `:history_corrupt` or `:history_rebuilding` (C4-T01 cleared the checkpoint) | Run starts at `cursor: nil`; after the last page, `mark_complete` makes the store available | T13 |
| N12 | `tracker_kind` is `"linear"`; or `configured_repo` errors; or `token_fun` errors | Zero requests; `:not_applicable` or `{:unavailable, %{reason}}` | T14 |
| N13 | Checkpoint `query_version: 0` | Ignored; run starts at `cursor: nil` | T15 |
| N14 | An issue's timeline has `hasNextPage: true` and no merged PR in its first 100 items | Event has `timeline_complete: false` and no `merged_at` key (unknown, not `:none`); no extra request | T16 |
| N15 | `label_prefix` is `aiur`; events `agent:in-progress` at 09:00 and `aiur:in-progress` at 10:00 | `in_progress_at` = 10:00 (only the configured prefix counts) | T17 |
| N16 | History holds row #7 written by a webhook event with `observed_at` 12:00; the backfill applies an event for #7 with `observed_at` 11:00, the same `updated_at` and a different title | The 12:00 title stays (C4-T01 rule 2) | T18 |
| N17 | `blockedBy` node in `other-org/lib` #5; closed by merged PR #40 at 15:00 | `blocked_by: [%{owner: "other-org", repository: "lib", number: 5}]`; `merged_at` 15:00, `pr_number` 40 | T19 |
| N18 | A new issue is opened while page 2 of 3 is in flight (`totalCount` 6 → 7) | Run continues; status `:complete` | T20 |
| N19 | The process is not running | `status/0` returns `{:unavailable, %{reason: :backfill_not_running}}` | T21 |
| N20 | `History.apply/2` returns `{:error, :history_unsafe_path}` (symlink at the store path) | `:failed`, no timer, no further requests (no 3-points-a-minute loop) | T22 |
| N21 | The supervisor restarts the process while a page is in flight | The in-flight request dies with its guardian (`transport.ex:250-306`); the new process resumes from the store checkpoint; at most one page is paid twice | covered by T3 and T4 |
| N22 | Issue #9 has 130 blockers (`blockedBy.pageInfo.hasNextPage: true`) | Page event has 100 blockers and `blocked_by_complete: false`; one follow-up request; then 130 blockers and `blocked_by_complete: true` | T23 |

Security and privacy: the job uses the daemon's credential through the normal
`default_request_fun/1` path. No agent can start, pause or read it. Titles and
actor logins are stored as data (logins are already public on the issue). No
body text is stored. The checkpoint holds an opaque GitHub cursor and counts.

## Compatibility and rollout

- No config key, no CLI flag, no new file. The checkpoint lives in C4-T01's
  `history.json`; the row fields are in its version 1, so no version bump.
- **First boot after upgrade:** one paced run of about 42-45 points for
  aiur-team/aiur, starting 60 s after boot. Later boots: zero requests.
- **Rollback:** a release without this ticket leaves the `backfill` checkpoint
  unread. Rows from the backfill stay.
- **Several Aiur instances on one repository:** each has its own
  `decision_state_dir`, so each runs its own backfill once. Two instances on a
  shared credential spend about 90 points once. Accepted.

## Pixel parity

Not applicable to this ticket: it renders nothing, and the C1-T02 side-by-side
harness has no element to compare. The design has no "history incomplete"
state; the visible state is C9-T13's S-9 default (`.bd-mk.empty`,
`design-source/assets/build.css`), and its parity check belongs to C9-T13. This
ticket's obligation is only the contract in "Status read": any status except
`:complete` must reach the client as "incomplete", so C9-T13's screenshot
fixture can include it.

## Verification

All tests use an isolated HOME, a temp C4-T01 store (`state_dir` under
`tmp_root!/1`, test server name) and never read `~/.aiur` (AGENTS.md "Reading
real state"). The store is the real C4-T01 process, not a double, so the merge
and checkpoint behaviour is the shipped one. Stub `request_fun` returns queued
pages from fixtures built on the census shape (three pages of 2 issues each,
one root with a `SubIssueAddedEvent`, one cross-repo blocker, one timeline with
`hasNextPage: true`). Clock and scheduling are injected (`now_fun`,
`schedule_fun` records `{delay, msg}`); no test sleeps.

PROPOSED `test/aiur/build_order/history/backfill_query_test.exs` and
`test/aiur/build_order/history/backfill_test.exs`:

| Test | Expected | Fails without |
| --- | --- | --- |
| T1 "query is billed to its own caller" | every stub request has `caller: "build_order_history_backfill"` | the `request.ex` `caller/1` clause (falls back to `"build_order_graph"`) |
| T2 "fresh run walks all pages and records reported cost" | 3 requests with cursors `nil, "c1", "c2"`; checkpoint `status: "complete"`, `points: 8` (fixture costs 3+3+2); `History.health` `complete?: true`; `status/0` `:complete` | the cursor advance, the cost sum, or the `mark_complete` call |
| T3 "restart resumes from the checkpoint" | store seeded with checkpoint `cursor: "c2"`; the first request has `cursor: "c2"`; total requests 1 | reading `History.checkpoint(:backfill)` at check |
| T4 "re-fetching a page adds no duplicate list items" | apply page 2 twice (second time with a later `observed_at`): row fields equal except `observed_at`; `label_events` and `sub_issues_added` lengths unchanged | the `sub_issues_added` union-dedupe rule added to `Row` |
| T5 "complete store makes zero requests" | `request_fun` that flunks is never called | the complete check |
| T6 "local hold waits until reset_at" | `{:aiur, :locally_held, %{reset_at: now+4s}}` → `schedule_fun` delay 4_000; status `{:held, _}`; next request same cursor | the raw-hold branch (it would fall to the backoff or `:failed`) |
| T7 "rate limit holds, never fails" | 403 + `x-ratelimit-remaining: 0`, reset in 20 min → delay 1_200_000; status `{:held, %{reason: :rate_limited}}`; checkpoint unchanged | the `:rate_limited` branch and the ISO parse |
| T8 "low remaining holds until resetAt" | page 1 `remaining: 900, limit: 5000` → delay = `resetAt - now`, not 10_000 | the reserve check |
| T9 "hourly cap holds" | fixture pages report `cost: 150`; after 2 pages within 60 min the third is scheduled at first-spend + 60 min | the cap |
| T10 "permanent error fails once" | 401 → 1 request total, status `{:failed, %{reason: _}}`, no schedule | the permanent branch (would loop) |
| T11 "partial GraphQL pages are retried, then fail" | 200 with `errors` + `data` → nothing applied; 4 requests (1 + 3 retries); then `:failed` | the `:graphql_partial` retry clause (would fail after 1 request) |
| T12 "a store that refuses writes blocks the run" | store started with a mismatched `repository` → 0 requests; status `{:waiting_for_history, %{reason: :repository_mismatch}}`; **mutation:** replace the branch with `:complete` → test fails | the waiting branch |
| T13 "a corrupt store is rebuilt, not waited on" | store file `{not json` → requests start at `cursor: nil`; after the last page `History.health` is `:healthy, complete?: true` | running in the corrupt/rebuilding state (a "wait while unavailable" rule deadlocks: 0 requests, store never available) |
| T14 "not GitHub / no repo / no token" | 0 requests; `:not_applicable`, `{:unavailable, %{reason: :missing_configured_repository}}`, `{:unavailable, %{reason: :missing_github_token}}` (via `token_fun`) | the init guards |
| T15 "old query_version is ignored" | checkpoint `query_version: 0`, `cursor: "c2"` → first request `cursor: nil` | the version check |
| T16 "an incomplete timeline is marked and claims nothing" | event `timeline_complete: false`; no `merged_at` key; 0 extra requests | the flag and the omit rule (would write `:none`, which claims "never merged") |
| T17 "only the configured prefix sets in_progress_at" | `in_progress_at` = 10:00 | prefix matching (would pick 09:00) |
| T18 "a newer stored row is not overwritten" | title from the 12:00 event remains | using the page receive time as `observed_at` (a fixed or epoch `observed_at` passes; a "now at apply" one written after the webhook fails) |
| T19 "normalizer keeps cross-repo blockers, the closing PR and the actor" | exact event maps for N17, and a `label_events` item with `actor: "kev"` | the normalizer fields |
| T20 "a growing totalCount does not fail the run" | 3 pages, `totalCount` 6 then 7; status `:complete` | not reusing `Pager` (would be `:pagination_mismatch`) |
| T21 "status of a dead process is unavailable" | `{:unavailable, %{reason: :backfill_not_running}}`; **mutation:** return `:complete` from the fallback → test fails | the fallback clause |
| T22 "a refused write stops the job" | `apply` returns `{:error, :history_unsafe_path}` → 1 request, `:failed`, no schedule | the apply-error branch (would retry every minute) |
| T23 "blockedBy overflow is paged" | N22 fixture → `blocked_by_complete: false` after the page, then 130 refs and `true` after the follow-up, billed to `build_order_history_backfill` | the follow-up (without it the row stays `false` with 100 refs) |

T18 note: C4-T01 owns the merge rule; this test guards this ticket's choice of
`observed_at`, so its fixture applies the webhook event first and the backfill
event second with the page's earlier receive time.

Mutation check (AGENTS.md "Tests must fail without the production change"): in a
worktree, revert each production hunk named in "Fails without", run its test,
confirm it fails, restore, confirm it passes. `git status --porcelain` must show
only the intended revert. Report each result and the exact command in the PR
body.

Command:

```bash
env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- mix test \
  test/aiur/build_order/history/backfill_query_test.exs \
  test/aiur/build_order/history/backfill_test.exs \
  test/aiur/build_order/history_test.exs \
  test/aiur/build_order/github_graph_test.exs
```

(`history_test.exs` is C4-T01's suite; it must stay green with the new row
fields.) Then CI green on the head SHA (the narrow run hides supervision bugs).

Manual check (not a TUI feature, so the AGENTS.md TUI recipe does not apply):
on the dev daemon, after `aiurdev restart`, watch `Backfill.status/0` (through
the control RPC) go from `:running` to `:complete`, confirm `aiur github-cost`
shows the `build_order_history_backfill` row with `SOURCE reported`, and
restart once more to confirm zero new points for that caller.

## Completion and handoff

- [ ] T1-T23 pass and each fails with its production hunk reverted.
- [ ] C4-T01's suite stays green.
- [ ] Measured cost in the PR body: issues, pages, reported points, date
      (step 9). Stop if more than 5 points per page.
- [ ] `apis/github.md` paragraph added (step 8).
- [ ] A second restart spends zero points on this caller.
- [ ] `status/0` never returns `:complete` before the last page is applied,
      `mark_complete/1` returned `:ok` and the store was flushed.
- **Dependents:** C4-T04 (reads `in_progress_at`, `merged_at`, `closed_at`;
  replaces the interim `put_signals/2` with `Timing.merge/3`), C4-T05 (reads `blocked_by`,
  `blocked_by_complete`, `parent`, `complete?`), C6-T02 (reads `label_events`
  with `actor`), C6-T03 (reads `sub_issues_added`), C8-T04 / C9-T13 (render
  `status/0`), C4-T03 (reads `started_at` from the `backfill` checkpoint).
- **Sources:** baseline.md §4, §4.1, §4.2 (`:340-375`); plan.md §8 EC-31,
  EC-32, §9 K-4; C4-T01 §4.1-§4.4, §6; C4-T03 "Contract with C4-T01";
  C4-T04 "Interface notes"; C6-T02 return note; C6-T03 interface item 3;
  `website/docs-app/apis/github.md`; the files cited above.

### Interface mismatches found with neighbour rows

1. **README row reason is wrong.** The agent `gh` wrapper does not refuse GraphQL
   (`apis/github.md:565` sends it to GitHub unshared). The job is still
   daemon-owned, for the reasons in "Verified starting point".
2. **Cost figure.** plan.md:131 and §9 K-4 and decisions.md E8-D10 say "about 30
   points". The combined query is predicted at about 42-45 points (3 per page).
   The README title already says 30-45. Step 9 settles it.
3. **Write coalescing** is in this row, but C4-T01 owns the debounced flush. This
   ticket writes once per page (one `apply/2` per 10 s at most) and keeps
   C4-T01's 2 s default. Coalescing of C4-T03's event-rate writes belongs to
   C4-T01 or C4-T03.
4. **C4-T01 row shape.** Settled 2026-10-08: C4-T01's version-1 row has the
   `%{owner, repository, number}` refs and every field this ticket writes.
5. **C6-T03** Settled 2026-10-08: `sub_issues_added` items are `%{ref, at}`
   with `ref = %{owner, repository, number}`; C6-T03 compares with
   `Bounded.same_repository?/2`.
6. **C13-T01** exports "body excerpt and PR files per ticket from the History
   store" with "no new GitHub reads". This ticket stores neither (bodies would
   grow the store far past C4-T01's 0.4 MB, and PR files need another
   connection per issue). C13-T01 must either read them itself (and C13-T00
   measures that cost) or the scope drops them (C13-T00 M-1 records the same).
7. **C8-T04** now lists C4-T02 in `blocked_by` (its line 8) and reads
   `Backfill.status/0`. Its line 576 note about `History.status/0` is obsolete:
   C4-T01 exposes `health/1`, and this ticket no longer cites `History.status/0`.
8. **C4-T03 watermark.** Settled 2026-10-08: C4-T03's floor is
   `:backfill.started_at` (kept across resumes); its watermark is its own
   `:closed_since` checkpoint.
9. **C4-T03 merge guard.** Settled 2026-10-08: C4-T01 orders G fields by
   `updated_at` (rule 6); this ticket reads `updatedAt` (no point cost).
10. **C4-T04** Settled 2026-10-08: `in_progress_at` is in C4-T01 version 1
    (earliest wins); C4-T04 replaces the interim `put_signals/2` with
    `Timing.merge/3`.

## Decisions made without the owner

1. **One combined query; the only follow-up is `blockedBy` overflow.** Label
   and timeline overflow is recorded as a `*_complete: false` flag instead of
   extra pages, and "latest wins" fields are left unknown when the timeline is
   incomplete. Expected affected rows: zero (longest timeline 51 of 100).
2. **One extra timeline item type** (`SUB_ISSUE_ADDED_EVENT`) beyond the row's
   four, and `actor { login }` on label events. Same connection, no extra
   points. `REOPENED_EVENT` is not read: no successor uses it.
3. **Only `<prefix>:in-progress` and `feature:*` label events are kept.** Other
   label events are dropped to keep the store small; no consumer reads them.
4. **Pacing values** (60 s start delay, 10 s per page, hold below 20 %
   remaining, 300 points per hour, 3 retries) are module attributes, not config.
   Kevin can ask for a key later; nobody asked for one now.
5. **The checkpoint lives in the History file** (C4-T01's `checkpoint:` option),
   not in a separate state file. One write holds rows and cursor, so they
   cannot disagree, and a corrupt store resets both.
6. **A permanent error stops the job until the next daemon start.** No retry
   loop, no new alert type; the reason is in `status/0`.
7. **The repository is `GitHub.Config.configured_repo/0`** (explicit, else
   `origin`), the same source as the store's `repository`. The store's
   `:repository_mismatch` check then protects the backfill. (The earlier draft
   used `explicit_configured_repo/0`; with an `origin`-only setup that would
   leave history incomplete forever while the store itself runs.)
8. **The backfill never starts from a page view or a CLI call.** Only the
   daemon starts it (`apis/github.md:294`: page views cost nothing).
9. **`:graphql_partial` is retried** (3 times) although
   `Errors.retryable_github_error?/1` says false, because a heavy nested page can
   fail partially on a GitHub timeout. The retry is bounded and spends at most
   about 9 points.
10. **A write the store refuses is `:failed`, not a wait.** Waiting would re-fetch
    the same page every minute at 3 points each.

Residual risk: a checkpoint cursor that GitHub no longer accepts (for example,
after weeks of downtime) fails the job permanently at every start. The PR should
check whether GitHub returns a classified error for a stale cursor; if so, map
it to "restart from cursor nil" once.

## Review log

Adversarial review, 2026-10-08, against `58854d4c8` sources and neighbour tickets.

1. Replaced the invented `History.apply_rows/2` / `History.status/0` /
   `build_history_state_dir` usage with C4-T01's real interface
   (`apply/2` events with `checkpoint:`, `health/1`, `checkpoint/2`,
   `mark_complete/1`, `flush/1`). Removed the separate `backfill.json` and its
   corrupt/foreign-file branches; the old N2 "crash between apply and
   checkpoint" case no longer exists.
2. Fixed a deadlock: the draft waited while History was unavailable, but C4-T01
   stays unavailable after a corrupt file until this ticket calls
   `mark_complete/1`. Corrupt/rebuilding now runs from page 1 (new T13); only
   write-refusing states wait (T12).
3. Fixed the local-hold shape: GraphQL holds arrive raw as
   `{:aiur, :locally_held, %{reset_at}}` (`transport.ex:647`), not
   `{:github, :local_hold, %{hold: …}}`; dropped `LocalHold.wait_ms/2` (real
   clock, `:no_wait` past 60 s).
4. Fixed GraphQL error handling: a 200 with `errors` is `:graphql_partial` or a
   classified tuple (`graphql_errors.ex:6-12`), not retryable by
   `Errors.retryable_github_error?/1`; made the retry an explicit decision (9)
   and fixed T11. `reset_at` from a status error is an ISO string; added parsing.
5. Added `:token_fun` injection: `require_token/1` returns a test token whenever
   `:request_fun` is set (`transport.ex:85-88`), so the old T13 "no token" case
   could not fail.
6. Aligned row fields with C4-T01: `lifecycle` (incl. `:duplicate`), sentinels,
   `label_events` (with `actor`, for C6-T02) instead of `feature_label_events`,
   ref shape `%{owner, repository, number}`; dropped `reopened_at`,
   `REOPENED_EVENT`, `updatedAt` and `put_signals/2` (no reader); the newer-row
   rule is C4-T01's `observed_at`, not `updated_at`. Listed the five row fields
   this ticket must add because C4-T01 rejects unknown keys.
7. `merged_at`/`pr_number` are now left unknown, not `:none`, when the timeline is
   incomplete (T16).
8. Repository source changed to `configured_repo/0` to match the store
   (decision 7).
9. Fixed citations: `pager.ex` `remember_total/2` is at `:54-56, 72-74` (not
   `:148-150`); supervision placement and gate pattern are `aiur.ex:452-453` and
   `config.exs:66` (the `History` child sits before `:452`, not near `:375`);
   `graphql_cost.ex` estimate is 301 points; `resource_store.ex:264`; S-9 is
   `DESIGN-E8.md:109`. Added `read_cache/policy.ex:273-286` (do not add the
   caller) and `ad_hoc_source.ex:98-103`.
10. Scoped the "`first: 100` costs the same" claim to leaf connections, with the
    `reviewThreads` counter-example, and tied the 3-points prediction to the
    measured 1-point census pages.
11. Fixed vacuous or unreachable tests: T4 (re-fetch has a new `observed_at`, so
    "byte-identical" was false), T9 (3-page fixture could not reach 300 points),
    T18 (now guards this ticket's `observed_at` choice); added T22 (refused
    write) and C4-T01's suite to the command.
12. Interface notes: added C4-T03 watermark and merge-guard items, C4-T04
    `in_progress_at` ordering, C6-T02 actor, C6-T03 ref shape; updated C8-T04
    (it now lists C4-T02).
- Reconciliation 2026-10-08 (coordinator): row fields now come from C4-T01 v1 (no row.ex change, no version bump); `sub_issues_added` written as `%{ref, at}`; added `id`/`updatedAt` to the query and `node_id`, `updated_at`, `last_closed_at` to the events; `blockedBy` overflow paged with `blocked_by_complete: false` until done (N22, T23); interim `put_signals/2` replaced by C4-T04 `Timing.merge/3`; merge-rule summary per C4-T01; settled interface items 4, 5, 8, 9, 10.
