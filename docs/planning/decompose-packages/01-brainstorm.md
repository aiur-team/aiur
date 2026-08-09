# Brainstorm: decomposing aiur into sub-packages

Research spike, 2026-08-08. Five parallel surveys of the codebase plus two
capability-slice assessments. **Nothing here is implemented or scheduled.** The
gate in `README.md` applies.

## The question, corrected twice

The spike began with the wrong evaluation criterion and the wrong slicing axis.
Both corrections came from the operator, and both change the answer.

### Correction 1 — the criterion

The surveys asked **"who uses this alone today?"** and answered "almost nobody".
Of roughly thirty candidates across four surveys, three had a credible external
consumer.

The operator's criterion is different:

> not because anything uses them externally, but to allow for other projects to
> utilize the plumbing

That is a question about **enablement**, not adoption. A package that nobody
uses today but that lets someone build a thing they cannot build now is a
success under the second criterion and a failure under the first. The second is
the right one here.

### Correction 2 — the axis

The five surveys sliced **horizontally**: runtime, web, CLI, integrations,
tests. The operator's two examples are **vertical** — a capability that cuts
through every layer:

| capability | cuts through |
| --- | --- |
| watch PR/issue comments and act on requested changes | GitHub polling → event bus → wake → dispatch |
| decompose a feature into a build order | planning graph → ticket shapes → tracker write |

A horizontal survey cannot see a vertical package. This is why `github/` came
back as *do not extract*: as a **layer** it is ~9,000 lines with a circular
dependency. As a **capability slice** it may be a fraction of that.

The vertical assessments are in `02-capability-slices.md`.

### Correction 3 — refactoring is in scope

> i am very open to needed refactoring to reduce coupling

Most survey verdicts were *do not extract, the coupling is expensive to break* —
not *the seam is in the wrong place*. With refactoring in scope, those verdicts
are no longer refusals. They become cost estimates.

## What the codebase actually is

One flat Mix app. `app: :aiur`, 815 modules, a single supervision tree at
`aiur.ex:139-200` starting roughly sixty named singletons. No umbrella.
`packages/streamdeck/` is the only genuinely separate package, and it is
TypeScript.

There are no per-subsystem supervisors, so **no candidate has an existing
startable boundary**. That is a precondition for any split, horizontal or
vertical.

## Three cycles block everything

Each must be cut before any package can be expressed. Each is cheap relative to
its blocking power.

### 1. The runtime depends on the web namespace

```
aiur/current_run_projections/state.ex:20        → AiurWeb…UnitsRow.snapshot/1
aiur/current_run_projections/units_builder.ex:46 → UnitsRow.version()
aiur/current_run_summary/facts.ex:45-46          → UnitsPolicy.in_scope?/2
```

`UnitsRow` has zero Phoenix references. It is runtime domain code misfiled under
`AiurWeb`. The same inversion applies to PubSub: `Aiur.Alerts`,
`Aiur.RecentMergeStore` and `Aiur.Orchestrator.SnapshotStore` all broadcast
through `AiurWeb.ObservabilityPubSub`.

The fix is a rename, and the correct-direction twin already exists —
`aiur/agent_pubsub.ex:6` documents itself as "Modeled on
`AiurWeb.ObservabilityPubSub`".

### 2. `claude` and `codex` mutually alias each other

```
claude/coding_agent.ex:18-19  → alias Aiur.Codex.AppServerPort, Aiur.Codex.DynamicTool
codex/app_server_port.ex:8    → alias Aiur.Claude.RemoteControl
```

A "modular backend" package could never ship a single backend. This defeats the
stated goal directly, so it is a precondition rather than a nice-to-have.

### 3. `github/` and `BuildOrder.GitHubGraph`

```
github/client.ex:6,74-80        → BuildOrder.GitHubGraph
build_order/github_graph.ex:5   → GitHub.Transport
```

This one sits directly across the build-order capability slice, so it is load
bearing for the operator's second example.

## One change is worth more than any package

The provider registry is consulted at **compile time**:

```elixir
usage_envelope.ex:16                 @providers Aiur.CodingAgent.provider_families()
provider_meters/input.ex:5           (same)
usage/price_table/validator.ex:7     (same)
provider_meter_projection.ex:31      (same)
```

The provider list is baked into four BEAM files. Adding a provider forces a
recompile of the usage layer. Making it runtime unlocks the price table, the
usage envelope, and most of `GroupedScopes` in one move — and is valuable with
no packaging at all.

## The test-speed argument does not hold

The operator asked specifically about faster test runs, faster iteration and
more parallel agents. This was measured rather than asserted, and the honest
answer is that **decomposition buys flake reduction, not parallelism.**

Measured:

| | |
| --- | --- |
| CI critical path | 562s |
| Serial share of ExUnit time | 79.3% |
| CI failure rate | ~40% of runs |
| `async: false` files | 181 of 530 |

