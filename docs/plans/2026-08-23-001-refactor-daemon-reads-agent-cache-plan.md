---
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
product_contract_source: ce-plan-bootstrap
plan_type: refactor
---

# Plan: Let the daemon serve issue reads from the agent `gh` cache

## Goal Capsule

The agent-side `state-cache` holds 619 `gh`-stdout bodies the daemon re-fetches
from GitHub. The byte representation cannot be shared between the two stores
(document, don't re-derive: `Aiur.GitHub.AgentCache` explains why replaying a
stored REST body as `gh` stdout would be imitation), so the ownership answer is
**two stores with a documented sync joined by resource identity**. What is
missing today is the direction this ticket names: the daemon **reading** the
agent cache for the number-addressed resources it would otherwise fetch.

This change makes the daemon's single-issue reads (`GET /repos/{o}/{r}/issues/{n}`,
the read behind the Build Order ticket-detail page and the per-cycle poll) consult
the agent cache on a store miss, serve a validated agent-fetched body with **no
upstream request**, deposit it into `ResourceStore` so the win is durable, and
count each serve so the reduction is measured. Every doubt fails open to today's
behavior.

## Problem Frame

Three caches hold overlapping GitHub state and none reads the others (measured
on the running system):

| store | location | contents | read by |
| --- | --- | --- | --- |
| agent guard state-cache | `~/.aiur/github-budget/state-cache` | 12 MB, 619 `gh` response bodies | agents only |
| daemon ReadCache | in-VM, TTL body cache | classified reads | daemon only |
| daemon ResourceStore | ETag/identity-aware | `:issue`, `:issue_labels`, `:issue_comment`, … | pollers |

`Aiur.GitHub.AgentCache` and `Aiur.GitHub.AgentCacheBridge` already make the
agent store's **invalidation** flow out of `ResourceStore` changes (a delivery
retires the agents' copies). The **read** direction does not exist: when the
daemon needs `GET /repos/{o}/{r}/issues/{n}` and its own store is cold, it pays
for a fetch even when an agent fetched the same issue minutes earlier and the
body is already on disk in a form the daemon can parse.

The byte mismatch is real and documented: the wrapper stores `gh` stdout, and
most of it is a projection (`gh issue view --json … -q …`) that is not the REST
body. But the wrapper also stores **raw `gh api` reads** (`gh api
repos/o/r/issues/1670`), whose stdout IS the REST issue body (modulo Go's JSON
escaping, which `Jason.decode/1` already undoes). Those entries are
number-addressed under `state-cache/v1/<owner>/<repo>/issue/<id>/`, the exact
directory `Aiur.GitHub.AgentCache.resource_dir/2` already resolves from a
`ResourceStore` key. That is the seam this plan uses.

## Scope Boundaries

### In scope

- A daemon read of the agent cache for **number-addressed `:issue` resources**
  (`state-cache/v1/<owner>/<repo>/issue/<id>/`), with shape validation, marker
  freshness, and fail-open.
- Integration into the two single-issue daemon reads that overlap with agent
  activity: `Aiur.GitHub.Issues.fetch_issue_raw_conditional/2` (Build Order
  ticket-detail) and the per-cycle poll path in `Aiur.GitHub.Issues`.
- A measured counter of daemon reads served from the agent cache, surfaced on the
  GitHub cache page.
- The ownership decision written down where a future reader will find it
  (`Aiur.GitHub.AgentCache` moduledoc) plus the TTL-backstop justification.
- Tests for every serve/miss path and for "no upstream request on an
  agent-cache serve".

### Out of scope / deferred to follow-up

- **Byte-level unification of the stores.** Not possible; the wrapper must answer
  `gh` stdout and a REST body is a different artifact (imitation). The design is
  two stores with a documented sync — this is a decision, not a gap.
- **Lengthening or removing the TTL in favour of delivery-driven retirement.**
  Gated on #2331's recovery defects being fixed (the ticket says so explicitly:
  delivery-driven invalidation with a broken gap-recovery path is worse than a
  timer). This plan only adds a **conservative timer backstop** with a stated
  justification, and notes the gating.
- **Collection reads** (`GET /repos/{o}/{r}/issues?state=open`, `/pulls?state=open`,
  `/issues?labels=…`). The wrapper files these under `kind=api` keyed by an
  endpoint digest, not by resource identity, and their bodies are harder to
  validate (paginated lists, `gh issue list` projections). The identity path this
  plan uses (`resource_dir/2`) deliberately does not resolve them. Deferred.
- **Pull request reads.** The daemon's single-PR reads are strict decision paths
  (`ResourceFetch.decision/0`) that must not be served from a cache.
- **#2331's gap-recovery and event-sourcing work.** Separate PR, still blocked.

