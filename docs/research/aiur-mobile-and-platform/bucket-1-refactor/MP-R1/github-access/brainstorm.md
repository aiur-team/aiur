---
title: GitHub access layer as a reusable component - Plan
artifact_contract: ce-unified-plan/v1
artifact_readiness: requirements-only
product_contract_source: ce-brainstorm
date: 2026-10-09
base_sha: d2a022fad (origin/main)
parent: ../plan.md (MP-R1), ../component-map.md (row `github`)
---

# GitHub access layer as a reusable component - Plan

## Goal capsule

- **Objective.** Split MP-R1's `github` component in two: `github-access` (how aiur talks
  to GitHub: transport, read cache and its policy, budget broker and ledger, credential
  pool, request ledger and cost attribution, and the agent-side `gh` wrapper) and `github`
  (what aiur means by GitHub: tracker, code host, labels, trust, review threads, polling
  batches). `github-access` has no aiur domain types, takes its own config struct, and
  has its own state root. It can then be used outside aiur.
- **Product authority.** Kevin, 2026-10-09: "we have a whole github gh caching layer
  wrapper, is that planned to be its own reusable component package in the refactor?"
  Executor proposed this split; Kevin: "yes lets do that".
- **Open blockers.** None for the logical split (GHA-1..GHA-5). The scope of standalone
  use (library, CLI, or both) and the distribution channel are open questions for Kevin
  (section 9). They change GHA-5's packaging step and GHA-6, not the split itself.

