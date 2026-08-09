# Other slices worth considering

Candidates beyond the two the operator named. Judged by the **enablement**
criterion: what could someone build that they cannot build now?

Each entry says what it is, what makes it hard to rebuild, and what it would
drag in. Nothing here is recommended yet — this is the option space.

---

## Vertical slices — capabilities

### V1. Human-in-the-loop decision protocol

**Probably the strongest candidate in the whole spike.**

An agent hits a question it cannot answer, records it as a blocking decision,
and stops. The question routes to a human with options and a recommendation. The
human answers. The answer is delivered back and the agent resumes.

The lifecycle is the valuable part, and it is the part everyone gets wrong:

```
recorded → dispatch_pending → delivered → acknowledged → resolved
                            ↘ delivery_failed
                            ↘ superseded
```

`dispatch_pending` is the state that matters. The human has answered and the
agent has not received it — and from outside, that is indistinguishable from
"answered, done". Every naive implementation collapses those and silently
strands agents.

**Why it is hard to rebuild:** delivery is not a function call. It has to
survive a daemon restart, handle an agent that died between question and answer,
supersede an answer that was revised, and expire a decision whose ticket closed.
`DecisionExpiry`, revision handling and the delivery-failure path are all
earned behaviour.

**What it drags in:** `DecisionStore` is a named singleton; delivery routes
through `Orchestrator` (#1058 — unmonitored `Task.start`, no backpressure).
`decision_store.ex:2447`.

**Who would use it:** any agent framework with a supervisor in the loop. This is
the hardest part of agent supervision and it is currently welded to a fleet
orchestrator.

---

### V2. Host admission control

Decide whether to start another subprocess on this machine, from measured
pressure rather than a fixed cap.

`DispatchPolicy.admission_gate/1` gates on memory, file descriptors (with a 10%
headroom rule), run queue, load average, build pressure and provider
availability, then widens an AIMD envelope as samples come in below target.

**Why it is hard to rebuild:** tonight is the evidence. This host reached **load
100.95 on 16 cores** — 6.3× oversubscription — while status reported
`binding: none`. The *logic* was correct when fed real numbers; it was not being
applied (#1610). Getting this right is subtle, and getting it wrong is expensive
in a way that is invisible until the control surface stops answering.

**What it drags in:** `Config` reads at `dispatch_policy.ex:74,319-320,531,661,669`;
`BuildGate.status()` at `:64`; `ModelAvailability` at `:173`. The gate function
itself is pure — it takes a map and returns a decision. The *inputs* are coupled,
not the policy.

**Who would use it:** anything running N subprocesses on one box — CI runners,
build farms, local agent swarms. The `sysprobe` half is replaceable by `:os_mon`;
the *policy* is not.

---

### V3. Provider metering and exact cost

Normalise token payloads from several providers into one versioned envelope,
then resolve exact cost from an effective-dated price table using Decimal money.

**Why it is hard to rebuild:** people do this with floats and get it wrong.
Effective dating matters because prices change and historical runs must not
re-price. Provenance matters because a cost figure without a source is not
auditable.

**What it drags in:** the compile-time provider registry —
`usage_envelope.ex:16` and three others bake `Aiur.CodingAgent.provider_families()`
into the BEAM. Also `usage_aggregate/key.ex:27` has `{:github, owner, repo, id}`
**in the type**, so the aggregate is not extractable without a rewrite. Take the
price table and the envelope; leave the aggregate.

**Who would use it:** anyone running Claude, Codex, OpenRouter or DeepSeek
programmatically who needs to answer "what did that cost".

---

### V4. Isolated workspace provisioning

Give each unit of work its own git worktree, provisioned from a warm base, with
lease-based ownership so two workers cannot claim the same tree.

**Why it is hard to rebuild:** the lease and reconstruction paths are where the
bodies are. Ownership must survive a crash, a stale lease must be reclaimable,
and a half-provisioned tree must be recoverable rather than abandoned.

**What it drags in — and this is the expensive one:** the storage path depends on
**tracker identity** (`workspace/ownership/store.ex:170-173`), it registers
through `:global` (`workspace/reconstruction.ex:63,78`), and the provisioner
installs agent skills (`provisioner.ex:23,32`) — a clear inversion.

**Who would use it:** any system running parallel agents that must not share a
checkout. Real need; expensive extraction. Honest verdict: worth it only if the
tracker-identity coupling is being fixed anyway.

---

### V5. Coding-agent session driver

One contract over Claude, Codex and OpenAI-compatible CLIs: open a session, run
a turn, stream output, interrupt, close.

**Why it is interesting:** `AppServer.Adapter` is an 8-callback behaviour and is
the real runtime contract — more load-bearing than `CodingAgent.Backend`. Two
backends already implement it.

**What blocks it:** the `claude` ↔ `codex` mutual alias (cycle 2 in the
brainstorm) means the package could never ship one backend. And the registry
embeds dashboard CSS paths, SVG URLs and hex colours
(`coding_agent.ex:117-128`) — presentation data in a runtime contract.

**Honest verdict:** extract the **behaviour**, not the backends. The behaviour is
package-shaped. The implementations are not, until the cycle is cut.

---

### V6. CI readiness inspection

Answer "can this repository actually merge the PRs we open?" and report every
missing prerequisite at once rather than failing at the first.

`:base_branch_missing`, `:no_pr_workflow`, `:no_required_check`,
`{:required_check_not_produced, [...]}`.

**Why it is useful:** that last one is a silent killer — a branch rule requiring
a check no workflow emits makes every PR unmergeable, and without the inspection
you find out one PR at a time.

**Size:** small and self-contained. Needs a `workflow`-scoped token (#1588).

**Who would use it:** any bot that opens PRs. Narrow, but genuinely nobody has
this and everyone needs it.

---

### V7. Findings ledger and the self-improvement loop

Record an observation, classify it, dedupe by failure class rather than
incident, and promote it to a ticket. `aiur findings --unfiled` is the gate that
makes a retrospective real.

**Why it exists:** of 71 findings in the 2026-07-30 run, 23 reached no ticket.
The mechanism was "an Executor remembers", which is not a mechanism.

**Honest verdict: weak as a package.** The schema is aiur's workflow — scopes are
`~w(aiur repo)`, the ticket must be a GitHub issue number
(`findings.ex:220-222`), and the status machine couples to ticket presence. Two
consumers, both aiur. The *idea* travels; the code does not.

(Also: `findings.ex:152-162` halts on the first bad line, so one corrupt record
makes the whole ledger unreadable — #1624.)

---

## Horizontal slices — layers

### H1. Design tokens

~94 CSS custom properties plus the bucket-to-visual map, emitted as **both** CSS
variables and JSON so the web renderer and the hardware renderer consume one
source.

This is the piece that prevents the drift already observed (#1571, #1584). Small,
and it earns its place by fixing a live problem rather than by being tidy.

The larger "design system" is a mirage: 690 class names across ~25 feature
prefixes, smeared through 7,732 lines. Extract the tokens, not the stylesheet.

### H2. `topic_exchange`

Pattern-matching pub/sub. `Phoenix.PubSub` is literal-match only, which
`events/exchange.ex:5-22` states as the reason this exists. 295 LOC, ships with
its own tests, and `Exchange.publish/2` has exactly **two** call sites — an
unusually narrow seam.

### H3. Crash-safe local persistence

Atomic write with fsync, NDJSON decode-or-skip, replay, and quarantine on
corruption. ~450 LOC, ~98% standalone, and it is the substrate under
`IdGenerator`, `SubscriptionStore`, `ExecutorEvents` and `Findings` — so
extracting it pays into every later split.

### H4. GitHub HTTP primitives

App-installation token minting, ETag/304 caching, GraphQL error classification,
per-cycle fetch memoisation. ~800 of `github/`'s 9,000 lines, with **zero
`Aiur.*` references**.

This is the answer to "extract `github/`" done correctly: harvest the primitives,
do not attempt the tracker.

### H5. The CLI output envelope

`schema_version` / `snapshot` / `request` / `sources[]` / `data` / `auxiliary`,
with per-source freshness and an explicit rule that known-absence must never
degrade to `0` or `[]`.

Already designed and merged as research (#1590, PR #1601). It is the contract
both the Executor CLI and any third-party tool would consume.

**Caution:** it currently covers the four dashboard pages only. If it ships
without also covering `status`, `agents`, `watch` and `alerts`, the result is two
competing JSON contracts in one binary.

### H6. An aiur client

The thing that would replace `aiur-engine.sh:1744-2130`, where bash builds
Elixir **source strings** and ships them over Erlang distribution, then scrapes
`__AIUR_CONTROL_EXIT__:<n>` from stdout because the RPC's real return value is
discarded.

A real client speaking H5 over HTTP is the actual answer to "third-party tools".
It needs the HTTP gaps closed first: 3 of 17 commands exist, all disabled by
default.

### H7. procfs sampler

Per-process CPU, memory and FD attribution on Linux. `procfs.ex` has **zero
aliases** — free to extract, moderate value, `:os_mon` covers some of it.

---

## Ranking by enablement, not by tidiness

| tier | candidates | why |
| --- | --- | --- |
| **Strongest** | Stream Deck driver, V1 decision protocol, V2 admission control | Each enables something real that is genuinely hard to rebuild |
| **Strong** | V3 provider metering, H1 design tokens, H3 persistence, H2 topic_exchange | Small, clean, and each fixes a live problem |
| **Conditional** | V4 workspaces, V6 CI readiness, H4 GitHub primitives, H5 envelope | Worth it if the coupling is being fixed anyway |
| **Behaviour only** | V5 session driver | Extract the contract; the implementations are cycled |
| **No** | V7 findings, `github/` as a tracker, component library, orchestrator pair | The idea travels, the code does not |

## The pattern worth noticing

The three strongest candidates are all **hard-won operational knowledge**, not
tidy abstractions:

- how to ask a human a question and not strand the agent
- how to decide whether the machine can take more load
- how to talk to a piece of hardware reliably across suspend and hotplug

None of them are the layers a diagram would suggest. That is the argument for
slicing by capability rather than by directory.
