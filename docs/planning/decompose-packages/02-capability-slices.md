# The two capability slices the operator named

Assessed as **vertical** slices — a capability cutting through every layer —
rather than as layers. Both were assessed after the horizontal surveys had
already returned "do not extract" verdicts on the directories they live in.

Headline: **the vertical framing changes the answer for one and confirms it for
the other, and neither is an extraction.**

---

## Slice 1 — watch PR and issue comments, act on requested changes

> if i want to use the ticket + PR comment listener as a skill separate from
> aiur, the agent would have to fully install and run aiur. yet i only want the
> agent to subscribe and implement commented changes.

### The vertical framing works, and here is exactly why

The horizontal survey said *do not extract `github/`* because it is ~9,000 lines
with a circular dependency on `BuildOrder.GitHubGraph`.

That verdict does not transfer, for a specific reason:

> `Aiur.GitHub.Client` is **not required**. It is a facade that aliases
> `Aiur.BuildOrder.GitHubGraph` at `github/client.ex:6` — the circular
> dependency that killed the layer extraction. The slice calls exactly three of
> its functions, each a one-line delegate to `Comments`, `PullRequests`, or
> `ReviewThreads`. **Bypassing the facade dissolves the circularity entirely.**

That is the general lesson of this whole spike: **the cycle lives in a
convenience facade, not in the capability.** A layer survey sees the facade and
stops. A capability survey routes around it.

### But it is a rewrite that harvests, not an extraction

| | lines |
| --- | --- |
| lifts near-verbatim | ~2,480 |
| lifts with surgery | ~1,600 |
| left behind | ~1,935 |
| net new the package must write | ~400-600 |
| tests that do not transfer | ~1,800 of ~2,000 |

Both **ends** of the pipe are aiur-shaped and both must be replaced:

- The **input** end asks "which of my tickets are in `human-review` or
  `merging`?" (`target_selection.ex:16-19,148`). The package's input is "here is
  a PR number." 389 lines deleted, ~60 written.
- The **output** end drives a state machine over issue lifecycle, dispatch
  admission and workspace teardown (`comment_wake.ex`, 744 lines). The package's
  output is `send(pid, {:gh_event, event})`. 744 deleted, ~40 kept.

What survives is the middle: fetch → cache → prove completeness → sanitize →
dedup → fan out. That middle is genuinely good.

### What is actually worth harvesting

Not the poller. Two things:

**`Sanitizer` (306 lines, near-zero coupling).** The strip → redact → truncate →
escape ordering is load-bearing and documented as such: redact before truncate
so a redacted match cannot straddle the boundary, escape last so a body
containing `</external-content>` cannot break out of the digest wrapper. The
invisible-Unicode class list and `base64_blob?/1` — which requires an encoding
marker or a case-diverse alphabet so long prose is not eaten — are post-incident
knowledge.

**The cursor-completeness proof** (`comment_poll_batch.ex:341-372`). GraphQL
`comments(last: 100)` cannot express `since`, so the batch must decide whether
the newest-100 window *provably covers* the cursor. It declares truncation only
when `hasPreviousPage` **and** the window's own oldest comment is newer than
`since`. With no cursor at all it returns truncated, because returning the raw
window would replay a ticket's entire comment history as fresh events after a
restart.

Alongside it, the **never-guess discipline**: at every point where the batch
cannot give a provably complete answer, the target is dropped and the poller
does a full REST read. The batch is a pure optimisation that structurally cannot
lose an event.

### Three corrections to what was believed

1. **There is no rate-limit budgeting.** `transport.ex:301-312` logs a warning at
   ≤10% remaining and **nothing reads it**. No throttle, no backoff, no
   deferral. `comment_polling.ex:132-138` records that a quiet-period backoff was
   scoped and deliberately not implemented. Rate control is emergent from 304s
   and batching.
2. **There is no comment classification.** The pipeline is four booleans, and the
   capability as described — "wake when a comment asks for a change" — is
   approximated as "a CODEOWNER said something on an unresolved thread that is
   not the literal string `[codex] review passed`". A classifier is net-new work.
3. **Review submissions are not ingested on `develop`.** PR #1427 adds them with
   per-reviewer most-recent dedup — 31 matching lines — but it is unmerged.

### The gap that only exists standalone

aiur **never persists its cursor**. `state.ex:168-169` holds
`github_comments_since` and `github_comment_etags` as plain struct fields in the
orchestrator GenServer. After a restart there is no cursor and no dedup, and
aiur papers over it by defaulting `since` to boot-minus-60s
(`github_keys.ex:128`) — deliberately dropping pre-boot comments.