## Key Technical Decisions

### KTD1 — Two stores with a documented sync (the ownership answer)

The stores keep their distinct byte representations; they are one **identity**,
not one table. `Aiur.GitHub.AgentCache.resource_dir/2` is the single join, and
delivery/mutation invalidation flows to both (`AgentCacheBridge`). This plan
adds the one missing direction: the daemon reads the agent cache. The "three
stores with no relationship" state the ticket rejects becomes "two stores with a
documented, bidirectional sync plus the in-memory ReadCache".

### KTD2 — Serve only validated raw `gh api` bodies, found by identity

For a `ResourceStore` key, resolve the agent directory with `resource_dir/2`,
enumerate `*.body`/`*.meta` shapes in it, and accept only a body that parses as
JSON **and** validates as the full REST resource for that number (a map whose
`"number"` equals the resource id and whose `"url"` is the expected API URL).
Projected `gh` shapes (`gh issue view --json …`) fail validation and are
skipped. Any doubt returns `:miss` and the caller fetches exactly as it does
today.

### KTD3 — Freshness is the caller's tolerance applied to the agent's fetch stamp, bounded by a named backstop timer

The daemon cannot know the agent's configured TTL, and delivery-driven
retirement without #2331's gap recovery is not yet safe. So:

- the agent entry's `fetched_at_ms` (meta line 1) is compared against the
  caller's own staleness tolerance where one exists (the ticket-detail
  `freshness_ms`), so the daemon never serves a caller state older than the
  caller said it could live with;
- an absolute backstop timer (a real clock, named and justified) is the ceiling
  for the poll path and for any caller without a tolerance;
- the entry is rejected when stamped in the future, when older than the backstop,
  or when any covering invalidation marker (`$root/v1/.invalidated`,
  `$repo/.invalidated`, `$entry/.invalidated`) is newer than its fetch stamp —
  the same marker test the wrapper applies.

The TTL-as-backstop value is written next to the constant with its justification
rather than assumed.

### KTD4 — Every serve is counted; every doubt fails open

A served read increments a daemon-side counter exposed on the cache page; that
counter is the "measured reduction in duplicate URL fetches" (each serve is a
fetch that did not happen). An unreadable/absent/unparseable/invalidated entry,
an unwritable store, a missing root, or a decode failure all return `:miss` and
the caller spends exactly as it would have — a failed cache costs throughput,
never correctness.

## High-Level Technical Design

The read path, one resource:

```text
Issues.fetch_issue_raw_conditional(n) / poll fetch_conditional_issue(n)
  └─ ResourceStore.fetch(:issue, o, r, n) ── hit ──> serve (unchanged)
  └─ miss → AgentCache.read_body(key)
        ├─ resource_dir(key) → nil (collection/non-addressable) ──> :miss
        ├─ enumerate <dir>/*.meta + *.body
        │    ├─ meta: fetched_at_ms, reject if future / older than backstop
        │    │        or any covering marker >= fetched_at
        │    ├─ body: Jason.decode, validate number+url match the key
        │    └─ first valid shape wins (freshest first)
        ├─ {:ok, body} → put_issue_resource(key, body, nil, :agent)
        │                → serve; counter++
        └─ :miss → existing conditional fetch (unchanged)
```

Directional only: the real `Issues` code keeps its 304/retry/regression
handling; the agent-cache consult is a new branch that fires only where the
store would otherwise be consulted for a miss.

## Implementation Units

### U1. `AgentCache.read_body/1` — the daemon read of one number-addressed resource

**Goal:** One function that turns a `ResourceStore` key into a validated,
fresh agent-cache body or `:miss`, used by both daemon read paths.

**Files:**
- `src/lib/aiur/github/agent_cache.ex` (add `read_body/2` + helpers)
- `src/test/aiur/github/agent_cache_test.exs` (extend)

**Approach:**
- Resolve the entry directory with the existing `resource_dir/2`; `nil` → `:miss`.
- Enumerate `*.body` files; for each, read its sibling `.meta` (line 1 =
  fetched-at epoch seconds, line 2+ = optional ETag — not needed for serving).
- Freshness: reject future stamps; reject `now - fetched_at > backstop_ms`
  (named constant with justification); reject when the covering markers
  (`$root/v1/.invalidated`, `$repo_dir/.invalidated`, `$entry_dir/.invalidated`)
  hold a value `>=` the fetched-at seconds.
- Decode and validate: parse JSON, then require the shape the resource type
  demands. For `:issue` (and `:pull_request`), a map with `"number"` equal to
  the key's id and `"url"` matching `https://api.github.com/repos/{owner}/{repo}/issues/{id}`.
  Anything else is skipped in favour of the next shape; nothing valid → `:miss`.