Every one of the 181 serial files was classified by cause:

| cause | files | share |
| --- | --- | --- |
| a named singleton the test starts | 118 | 65.2% |
| VM-global state (persistent_term, ETS, env) | 44 | 24.3% |
| real host state | 13 | 7.2% |
| cargo-culted | 6 | 3.3% |
| **genuinely sequential logic** | **0** | **0%** |

Nothing is serial because the logic requires it. Everything is serial because of
shared state — and the dominant mechanism is one idiom: **71 modules start as
`name: __MODULE__`**, so any test starting a second copy collides.

Two reasons a split does not deliver the speed:

1. **39 files collide on `System.put_env` / `Application.put_env`** — 21.5% of
   the serial population. Those are global to a *BEAM*, not to a package.
   Siblings inside one package still collide. A split fixes approximately none
   of them.
2. **The cross-package leaks stay serial.** #1330, #1426, #1007 and #1602
   involve files that are already `async: false` and would remain so. The split
   makes them *reliable*, not *parallel*. Different properties.

Estimated files that could go `async: true` after a six-way split: **15-25 of
181 (8-14%)**.

So the speed case belongs to #1625 (singleton naming), not to decomposition. The
flake case does belong to decomposition — it would have prevented four of the
five flake mechanisms this repo has hit. Against a 40% CI failure rate that is
real value, but it should be claimed honestly for what it is.

## Horizontal candidates that survive on their own merits

Three, and only three, had a credible external consumer under the *original*
criterion. They remain the strongest under either.

| candidate | why | standalone today |
| --- | --- | --- |
| **Stream Deck driver core** | 26 of 37 modules, one runtime dep (`usb`), fully dependency-injected. The aiur coupling is *three strings*: a lock name, an env var, a systemd unit name. | ~95% |
| **LLM price catalog** | Effective-dated, provenance-carrying price table with exact Decimal cost. People reimplement this with floats. | ~80% |
| **`topic_exchange`** | Pattern-matching pub/sub. `Phoenix.PubSub` is literal-match only, which `events/exchange.ex:5-22` states as the reason it exists. 295 LOC with its own tests. | ~95% |

The Stream Deck one is time-sensitive: PR #1603 is defining the artifact layout
now, and choosing that layout with the driver/binding split in mind is much
cheaper than re-cutting a published, content-addressed artifact later.

## Splits that are wrong, and why

Recorded so they are not re-proposed.

- **`github/` as a tracker package.** 79 direct `GitHub.*` references across 47
  files outside `github/`, versus ~64 calls through `Aiur.Tracker` — roughly
  1:1. The abstraction does not hold. Several modules branch explicitly on
  `Config.tracker_kind() == "github"`, and `orchestrator/tracker_health.ex` is
  itself GitHub-specific.
- **Linear as evidence of tracker-agnosticism.** It is the default fallback
  branch, self-described as "LIMITED and lightly tested", with half its
  callbacks stubbed `{:ok, []}` or `{:error, :unsupported}`. One test file
  against 49 touching `Aiur.GitHub`. It passes the suite by being a null object.
- **A component or design-system package.** 7k LOC of components and 7.7k lines
  of CSS serving four pages, with per-page class prefixes smeared across the
  file. Extract the ~94 design tokens; leave components with their pages.
- **`opencode/` as one package.** It is two things in one directory: a pane pool
  with zero external callers, and wire plumbing that must stay headless. Split
  on that line, not the directory.
- **The orchestrator/agent-runner pair.** A real bidirectional dependency around
  shared queue state. A package boundary across a cycle produces a circular
  dependency you "solve" by inventing a third types package — the classic wrong
  split.

## Defects found while looking

None of these are decomposition work. All were filed.

| | |
| --- | --- |
| #1621 | a session without `:backend` silently dispatches to the global default backend |
| #1622 | one string-returning call drags the whole Phoenix tree into every control read |
| #1623 | unconfigured credentials make the auth plug pass requests through unauthenticated |
| #1624 | one corrupt line makes the entire findings ledger unreadable |
| #1625 | 71 GenServers default to `name: __MODULE__` |

#1622 is worth doing before any measurement is trusted: it inflates every module
closure the planning would be based on.

## Open questions for discussion

1. **Is enablement enough?** Under the operator's criterion the bar is "someone
   could build a thing they cannot build now". That is a real bar, but it is
   satisfiable by almost any split. What makes a candidate worth its versioning
   cost?
2. **Where does the aiur-specific glue live** once a capability is extracted? A
   package plus an adapter is two things to maintain, not one.
3. **How is drift prevented?** The Stream Deck package already drifted from the
   web renderer on two fields with no parity test (#1571, #1584). That happened
   inside one repo. Across published versions it is harder.
4. **Umbrella or separate repos?** Not answered here. The cycles must be cut
   before the question is even expressible.