A standalone package cannot make that trade. An agent that restarts must not
miss the review comment that arrived while it was down, nor replay an hour of
comments. Durable cursor and dedup are new work aiur cannot donate.

---

## Slice 2 — decompose a feature into a build order

> if i want an agent to decompose a feature into a build order, it shouldn't
> need all of aiur to do that

### The valuable asset is the skill markdown, not the Elixir

> `references/decomposition-workflow.md` (386 lines) contains the real
> intellectual property, and **none of it is implemented in Elixir**.

What lives only in the doctrine:

- **"Phases are computed, not chosen"** — a phase is an antichain of the hard
  dependency graph, leveled by longest-path-from-roots, with zero internal
  `depends_on` edges, so a consumer may treat it as a free barrier. Elixir
  merely parses an authored integer (`metadata.ex:102-106`), and
  `planning-contract.md:71` concedes "Phase is authored planning metadata."
- Six typed edge kinds — `depends_on`, `serializes_with`, `suggested_after`,
  `contains`, `external_gates`, `discovered_from`. Elixir models **one**.
- The edge acceptance test, the depth-reduction playbook, wave profiles,
  critical path, serialization cliques, and a 12-point semantic validator.
- Worked calibration: *"CropTracker's Stripe lane started at effective wave 7 of
  21 under milestone phases; under computed phases it starts at phase 4 of 9."*

### The Elixir tree is a dashboard read model, not a planning library

The proof is a round trip. A tracker-neutral JSON pack has its integers
stringified into GitHub label syntax purely so the parser can re-parse them:

```elixir
# planning_source.ex:211-213
defp pack_labels(ticket) do
  ["build-lane:#{ticket.lane}", "phase:#{ticket.phase}"] ++
    if(ticket.complexity, do: ["complexity:#{ticket.complexity}"], else: [])
end
```

`metadata.ex:28,39,50` reads complexity, phase and lane out of label *text*.
There is no struct field carrying an integer complexity.

There is also **no module that authors a pack**. No epic type, no provenance, no
typed edges, no phase leveling. The Elixir models a graph of issues that already
exist.

### Three couplings, in order of severity

1. **The planning vocabulary has no representation independent of GitHub
   labels.** Any extraction replaces this layer rather than lifting it.
2. **`TrackerIdentity` is an abstraction with one legal inhabitant.**
   `tracker_identity.ex:121` pattern-matches `kind: :github` as a literal, and
   `member.ex:102` makes that a validity precondition. Any other value fails
   closed.
3. **`bounded.ex` is load-bearing in both directions.** It sits in the
   `BuildOrder` namespace, hardcodes `github.com` (`bounded.ex:192`), is
   required by the planning model (`member.ex:138,146`), and is required by
   aiur's own GitHub transport (`github/issues.ex:7`). It cannot move and cannot
   be cheaply duplicated.

### The accounting

| bucket | lines | disposition |
| --- | --- | --- |
| skill doctrine | 963 | **port verbatim — the asset** |
| graph algebra | **411** | extract |
| model shape | ~658 | read for structure, rewrite |
| `bounded.ex` | 236 | leave — 8 external consumers |
| GitHub adapters, projections, ticket detail | ~5,900 | leave |
| **orphaned Python in `scripts/`** | **12,922** | **discard** |

The Python is superseded and contradicted by its own contract:
`planning-contract.md:57` states *"No publication manifest, receipt, or
automatic materialization machinery is part of this flow"* — an explicit
repudiation of the publication scripts. No markdown references any script by
name, no CI job invokes it, and its validator checks a schema the Elixir reader
ignores entirely.

### Half the API does not exist anywhere

Authoring, phase leveling, wave profiling and the semantic validator have **no
implementation in either language**. They are currently performed by a model
reading `decomposition-workflow.md`.

### Implication

If the goal is an agent that decomposes a feature without installing aiur, the
shortest path is **ship the skill markdown plus a small validator**, and treat
the Elixir tree as a reference implementation of the dashboard read model.
Extracting the Elixir buys ~411 lines of individually unremarkable graph
algorithms and inherits three GitHub couplings that each need removing anyway.

---

## What both slices have in common

1. **Neither is an extraction.** Both are rewrites that harvest a good middle.
2. **The valuable part is not where the directory structure suggests.** For the
   listener it is a sanitizer and a completeness proof. For build orders it is
   markdown.
3. **The stated capability does not fully exist yet.** The listener cannot tell
   whether a comment asks for a change. The build-order tooling cannot compute a
   phase. Both need net-new work to deliver what was described.
4. **The cycle that blocks the layer does not block the capability.** In both
   cases it lives in a facade or a shared validator, not on the path the
   capability actually walks.