- Never raise: wrap filesystem reads/decode in rescue so a torn or corrupt
  entry is a `:miss`.
- `opts` accept a `state_dir` test seam like the rest of `AgentCache`.

**Patterns to follow:** the wrapper's `cache_lookup` freshness/marker rules in
`src/priv/github_quota_guard.sh`; `AgentCache.resource_dir/2` and `mark/2`
naming; `AgentCache`'s existing fail-open `:ok` style.

**Test scenarios:**
- A `gh api`-style raw issue body (a full REST issue map with `number`/`url`) in
  the entry directory, fresh and unmarked, decodes and is served.
- A projected `gh issue view --json body -q .body` shape (e.g. `{"body": "..."}`)
  in the same directory fails validation and the next valid shape (or `:miss`)
  wins.
- A body whose `"number"` differs from the key's id is rejected.
- An entry whose `fetched_at` is in the future is a miss.
- An entry older than the backstop is a miss.
- A `.invalidated` marker newer than `fetched_at` (root, repo, or entry) makes it
  a miss; an older marker does not.
- Multiple shapes: the freshest valid one is chosen.
- A non-JSON or torn (missing body) entry is skipped, not raised.
- A collection / non-addressable key (e.g. `:branch_pull_request_listing`)
  returns `:miss`.
- A missing/unwritable store root returns `:miss` (fail open).

**Verification:** the module tests pass and each serve/miss reason has a named
case; the freshness and marker rules mirror the wrapper's `cache_lookup`.

### U2. Serve the Build Order ticket-detail read from the agent cache

**Goal:** `Issues.fetch_issue_raw_conditional/2` stops re-fetching an issue an
agent recently fetched.

**Files:**
- `src/lib/aiur/github/issues.ex` (add the agent-cache branch + `:agent` deposit
  source handling)
- `src/lib/aiur/github/resource_store.ex` (add `"agent"` to
  `known_source_atom/1` if the deposit uses `source: :agent`)
- `src/test/aiur/github/issues_test.exs` (or the file covering
  `fetch_issue_raw_conditional`)

**Approach:**
- In `fetch_issue_raw_conditional/2`, when `stored_issue/2` answers `nil`, consult
  `AgentCache.read_body(key)` before `revalidate_raw_issue/…`.
- On `{:ok, body}`: deposit with the same `put_issue_resource` guard (regression
  check against a newer webhook body), serve `{:ok, body, :fresh}`, and count.
  The existing 304/retry/`freshness_ms` machinery is untouched.
- The deposit records the writer as `:agent` (a new known source) so the cache
  inspector can attribute it; this requires teaching `ResourceStore`'s decode to
  recognise the `"agent"` source string.
- Decide during implementation whether the third tuple element stays `:fresh`
  (measure via the counter) or gains `:agent` (honest outcome) — check every
  caller of `fetch_issue_raw_conditional/2` for a pattern match on that element
  before changing the union.

**Patterns to follow:** `put_issue_resource/4` and `regression?/2` in
`issues.ex`; `known_source_atom/1` in `resource_store.ex`.

**Test scenarios:**
- Store cold, agent cache holds a fresh valid issue → the read serves it with
  **zero upstream requests**, the store now holds it, and the counter increments.
- Store cold, agent cache empty → behavior unchanged (one upstream request).
- Store cold, agent cache entry invalidated → behavior unchanged.
- The deposited body respects the regression guard: a newer webhook body already
  in the store is not overwritten.