Plans per ticket: [GHA-1](plan-gha-1-manifest.md), [GHA-2](plan-gha-2-settings.md),
[GHA-3](plan-gha-3-edges.md), [GHA-4](plan-gha-4-facade.md),
[GHA-5](plan-gha-5-gh-wrapper.md), [GHA-6](plan-gha-6-promotion.md).
Issues: GHA-1 #3823, GHA-2 #3824, GHA-3 #3825, GHA-4 #3826, GHA-5 #3827, GHA-6 #3828
(sub-issues of Build Order part 3/3, #3252).

---

## 1. Problem frame

Today `components.json` (origin/main) has one `github` entry: "GitHub client, budget,
read cache, domain", paths `src/lib/aiur/github/**` (79 files at `d2a022fad`; the
component map's 68 was measured at `45a290e3`) plus `allowed_contributors`, `codeowners`,
`open_ticket_source`, `global_config_startup`. Its facade list is `*` (pending
MP-R1-C1-T02). The target in `component-map.md` is "package in `aiur_github` umbrella;
repo candidate".

Nothing in the MP-R1 plan makes the caching layer usable without the rest of aiur:

- The access modules read `Aiur.Config.settings/0`, `Aiur.GitHub.Config` (repo, labels and
  token in one 1,089-line module), `Aiur.Config.Paths`, `Aiur.Workspace.Layout` and
  `Aiur.RepoBase` directly (section 4).
- `ReadCache.Policy` reads the webhook `ModeTable` owned by github-listeners.
- The agent-side wrapper (`src/priv/github_quota_guard.sh`, 3,403 lines;
  `src/priv/github_budget.py`, 1,112 lines) is owned by no component in
  `components.json`, and mixes cache/budget logic with aiur agent policy (dispatch
  disposition #1793, provenance marker #2501, the merge/approve denial).

The cache and budget layer is the most reusable thing aiur has built for GitHub: a
host-wide shared budget ledger, a byte-exact `gh` answer cache with coalescing and
write invalidation, verdict refusal, credential pooling, and per-caller cost attribution
(`website/docs-app/apis/github.md` "API budgets", "Shared agent reads", "What the agent
guard governs"). Other agents and tools on the same host (Executor sessions, background
agents, Khala peers) call plain `gh` and spend the same credential's budget unseen.

## 2. Actors

- **A1 aiur daemon** - uses github-access through the `github` component.
- **A2 aiur agents** - use the `gh` wrapper installed in their workspace.
- **A3 other tools on the host** - Executor sessions, background agents, scripts that
  run `gh`; today they bypass the shared budget and cache.
- **A4 another Elixir application** - a possible library consumer (open question Q1).

## 3. Requirements

- **R1** `github-access` is its own entry in `components.json` with declared facades. A
  checker rule fails CI when github-access references any aiur module outside itself,
  `kernel` and `signal`. Today's violations are a ratcheting allowlist that only shrinks.
- **R2** `github` (domain) depends on github-access; github-access never depends on
  `github`, `config`, `orchestration`, `github-listeners`, `build-orders`, `workspace` or
  `agent-sandbox`.
- **R3** github-access takes a settings struct (credentials, limits, cache knobs, state
  root, caller-attribution hooks, freshness port, alert sink). aiur builds it from
  `.aiur/config`; another consumer builds it in code. Config hot reload keeps working.
- **R4** The state root is injectable. Under aiur, every path stays where it is today
  (`~/.aiur/github-budget/`, `<repo-state>/github-quota/`, `github_resources.json`).
- **R5** The agent `gh` wrapper builds as a standalone executable (`gh-access`) with
  its own docs, usable without aiur. aiur's installed wrapper stays byte-identical to the
  build before this work, so every aiur agent policy is still enforced.
- **R6** A physical package (own Mix app; npm or pip only if the wrapper ships
  separately) happens only when the promotion test in `migration-plan.md` §5 passes.
- **R7** No behaviour change: every cache, refusal, TTL, hold, ledger row, metric key,
  alert text and `aiur github-cost` row stays as is.
- **R8** Invariants kept: the `@unsafe_selections` and `@unsafe_rest` refusals in
  `read_cache/policy.ex` (and the wrapper's verdict refusals) stay in github-access and
  are not configurable off; agents never receive `GITHUB_TOKEN`/`GH_TOKEN` (#2356).

## 4. Module map (origin/main `d2a022fad`)

Classification of every file under `src/lib/aiur/github/**` plus related files. "Edge to
cut" lists the access → outside references found by a reference scan of aliases and
qualified names (doc-comment mentions excluded after reading the lines).

### 4.1 github-access

| File(s) | Role | Edge to cut (ticket) |
|---|---|---|
| `transport.ex` (854) | Single HTTP path, pagination, deadlines | `GitHub.Config.repo/token` (GHA-2); `Aiur.Orchestrator` poll owner (C7-T06, then GHA-3 port); `QueueCost`, `RequestOrigin` tagging (GHA-3 hooks) |
| `errors.ex`, `graphql_errors.ex` | Typed GitHub errors | none (doc mentions only) |
| `graphql_cost.ex` | GraphQL cost instrumentation | doc mention of `BuildOrder.GitHubGraph.Queries` only |
| `endpoint_policy.ex` | Endpoint family / resource table | none |
| `quota.ex` (1,380) | Rate-limit window, preflight, reconciliation | `Aiur.Config.workspace_root`, `Workspace.Layout`, `RepoBase`, `GitHub.Config` (GHA-2); `Aiur.Orchestrator` recovery send (C7-T06 → GHA-3); `Alerts` (C7-T06 / C5) |
| `request_log.ex`, `request_origin.ex` | Request ledger, view-origin flag | `RepoBase`, `Init`, `Workspace.Hooks` path helpers (GHA-2); `RequestOrigin` LiveView check becomes an aiur-supplied tagger (GHA-3) |
| `queue_cost.ex` | Build-queue caller attribution | **moves to `github`** as a registered tagger (GHA-3) |
| `budget.ex` (928), `budget_broker.ex`, `budget_ledger.ex`, `broker_timeout.ex`, `local_hold.ex` | Elixir client of the shared Python broker, holds | `Aiur.Config.settings` (GHA-2); `Config.Schema.Agent` in `broker_timeout` (GHA-2); `Alerts` (C7-T06) |
| `credential*.ex` (5), `app_credentials.ex`, `app_token.ex`, `app_token_refresher.ex`, `auth_preflight.ex`, `host_command.ex`, `connectivity.ex` | Credential pool, App tokens, auth preflight, host `gh` runner, reachability probe | `Aiur.Config`, `GitHub.Config` token half, `Config.Schema.GithubCredential`, `WorkflowStore` (GHA-2); `connectivity → Client` (GHA-3: probe through Transport); `host_command → AgentGitHubGuard` (GHA-5) |
| `read_cache.ex`, `read_cache/{identity,metrics,policy}.ex` | Daemon read-through cache and policy | `Webhooks.ModeTable` / `DeliveryMode` (GHA-3 freshness port); caller-name classes stay as data |
| `resource_store.ex` (2,261), `resource_events.ex`, `resource_fetch.ex`, `membership_access.ex` | One record per resource, change events | `Aiur.Config`, `Config.Paths` (GHA-2); PubSub name `Aiur.PubSub` (GHA-3, injected) |
| `agent_cache.ex`, `agent_cache_bridge.ex` | Agent `gh` answer store, invalidation bridge | `Budget.state_dir` is internal; doc mentions only |
| `cycle_fetch_cache.ex` | Process-local per-cycle memo | none |
| `config.ex` (credential half: `token`, `resolve_token`, `token_source`, `app_account`, `daemon_account`, `app_identity_issue`, `keyring_*`, `kill_os_process`) | Token resolution | split out of `GitHub.Config` (GHA-2) |
| `src/priv/github_budget.py` | Host-wide broker and SQLite ledger | owner assignment (GHA-1) |
| `src/priv/github_quota_guard.sh` (core parts: budget lease, state cache, coalescing, pagination, holds, credential injection) | Agent `gh` wrapper | aiur policy parts separated at build time (GHA-5) |
| `src/lib/aiur/agent_github_guard.ex` (install mechanics: `install_host`, `host_bin_dir`, `agent_token_path`, `ensure_agent_token_file`, `budget_broker_path`, `real_gh`) | Wrapper installer | workspace placement stays in agent-sandbox (GHA-5; after C7-T04) |
| `src/lib/aiur/github_cost_cli.ex`, `github_usage_cli.ex` | Cost / usage reports | renderers stay CLI; data comes from the facade (GHA-4) |

### 4.2 github (domain, stays)

`client.ex`, `tracker.ex`, `issues.ex`, `issue_state.ex`, `issue_dependencies.ex`,
`issue_relationships.ex`, `dependencies_api.ex`, `bounded_blocked_by.ex`, `labels.ex`,
`state_policy.ex`, `comments.ex`, `pull_requests.ex`, `ticket_pull_request.ex`,
`delivered_pull_request.ex`, `merge_queue.ex`, `changed_paths.ex`, `ci_readiness.ex`,
`ci_poll_batch.ex`, `comment_poll_batch.ex`, `poll_snapshots.ex`, `review_threads*.ex`
(4), `human_review_gate.ex`, `dispatch_authorization.ex`, `code_owners.ex`,
`codeowners_file.ex`, `codeowners_pattern.ex`, `trust_snapshot.ex`, `teams.ex`,
`bot_identity.ex`, `agent_marker.ex`, `write_through.ex`, `view_state_sweep.ex`,
`view_state_demand.ex`, `open_issue_listing.ex`, `open_issue_snapshot.ex`,
`repo_events.ex`, `config.ex` (domain half: repo, labels, planning budgets, trust lists,
mergers, pr_watch, pr_health, `validate!`), `config/semantic_check.ex`, plus today's
non-`github/` paths in the entry, and the aiur policy parts of the wrapper (#1793
disposition, #2501 marker, merge/approve denial) and `github_push_guard.sh`.

### 4.3 Crossing call edges (domain → access, allowed)

Every domain module above reaches GitHub only through `Transport`, `ResourceStore`,
`ResourceFetch`, `ReadCache.invalidate*`, `Budget`/`LocalHold` and `Errors`. These
become the github-access facade (GHA-4). Access → domain edges found by the scan:

| From (access) | To (domain or other component) | Kind | Treatment |
|---|---|---|---|
| `transport.ex` | `GitHub.Config` | call | settings struct (GHA-2) |
| `transport.ex` | `QueueCost` (domain), `RequestOrigin` | call | registered request taggers (GHA-3) |
| `transport.ex` | `Aiur.Orchestrator` (identity compare) | call | C7-T06 config key, then settings field (GHA-3) |
| `quota.ex` | `Aiur.Orchestrator` (send), `Workspace.Layout`, `RepoBase`, `Aiur.Config` | call | C7-T06 + settings (GHA-2/3) |
| `read_cache/policy.ex` | `Webhooks.ModeTable`, `DeliveryMode` | call, type | freshness port owned by access (GHA-3) |
| `connectivity.ex` | `GitHub.Client` | call | probe via Transport (GHA-3) |
| `credential.ex`, `credential_registry.ex` | `Config.Schema.GithubCredential`, `WorkflowStore` | type, call | credential spec struct in access; config converts (GHA-2) |
| `host_command.ex` | `AgentGitHubGuard` | call | installer moves into access (GHA-5) |
| `resource_store.ex`, `resource_events.ex` | `Aiur.Config`, `Config.Paths`, `Aiur.PubSub` | call | state root + pubsub from settings (GHA-2/3) |
| `request_log.ex` | `RepoBase`, `Init`, `Workspace.Hooks` | call | state root (GHA-2) |
| `app_token_refresher.ex`, `credential_headroom.ex`, `budget.ex`, `quota.ex`, `broker_timeout.ex` | `Aiur.Alerts` | call | C7-T06 / MP-R1-C5 move them to `Signal.alert/2`; access takes an alert sink |

The reverse direction is already true in one place: `ResourceStore` is written by
`Events.GitHubWebhook.Deposit` (github-listeners) and read by the domain. Both are
downward edges after the split.

## 5. Approaches considered

1. **Keep one `github` component (status quo plan).** Least work. The cache layer stays
   welded to aiur config, and a second consumer would need the whole tracker domain.
   Rejected by Kevin's ask.
2. **Two logical components, then promote (chosen).** Manifest split, settings struct,
   edge cuts and a facade inside `src/`; physical package only after the promotion test.
   Follows MP-R1-KD1 and KTD3/KTD11: ownership and contracts first, packages last.
3. **Extract straight to a new repository now.** Fastest route to "reusable", but it
   moves 30+ files before their edges are cut and before U5/U8 finish rewriting them,
   and breaks the single-release boot. Rejected: it fails promotion criteria 1-3.
4. **Challenger: wrapper-first.** Ship only the `gh` wrapper standalone and leave the
   Elixir side in `github`. The wrapper is already a process boundary (shell + Python
   + SQLite), so it is reusable with the least work, and it serves A3 at once. Folded
   into approach 2 as GHA-5, which does not wait on GHA-2..GHA-4.

## 6. Key decisions

- **KD1 No module rename in the logical phase.** Files keep `Aiur.GitHub.*` names; the
  manifest assigns them by path. A rename to a package namespace happens only at
  promotion (GHA-6), behind the facade, so callers change once. Reason: 42 distinct
  `Aiur.GitHub.*` modules are referenced from outside `github/` (C7-T06 census); a
  rename now collides with U5, U8 and C7 tickets on the same files.
- **KD2 One new facade module, `Aiur.GitHub.Access`.** KTD11 says no new facade "by
  default"; this is the explicit exception Kevin approved, because a reusable component
  needs a contract that is not "every module". Declared facades =
  `Aiur.GitHub.Access` plus a short, frozen list of existing modules still called
  directly (shrinks to zero by GHA-4).
- **KD3 Settings provider, not a static struct.** github-access calls a registered
  provider (`settings/0`) that returns `Aiur.GitHub.Access.Settings`. aiur's provider
  reads `Aiur.Config.settings/0` on each call as the code does today, so hot reload is
  unchanged. A standalone consumer registers a static provider.
- **KD4 State root default unchanged.** Under aiur the provider passes today's paths.
  The wrapper keeps `~/.aiur/github-budget` as its default root even standalone, so
  aiur agents and other tools on the same host share one ledger and one answer store
  per credential: that sharing is the point (github.md "separate daemons never get
  separate quota ledgers for a shared credential").
- **KD5 Wrapper split at build time, not by a runtime hook.** The guard source (after
  U8-P23-T01 splits it into parts) is grouped into `core` parts and `aiur-policy` parts.
  aiur's installed `gh` = concatenation of all parts in today's order, byte-identical.
  The standalone `gh-access` = core parts plus a no-op policy part. Reason: a runtime
  hook could be missing or bypassed, and U8-P23-T01 forbids runtime `source` of extra
  files; build-time composition keeps the merge/approve denial in aiur's file by
  construction.
- **KD6 Env names stay `AIUR_GITHUB_*`.** They are the wrapper's documented contract
  (github.md "Shared agent reads" settings table). Renaming is churn with no user value
  now; Q3 asks Kevin about a standalone name.
- **KD7 Verdict refusals are not settings.** `@unsafe_selections`, `@unsafe_rest` and
  the wrapper's `cache_volatile_fields`/`cache_unsafe_rest_endpoint` live in
  github-access and have no off switch in the settings struct. Caller-name classes in
  `ReadCache.Policy` stay as data in the policy (strings, not aiur modules).
- **KD8 Credentials stay out of agent env.** github-access exposes the credential-file
  path and the scrub list as data; the deny-list merge stays in agent-sandbox and runs
  after contributors (C7-T04 invariant 1). The standalone wrapper injects a credential
  only into the real `gh` child for one call, as today.
- **KD9 Order behind U5, U8, C7-T06, C7-T04, C4-T02.** Those tickets rewrite or split the
  same files. GHA tickets rebase on them instead of racing them.

## 7. Scope boundaries

- **In:** manifest split; settings struct and provider; state-root injection; access →
  domain edge cuts; `Aiur.GitHub.Access` facade and caller migration; standalone wrapper
  build and docs; promotion-test record and, on go, the package move.
- **Out:** any change to what is cached, refused, held or billed; webhook ingestion
  (github-listeners, MP-R1-C9); `Issues → DispatchPolicy` (C9-T09); U5 typed outcomes;
  U8 file splits (GHA tickets wait for them); renaming env vars; a hosted service.
- **Deferred to follow-up:** publishing the wrapper to npm/pip/Homebrew (depends on Q2);
  moving github-access to its own repository (promotion test, later).

## 8. Success criteria

- `python3 scripts/check-components.py` passes with `github-access` declared and an
  allowlist that only shrinks; `git grep` of `src/lib/aiur/github/<access files>` for
  `Aiur.(Config|Orchestrator|Workspace|RepoBase|Webhooks|BuildOrder|Alerts)\b` returns
  only doc comments.
- A test starts github-access with a static settings provider and a temp state root,
  without booting `Aiur.Application`, and serves a cached read and a budget lease.
- `gh-access` runs `gh api repos/o/r` twice against a stub `gh` with no aiur
  install, and the second call is a cache hit recorded in the ledger.
- aiur's installed `gh` wrapper hash equals the pre-change build.
- The promotion test record exists with each criterion answered.

## 9. Open questions for Kevin

- **Q1 Scope of standalone use.** (a) Elixir library for other Elixir apps, (b) a
  standalone `gh` caching wrapper for any agent or tool without aiur, or (c) both.
  **Recommendation: (c), wrapper first.** The wrapper is already language-neutral and
  has an immediate second consumer (Executor sessions and background agents that run
  plain `gh` on this host, which today spend the bot budget unseen). The library form
  follows through the promotion test; its second consumer is not yet named (Khala if it
  reads GitHub).
- **Q2 Distribution of the wrapper.** Inside the existing `aiur-cli` npm package
  (`aiur gh-access install`), a separate npm/pip package, or Homebrew.
  **Recommendation:** ship inside `aiur-cli` first plus a self-contained build in
  `packages/gh-access/`; publish separately only when an outside user asks. Netlify and
  publishing credits are not involved.
- **Q3 Name.** `gh-access` (matches the component) or an unbranded name for outside use.
  **Recommendation:** `gh-access`; keep `AIUR_GITHUB_*` env names (KD6).
- **Q4 Merge-gate default for standalone users.** The standalone build drops aiur's
  merge/approve denial. **Recommendation:** keep it dropped by default and document an
  opt-in `--deny-merge` build flag; the denial is aiur agent policy, not caching.

## Sources

- `components.json` (origin/main) entries `github`, `github-listeners`.
- `component-map.md` row `github`; `migration-plan.md` §5; tickets MP-R1-C7-T06
  (#3301), C4-T02 (#3270), C7-T04 (#3298), C7-T07 (#3309).
- `website/docs-app/apis/github.md` sections "API budgets", "Shared agent reads",
  "What the agent guard governs".
- U8 split tickets on the same files: #3489, #3490, #3491, #3492, #3493, #3494; U5
  #3296, #3297.