- `:revalidate` (operator's explicit refresh) bypasses the agent cache exactly as
  it bypasses the store.

**Verification:** a request-counting test proves the agent-cache serve spends
nothing; the regression test proves the deposit does not roll state back.

### U3. Serve the per-cycle poll read from the agent cache

**Goal:** the dispatch poll stops spending the cold-case request for an issue an
agent fetched.

**Files:**
- `src/lib/aiur/github/issues.ex` (the `fetch_conditional_issue/…`/poll path)
- `src/test/aiur/github/issues_test.exs`

**Approach:**
- In `fetch_conditional_issue/…`, when the poll's own per-cycle cache has no
  entry and the store offers no validator (the cold case that would otherwise
  spend a full `200`), consult `AgentCache.read_body(store_key)` under the
  backstop ceiling.
- On `{:ok, body}`: normalize + authorize exactly as a `200` would, deposit via
  `put_issue_resource(…, :agent)`, and continue without an upstream request.
- The 404/error/304 paths are untouched; the agent-cache branch is a miss that
  falls through to today's `conditional_get`.

**Patterns to follow:** `normalize_issue/…`, `authorize_issue/…`,
`put_issue_resource/4` in `issues.ex`.

**Test scenarios:**
- Poll cache empty, store cold, fresh valid agent issue → the issue is served
  with **zero upstream requests**, normalized and authorized, and the counter
  increments.
- Poll cache empty, store cold, agent cache miss → exactly one upstream request
  (unchanged).
- A 404 and an HTTP error still halt the poll exactly as before.
- An agent-served issue is not marked `processed` (fetching is not acting) — same
  as today's poll deposit.

**Verification:** request-counting test for the serve; the existing poll tests
for error paths still pass.

### U4. Measure and surface the reduction

**Goal:** the avoided duplicate fetches are a counted fact, visible on the cache
page.

**Files:**
- `src/lib/aiur/github/agent_cache.ex` (counter + `daemon_served_reads/0`)
- `src/lib/aiur_web/live/github_cache_live.ex` (surface the figure)
- `src/test/aiur_web/live/github_cache_live_test.exs` (or the agent-cache page
  test)
- `website/docs-app/guide/executor-control-center.md` (correct the page's
  description if a panel gains the figure and the page would otherwise be wrong)

**Approach:**
- A monotonically counted integer in `AgentCache` (`:atomics` or a `:counters`
  ETS table) incremented exactly once per `read_body/2` serve, exposed as
  `AgentCache.daemon_served_reads/0`.
- Render the figure on the GitHub cache page's agent-cache panel, alongside the
  existing agent effectiveness numbers, labelled so it reads as "daemon reads
  served from the agent store" (each is a fetch that did not happen).
- Keep the page strictly view-only; the counter is read, never written, from the
  page.

**Patterns to follow:** `Aiur.GitHub.ReadCache.Metrics` and
`AgentCacheMetrics` for counter/snapshot shapes; the cache page's existing agent
panel.

**Test scenarios:**
- Serving one agent-cache read increments the counter by one; a miss does not.
- The page's snapshot exposes the figure.
- A reset test seam clears it for determinism.

**Verification:** a test asserts counter deltas match serves; the page renders the
figure.

### U5. Write the ownership decision and TTL backstop into the code

**Goal:** a future reader can find why there are two stores and why the daemon
reads the agent cache under a timer backstop.

**Files:**
- `src/lib/aiur/github/agent_cache.ex` (moduledoc: the read direction, the
  ownership decision, the validation, the fail-open, the backstop justification)
- `src/lib/aiur/github/agent_cache_bridge.ex` (moduledoc: the sync is now
  bidirectional — invalidation out, reads in)
- `docs/plans/2026-08-23-001-refactor-daemon-reads-agent-cache-plan.md` (this
  plan, referenced from the moduledoc)

**Approach:**
- Extend the `AgentCache` moduledoc with a "What this module is for" section on
  the read side: two stores with a documented sync, the byte-mismatch reason,
  the identity join, the validation rule, and the backstop-timer justification
  with the explicit note that lengthening it delivery-driven is gated on #2331.
- No `website/docs-app/` config/CLI page changes are needed unless U4 surfaces a
  new user-facing figure that makes an existing guide page wrong — handle there.

**Test expectation:** none — documentation only; the claim "the moduledoc says
X" is verified by reading it in review.

## Risks & Dependencies

- **Serving agent-written bytes to daemon readers.** The wrapper already runs
  agents on one OS-user trust boundary (an agent can plant a response other
  agents read, and can already write the shared budget DB and other workspaces).
  `read_body/2` narrows this by requiring the body to parse and to carry the
  resource's own `number`/`url` — a non-issue shape is never served. The poll
  path's use of the body for dispatch gating is unchanged in trust level from the
  wrapper's own agent-facing use. Documented, not new.
- **Stale serve if a delivery is lost.** The backstop is a real timer, and
  delivery-driven retirement (the safer freshness) is deliberately not relied on
  until #2331's gap recovery lands — the ticket's own gating.
- **Contract churn on the `Issues` outcome union.** Resolved at implementation by
  checking every caller before adding `:agent`; default is `:fresh` + counter.
- **Dependency: #2331** (open, blocked) — does not block U1–U5; it only gates the
  later TTL lengthening, which this plan explicitly defers.

## Deferred Implementation Notes

- Collection reads (`issues?state=open`, `/pulls?state=open`) need a second
  identity path into `kind=api` (endpoint-digest) directories plus list
  validation. Noted as follow-up; the wrapper's collection bodies are a mix of
  raw `gh api` lists and `gh list` projections, so validation is the open piece.
- Whether the daemon's agent-cache read should also extend the agent **ETag**
  (meta line 2) into the store as a validator: the raw `gh api` body and the
  daemon's conditional read use the same GitHub ETag, so a follow-up could make
  the next re-read a free `304`. Left out to keep this change minimal and
  obviously safe.
