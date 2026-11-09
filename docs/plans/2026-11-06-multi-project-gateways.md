---
title: Multi-project, multi-gateway Aiur - Plan
type: feat
date: 2026-11-06
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: operator-scope
execution: code
---

# Multi-project, multi-gateway Aiur - Plan

## Read this first

- **What changes.** One daemon per machine (a **gateway**) runs several repositories (**projects**). Ticket
  ownership becomes a durable record on GitHub that only one gateway can win. Any CLI command can target another
  gateway with `--gateway`, and the receiving gateway decides what each peer may do. A project-first dashboard reads
  every reachable gateway.
- **The atomic-claim answer.** No issue-level GitHub write (labels, assignees, comments, body) is a compare-and-set.
  A git ref is: GraphQL `updateRefs` with an expected old value is documented as atomic. Ownership lives in one ref
  per ticket; a `gateway:<label>` label mirrors it for people (KTD-2). A spike confirms the error shapes first.
- **What exists already.** Remote control over HTTPS (`--instance`), a Postgres ticket lease, ownership rules,
  wake fan-out, a roster page, a Stream Deck switcher, and agents that survive a same-machine restart. The plan
  reuses all of them. Evidence: [code-evidence.md](2026-11-06-multi-project-gateways/code-evidence.md).
- **Biggest cost.** One daemon for many projects touches 142 files that read global config and 181 references to the
  orchestrator singleton. A design ticket (MPG-301) fixes the process model before that work starts.
- **Tickets.** 47 work tickets (42 implementation, 5 design or spike) plus 42 research deep dives = 89, in 8 waves.
  Two critical paths of 8 steps each (section "Ticket graph").
- **Kevin's answers (2026-11-06).** He approved the plan. He decided Q2, Q4 and Q5; Q1 and Q3 use the proposed
  defaults, which he did not object to but did not decide (section "Product questions: answers").

---

## Goal Capsule

- **Objective.** Aiur coordinates work across projects and gateways when they are connected. It offers consistent,
  authorised remote CLI control of registered gateways. Every gateway keeps doing useful, correctly owned local work
  when coordination is unavailable.
- **Authority.** Kevin's decisions in the scope (2026-11-06) bind this plan. Where the plan picks a default Kevin did
  not state, it says so and lists it under open questions or KTDs. Suggestions in the scope stay suggestions.
- **Stop conditions.** Stop and report if: MPG-101 finds no atomic create-if-absent on GitHub; MPG-301 concludes that
  one BEAM per gateway cannot isolate projects; a unit would relabel more than 50 issues without a dry run; a unit
  would break an existing `--instance` user or a single-repository install.
- **Tail ownership.** Each ticket is one GitHub issue and one PR. The Executor owns rebuild, restart and live checks.

---

## Decisions

Status words: **Decided** (Kevin), **Accepted** (Kevin accepted a suggestion), **Default, not objected** (the plan's proposed default; Kevin did not object but did not decide it), **Recommended** (the scope's
recommendation, not decided), **Open** (to settle; the plan proposes where noted).

| # | Topic | Result | Status | Where the plan acts |
|---|---|---|---|---|
| 1 | Priority model | Hierarchical project/feature/ticket priority, separate from allocation | Decided | KTD-7, MPG-401/402 |
| 2 | Global home | Nook holds global state; local snapshots; independent operation | Decided | KTD-8, S4 |
| 3 | Repo vs global state | Feature and Build Order definitions in repos; live cross-project order and overrides on Nook | Accepted | Config layers |
| 4 | Store down, shared repo | Ownership on GitHub persists; skip the offline machine's reserved work | Decided; atomic protocol proposed (KTD-2) | KTD-2, Q3 |
| 5 | Conflicting changes | Latest change, audited, no loops, human intent first | Decided; exact protocol open for MPG-403 | KTD-8, MPG-403 |
| 5a | Executor overriding a human dashboard change | Only with explicit force and a reason naming the overridden change; shown as a takeover (Q4) | Decided | Reconciliation rule 3, MPG-405 |
| 6 | Cross-machine queue authority | Local autonomy, explicit shared changes, no ping-pong | Decided; scheduler Open | MPG-401 |
| 7 | Delegation | Target gateway executes; its Executor reviews and merges; durable waiting | Decided in part; routing Open | KTD-11, Q2 |
| 8 | Executor count | Flexible; one Nook Executor may supervise both; no automatic PC replacement | Decided | MPG-502 |
| 9 | Daemon restart | Running agents keep running | Decided; implementation Open | MPG-308 |
| 10 | Per-project reload and pause | Recommended by the scope | Recommended | MPG-308 |
| 11 | Pause and limits | Pause one machine and pause all; machine-wide agent capacity | Decided | MPG-307, MPG-406 |
| 12 | Setup | Executors use files; Kevin uses the dashboard; easy setup | Decided in part; exact setup Open | MPG-208, MPG-309 |
| 13 | Dashboard top | Projects and features first; machines secondary | Decided | MPG-601..604 |
| 14 | Existing pages | Multi-project overview; keep detailed project views; machine filters | Decided | MPG-603 |
| 15 | Priority editing | Cross-project queue, later drag-and-drop at all levels, human intent first | Decided; editor later | Out of MVP |
| 16 | Failures on the dashboard | Offline is never idle; show unknown and last-known age | Existing requirement | MPG-209, MPG-603 |
| 17 | Sign-in | Browser to daemon over Tailscale from one aiur.dev URL | Firm architecture; auth Open | MPG-601 |
| 18 | First version | PC and Nook on the Aiur repo; second repo on one; outage tests | Accepted | MPG-701 |
| 19 | Order of work | Incremental multi-machine MVP; Executors fill gaps by hand | Decided direction; sequence is a suggestion | Milestones |
| 20 | Out of scope | Advanced editing and automation later; other exclusions recommended | Partly decided | Scope boundaries |
| 21 | Offline alerts | Alert when a machine goes offline, not when it returns | Decided | MPG-408 |
| 22 | Alert debounce and dedupe | Recommended | Recommended | MPG-408 |
| 23 | Reconnect | Automatic, honouring pause and ownership | Decided | MPG-406 |
| 24 | One daemon per machine | Firm, even though a crash pauses all local projects | Decided | KTD-4 |
| 24a | Focus | Finish one feature at a time where possible, but never leave slots idle | Decided | MPG-401 |
| 25 | Moving a project in the queue | Gives first access to slots, not exclusive use | Decided | MPG-401 |
| 26 | Allocation algorithm | Delegated to a design agent | Decided | MPG-401 |
| 27 | Durable Decision ids, claimable Decisions | Recommended | Recommended | MPG-502 |
| 28 | Unknown repo on delegation | Refuse, or wait with a visible label; no auto-clone (Q2) | Decided | MPG-501 |
| 28a | Unify `agent:`/`nuc:` state prefixes (Q1) | Yes, after the first ownership test (MPG-109) passes, as a separate dry-run migration | Default, not objected | Migration step 5 |
| 28b | Who may move a ticket from an offline owner (Q3) | A human, or an Executor with `tickets` rights; an online owner releases first unless a human forces it locally | Default, not objected | MPG-106 |
| 29 | Gateway naming | A gateway is a machine running an Aiur environment | Decided | KTD-1 |
| 30 | CLI target | Global `--gateway` across applicable commands | Decided | KTD-6, MPG-202 |
| 31 | Management | `gateway` namespace: registration, discovery, status, workload | Decided | MPG-206..209 |
| 32 | Discovery | Automatic where practical plus manual; Tailscale not required | Decided | MPG-207, MPG-208 |
| 33 | Verify identity before auto-enrol; stable ids independent of address | Recommended | Recommended | KTD-1, KTD-10 |
| 34 | Trust | Per-peer, directional; easy human-approved full mutual trust | Decided | KTD-9, MPG-206 |
| 34a | Default grant in a new invite (Q5) | Read-only; full mutual trust takes one command per side, confirmed by a signed-in human | Decided | MPG-206, MPG-208 |
| 34b | Write authority over a gateway | Only the target gateway can grant another gateway write actions over it: through its own local config, CLI or dashboard, confirmed by a human signed in on that gateway. No self-grant, no grant by a third gateway, no grant by remote command even from a fully trusted peer | Decided | KTD-9, MPG-206, G10 |
| 34c | Where grants live | In the receiving gateway's registry config, in its peer entries (S2): the enforced source of truth; CLI and dashboard edit it; a hand edit is equally valid; secrets only referenced; no remote command can write it | Decided | KTD-9, MPG-206 |
| 39 | Merge the plan and file all 89 tickets | Approved | Decided | Ticket graph |
| 35 | Remote operations | The full applicable CLI surface | Decided | MPG-203 |
| 36 | Offline interactive requests | Fail at once; no queue in the MVP | Accepted | MPG-204 |
| 37 | Icons | Separate design effort; expose accurate states | Decided | MPG-601 |
| 38 | `--gateway` vs `--instance`; permission schema; transport | Technical design | Open; proposed here | KTD-6, KTD-9, KTD-10 |

---

## Product Contract

### Problem frame

- Aiur runs one daemon per repository. Two machines share the Aiur repository today by giving each daemon its own
  state-label prefix (`agent:`, `nuc:`); a guard skips tickets carrying the other prefix, but no claim is atomic.
  Without the Postgres store nothing else stops double dispatch, and todo claims are written after the agent starts.
- Capacity, pause, queue and priority are per daemon, so a machine cannot share slots across repositories.
- `--instance` reaches another daemon, but write tokens are all-or-nothing, three allowlisted commands are blocked by
  the CLI gate, and nothing records which gateway a token belongs to.

### Requirements

- **R1** One daemon per gateway manages every configured project; single-project installs behave as today.
- **R2** Machine capacity is shared across projects; each project and feature may have a lower limit.
- **R3** Priority (project, feature, ticket) decides first access to free slots; it never raises a limit.
- **R4** A ticket is worked by at most one gateway. Ownership is durable on GitHub and changes only by explicit
  reassignment. Ambiguous ownership means skip.
- **R5** With Nook, Postgres, Khala or an Executor down, each gateway keeps dispatching tickets it owns or can claim.
- **R6** Running agents survive a daemon restart; one project's change does not disturb another's agents.
- **R7** Shared intent (cross-project order, overrides, pause-all) reconciles deterministically, keeps human intent
  first, never republishes a remote change, and works offline with a local cache and change log.
- **R8** `--gateway` targets any remote-capable command; `--instance` keeps working; local-only commands say so.
- **R9** A `gateway` namespace registers, discovers, inspects and removes gateways and manages directional grants.
- **R10** The receiving gateway enforces grants; an Executor cannot raise its own grants; every remote write is
  audited with origin gateway, actor, request id and outcome.
- **R11** A command to an unreachable gateway fails at once and says whether the outcome is unknown; nothing queues.
- **R12** A project-first dashboard shows every reachable gateway; an unreachable one is `unreachable` with
  last-known age, never zero or idle.
- **R13** Alert when a gateway goes offline, not when it returns (decided); debounce and one alert per outage
  (recommended, adopted here).
- **R14** Delegation is ownership transfer; the receiving gateway's Executor reviews; delegated work waits on GitHub.

### Acceptance tests

Run live on PC and Nook (MPG-109, MPG-210, MPG-701).

| Id | Test |
|---|---|
| A1 | PC and Nook dispatch on the Aiur repo for 30 minutes: no ticket gets two agent runs |
| A2 | One daemon manages a second repository |
| A3 | Capacity is shared across projects: running total never exceeds machine capacity |
| A4 | Lower-priority work uses otherwise idle slots |
| A5 | Nook down, PC down, Postgres down (each in turn): the other gateway keeps dispatching its own work |
| A6 | An offline gateway's tickets stay reserved; the other skips them; explicit transfer works |
| A7 | Reconnect after offline edits on both sides: one final order, no oscillation over 30 minutes |
| A8 | A running agent survives a daemon restart with `--keep-agents` |
| A9 | Nook's Executor delegates a ticket to PC; PC runs it; PC's Executor reviews the PR |
| A10 | The dashboard loads with one gateway unreachable and labels it so |
| A11 | Pause one gateway; pause all |
| A12 | A gateway offline during pause-all comes back paused |
| G1 | Nook and PC registered; list shows registered vs reachable and accurate last seen |
| G2 | Discovery on the tailnet; manual registration with no Tailscale |
| G3 | A read command with `--gateway` reaches the intended gateway (identity pin checked) |
| G4 | An authorised remote write is enforced and audited by the receiver |
| G5 | Unauthorised writes are refused, including an Executor granting itself more |
| G6 | A remote gateway's agents and ticket owners are shown; an offline one is not shown as idle |
| G7 | A command to an unreachable gateway fails promptly and clearly; nothing is queued |
| G8 | Delegated tickets stay owned on GitHub while remote commands to the owner fail |
| G9 | Existing `--instance` scripts and local CLI behave as before |
| G10 | A peer with full trust on its own side tries, by remote command, to grant itself or a third gateway write access on a target: the target refuses, changes nothing and audits the denial |

### Scope boundaries

- **Out of the MVP (scope):** drag-and-drop editor, allocation editing, automatic allocation optimisation, automatic reassignment, automatic cross-gateway delegation, hosted cloud workers, native mobile app, remote voice, full Stream Deck targeting, multi-user organisations, consolidated historical analytics.
- **Not in this plan:** moving a running agent between gateways; a durable cross-gateway message queue; gateway icon artwork; replacing the Postgres lease store.

---

## Planning Contract

### Key technical decisions

- **KTD-1 Gateway identity is the machine id.** `gateway_id` = the 26-character `machine_id` in `identity.json`;
  `gateway_label` = `machine_label` ("PC", "Nook"). Addresses are mutable registry data. The existing `instance_id`
  stays for compatibility. The machine file's `gateway:` section is the paired-phone listener of the planned
  `machine-gateway` process (`docs/research/aiur-mobile-and-platform/`); it keeps its name, and MPG-301 decides
  whether that process folds into the one gateway daemon.
- **KTD-2 Ownership lives in one git ref per ticket, written only by compare-and-set.** Ref
  `refs/aiur/owners/<ticket>` (namespace confirmed by MPG-101; the fallback `refs/heads/aiur-owner/<ticket>` would
  fire push webhooks, CI and Aiur's own `branch.push` wake, so it is used only if those ignore the prefix) points
  at a commit holding `owner.json` (S1). Claim = `updateRefs` with zero `beforeOid`; transfer and release = advance
  with the observed `beforeOid`. Only the documented or MPG-101-observed "lost" responses mean lost; everything else
  is unknown, and unknown means skip. A `gateway:<label>` label is a projection. Ref and label disagreeing = skip and
  alert. Evidence: [github-claim-protocols.md](../research/multi-gateway/github-claim-protocols.md).
- **KTD-3 The Postgres lease becomes an optimisation.** It still prevents two runs of one owned ticket and reports
  liveness; it never grants or revokes ownership. Claims on GitHub work with the store down (R5).
- **KTD-4 One BEAM per gateway, one supervision tree per project.** Project processes carry a project context that
  config reads; per-project singletons register through `Aiur.ProjectRegistry`. Machine-level services (HTTP, GitHub
  budget, agent socket, alerts) stay single. MPG-301 confirms this against the 27 named singletons.
- **KTD-5 A capacity broker grants slots machine-wide.** Orchestrators ask `Aiur.Gateway.Capacity`; MPG-402 orders
  grants by priority. Running agents are never preempted.
- **KTD-6 `--gateway` reuses the `--instance` transport and registry.** Same file, same HTTPS control call, same exit
  codes. Registry entries gain optional `gateway_id`, `label`, `tls_pin_sha256`. Names, labels and ids all resolve.
  `--instance` stays a documented alias; giving both is an error. `--project` selects a project on a gateway.
- **KTD-7 Priority and allocation are separate inputs to one pure allocation function** (MPG-401).
- **KTD-8 Shared intent is a change log with per-writer slots** (section "Reconciliation").
- **KTD-9 Permissions are a receiver-side, deny-by-default table per peer.** Categories: `read`, `message`,
  `executor`, `agents`, `tickets`, `config`, `trust`. `trust` is never granted to a peer. Grant changes are refused
  over the network; locally a human or Executor may grant `read`, and wider grants wait for a human signed in on
  that same gateway (Kevin decided: the target gateway authorises any write takeover of itself).
  Capability tokens (macaroons, Biscuit, UCAN) are rejected for now: no Elixir libraries, and attenuation does not
  stop an Executor asking for a wider token. Evidence:
  [gateway-enrollment-and-permissions.md](../research/multi-gateway/gateway-enrollment-and-permissions.md).
- **KTD-10 Transport is HTTPS with per-peer bearer tokens; enrolment is a one-time invite pinned to the target.**
  See "Transport and auth options".
- **KTD-11 Delegation is ownership transfer.** No separate routing channel; a gateway without the project waits.
- **KTD-12 Remote writes carry a request id** with stored replay; a lost reply is reported as outcome unknown with a
  safe retry command.

### State schemas

**S1 Ownership record** (`owner.json` in the commit at the ownership ref):

```json
{"schema": "aiur.ownership/v1", "repo": "owner/name", "ticket": "123", "state": "owned",
 "gateway_id": "<26 base32>", "gateway_label": "Nook", "daemon_key": "<instance key>",
 "epoch": 4, "previous_epoch": 3,
 "actor": {"kind": "daemon|human|executor", "id": "<token name or login>"},
 "reason": "dispatch|transfer|release|migration", "at": "2026-11-06T12:00:00Z"}
```

`state: released` keeps the ref. Every claim and transfer sets `epoch = previous_epoch + 1`. "Self" means this
`gateway_id` and `daemon_key`, so two daemons on one machine (before M3, or a test instance) never both own a ticket.
PR-anchored units use ticket `pr-<N>`.

**S2-S6** (registry entry, machine config additions, shared intent tables, audit line, gateway summary) are in
[state-schemas.md](2026-11-06-multi-project-gateways/state-schemas.md).

### Config precedence and provenance

Each field has one owning layer. A higher layer may override a field only where the table allows.

| Layer | Source | Owns |
|---|---|---|
| L0 | built-in defaults | everything, as fallback |
| L1 | machine `~/.aiur/machine` | capacity, projects list, local paths, coordination (peer grants live in the registry config, S2) |
| L2 | user global `~/.aiur/config` | workflow defaults for projects without their own file (today's behaviour) |
| L3 | project `<repo>/.aiur/config` | tracker, prompts, hooks, routing, lanes, Build Order structure, project agent cap |
| L4 | shared intent (Nook store, cached) | cross-project order, overrides, pause-all |
| L5 | runtime `aiur set` (per project) | the keys `aiur set` accepts today |
| L6 | launch flags | `--max-agents` (machine capacity), `--host`, `--pause` |

`agent.skills` is the exception to one owning layer: L2 supplies a default map and L3 merges over it by
dimension and key, the L3 entry winning on the same key (#7870).

Rules: L1 `projects[].max_agents` caps L3 `agent.max_concurrent_agents`; L4 order falls back to L1 `priority` and
L3 `build_order.feature_order` when the store was never reached. Merged results are never written back.
`aiur config explain <key>` prints value, layer, file, and what it overrode (MPG-310).

### Ownership protocol

1. **Eligible?** Dispatch policy as today (labels, dependencies, pause), then ownership.
2. **Read** the ref uncached. Owner is self (gateway id and daemon key): go to 5. Owner is another gateway: skip. Unreadable: skip (`unknown`).
3. **Claim** an unowned or released ticket: create tree and commit with S1, then `updateRefs` with the observed
   `beforeOid` (zeros if absent). `won`: continue. `lost`: skip. `unknown`: skip and re-read next poll.
4. **Project** `gateway:<label>` on the issue (best effort; a mismatch later means skip and alert).
5. **Lease** (if the store is up): take the run lease; refusal means another run is live.
6. **Spawn** the agent with its epoch. Before each push, PR creation or merge request, the guard re-reads the
   ref (at most 30 s old); a moved epoch stops the agent and keeps its workspace.
7. **Release** on close: advance to `state: released`. Transfer: advance with a new owner, epoch + 1.

| Failure | Behaviour |
|---|---|
| Two gateways claim at once | Exactly one `updateRefs` succeeds; the other is `lost` and skips |
| Write applied, reply lost | `unknown`; skip; next poll's uncached read shows the truth |
| Read lags a write | A stale "unowned" makes the claim fail safely; a stale "mine" is bounded by the 30 s fence refresh |
| Postgres down | Claims continue on GitHub; only the run-lease optimisation is off |
| GitHub unreachable | No new claims; running agents continue; nothing dispatches on unknown ownership |
| Gateways partitioned from each other, both reach GitHub | GitHub arbitrates; no effect on safety |
| Owner gateway offline | Its tickets stay reserved; transfer only by explicit command (Q3). With no liveness source (store down, hello unreachable) the owner counts as live. A transfer disables auto-merge on the old owner's PR |
| Two transfers at once | Both advance from the same `beforeOid`; one wins |
| Old owner returns after transfer | Fence refuses its next push; daemon stops the agent, alerts, keeps the workspace |
| Human edits the label | Ref wins; mismatch is skipped and alerted; a label on an unowned ticket is a request, not a claim |
| PR-anchored unit | Same protocol with ticket `pr-<N>`; the lease bypass is removed |

What it cannot promise: a gateway that reaches GitHub writes but reads data older than 30 s could act once more after
a transfer; labels, comments and PR creation cannot be fenced by GitHub. The fence narrows this window; it does not
close it. The duplicate would be visible (two PRs naming the ticket and different epochs).

### Reconciliation

Rules for shared intent (S4), adopted from
[priority-reconciliation.md](../research/multi-gateway/priority-reconciliation.md) and confirmed by MPG-403:

1. Every change has an immutable `change_id` and HLC `(wall_ms, counter, origin_gateway)`; the HLC is persisted and
   never moves backwards.
2. Each register has slots: `human` > `executor` > `default`. The effective value is the highest non-empty slot.
   Changes are folded in HLC order only; within a slot the later change replaces the earlier.
3. An Executor change clears the human slot only with `force: true`, a `reason`, and `supersedes` equal to the human
   slot's current change id; it is shown as a takeover. A forced change naming an older human change clears nothing
   (Q4). So human H1, forced Executor E (supersedes H1), human H2 ends with H2.
4. A later human change always replaces the human slot. Daemons write only `default`. A write is `human` when it
   comes from a signed-in dashboard session or the local CLI without `--as`; `executor` when it carries an Executor
   token or `--as`.
5. `pause` is the exception: the effective value is paused if any slot is paused. A human unpause clears every slot.
   An Executor's later emergency pause therefore always takes effect.
6. A remote change more than 60 s ahead of local time is held, alerted once, and applied when the clock passes it.
7. Applying a remote change stores it under its own id and never touches the outbox; only locally authored changes
   are published. Apply is idempotent by `change_id`; registers are recomputed by folding the sorted change set.
8. Local scheduler choices are never published; publishing needs an explicit command or dashboard action.

### Registry and permission model

- **Registered** (an entry in the caller's registry) and **reachable** (answered within the timeout) are separate.
- **Enrolment.** B runs `aiur gateway invite --grant <categories>` locally; A runs `aiur gateway join <code>`.
  The code carries B's url, gateway id, TLS fingerprint and a single-use secret with a 10-minute expiry. A checks B's
  hello before sending anything. B writes its registry entry for A with `allows` set to the invited categories. Reverse access needs an invite
  on A: grants are directional. `gateway trust <peer> --full` grants every category except `trust`.
- **Discovery** lists tailnet peers and registry entries that answer hello, marked `discovered (not enrolled)`.
  Discovery never grants anything. Manual `gateway register <name> --url --token-file` needs no Tailscale.
- **Enforcement.** The receiver checks: token valid and listed in the peer entry's `allows.credentials`, token
  categories ∋ category, the entry's `allows.categories` ∋ category (default `[read]`), `dashboard_writable` for writes. `trust` is never reachable remotely.
- **Where grants live (Kevin decided).** In B's gateway registry config, in B's entry for each peer (`allows`, S2).
  That file is what B enforces. B's CLI and dashboard grant actions edit it; a hand edit on B is equally valid and
  takes effect on reload. Credentials are only referenced from it. No remote command can write it.
- **Who may grant (Kevin decided).** Write authority that gateway A holds over gateway B exists only if B grants
  it, on B. Grant, revoke and invite are refused over the network, whatever the caller's grants, so A cannot grant
  itself access, a third gateway cannot grant it, and a fully trusted peer cannot either. Locally on B, `read` may be
  granted by any local actor. Through B's CLI, a write category or `gateway trust --full` is written to the file
  only after a human signed in on B's dashboard (Google or passkey) confirms the human-required Decision it raises;
  no client token can confirm it. The dashboard grant action needs that same session. A TTY is not proof of a person: Executors drive terminals.
- **Revocation and rotation.** `gateway revoke <peer>` empties the entry's `allows` and revokes its tokens. `gateway rotate <peer>`
  overlaps old and new tokens for 10 minutes.

### Remote CLI targeting and `--instance` compatibility

- First-argument selector `--gateway <name|label|id|all|local>`; same gate, transport and exit codes as `--instance`
  (`code-evidence.md` §3). `all` stays read-only.
- Gateway-scoped commands (status, agents, pause, capacity) need no project. Project-scoped commands (queue, lane,
  feature, build-orders, ticket) take `--project`; a single-project gateway needs none.
- Local-only commands (run, stop, restart, init, doctor, upgrade, login, token, pre-pr, build) refuse a selector with
  `<cmd> is local to the gateway's host; run it there` (exit 64).
- The CLI gate and the server allowlist are tested for parity (MPG-203).

### Transport and auth options

| Option | Fit | Verdict |
|---|---|---|
| HTTPS + per-peer bearer token on the existing control API | Works on any network; already shipped | **Recommended** (MVP) |
| Tailscale identity (`WhoIs`, tags, app capabilities) | Strong identity on a tailnet; not available off it | Optional discovery and dashboard sign-in aid; never required |
| Pinned self-signed TLS (`tls_pin_sha256`) | Off-tailnet without a public certificate | Supported for CLI; browsers cannot use it |
| mTLS with per-gateway certificates | Stronger channel binding | Later; tunnels that terminate TLS defeat it |
| Requests signed with the existing Ed25519 machine key | Replay protection independent of TLS | Later hardening |
| Capability tokens | Offline delegation between holders | Rejected for now (KTD-9) |

**Dashboard limitation, flagged and not resolved here.** The decided architecture is browser to daemon over
Tailscale. A non-Tailscale gateway is reachable from a browser only with a publicly trusted certificate (for example a
tunnel); pinned self-signed endpoints cannot be shown. Browsers also restrict public pages calling private-network
addresses. The research suggests proxying peers through the browser's own gateway; that would change a decided
architecture, so MPG-601 states the trade-off for Kevin rather than adopting it.

### Migration from today's two gateways

1. Ship ownership code with `instance.ownership: off`.
2. `aiur ownership migrate --map agent=<PC id> --map nuc=<Nook id>` dry run; count and record the population
   (open tickets per prefix, ambiguous count). Then `--apply`.
3. Set `instance.role: primary` on exactly one gateway per repository and `secondary` on the other, so that
   repository-wide services (landing watch, main watch, quarantine lifter) run once even with the store down.
   Turn `instance.ownership: github` on both; the cross-prefix guard stays. Run MPG-109.
4. Move each gateway to `projects:` mode one at a time (MPG-309 state migration, dry run first).
5. Unify the prefixes after MPG-109 passes, as a separate dry-run migration (Q1: default, not objected). Nothing
   in the MVP depends on it.

Rollback: set `instance.ownership: off`; refs are inert. Projects mode rolls back by emptying `projects:`.

### Security

- No secret in any repository file: registry, tokens, grants and project paths live under `~/.aiur`, mode 0600.
- Ownership refs are readable by anyone who can read the repository; they name gateway labels only. Choose labels
  that reveal nothing private.
- Receivers enforce grants; grant changes are local, and anything wider than `read` needs a signed-in human.
  Executors use their own tokens.
- Identity pinning refuses a response from the wrong gateway; invites pin the target before any secret is sent.
- The hello endpoint returns id, label, build and fingerprint only, and can be turned off.
- The control API is never exposed on a public tunnel without a token; Funnel-style listeners carry no identity.
- Every remote write, denial and grant change is audited (S5).

---

## Product questions: answers

| # | Question | Answer | Status | Why |
|---|---|---|---|---|
| Q1 | After ownership is proven, unify the `agent:`/`nuc:` state prefixes into one? | Yes, after MPG-109 passes, as a separate dry-run migration | Default, not objected | Ownership moves to the ref, so prefixes no longer carry it; one state vocabulary makes the project-first dashboard simpler |
| Q2 | A ticket delegated to a gateway that lacks the project: clone it or refuse? | Refuse, or wait with a visible label; no auto-clone | Decided | Cloning writes code and credentials onto a machine without anyone asking |
| Q3 | Who may move a ticket away from an offline owner? | A human, or an Executor whose token has `tickets`; an online owner must release first unless a human forces it locally | Default, not objected | Kevin requires explicit reassignment; this keeps Executors useful without letting them take live work |
| Q4 | May an Executor override a human dashboard change? | Only with `force` and a reason naming the change it overrides; shown as a takeover | Decided | Matches "human intent first" while keeping Executor autonomy for deliberate changes |
| Q5 | Default grant in a new invite | `read` only; full mutual trust is one command per side, confirmed by a signed-in human | Decided | Discovery must never grant control; full trust stays easy |

---

## Risks

- **Atomic claim rests on undocumented error shapes.** `updateRefs` atomicity is documented; its mismatch error and
  custom-namespace acceptance are not. MPG-101 measures them before any code depends on them.
- **Unfenceable writes.** Labels, comments and PR creation cannot carry an epoch; the fence narrows, not closes, the
  window after a transfer.
- **Refactor size.** 142 files read global config; 181 references name the orchestrator; 27 modules are named
  singletons. MPG-301 must size the batches, and M3 is the longest lane.
- **Shared GitHub budget.** Gateways using one GitHub App share secondary write limits (80 per minute); each claim
  costs about four writes.
- **Browser access.** Cross-origin and private-network rules may block the decided direct browser-to-daemon model on
  some browsers (MPG-601).
- **Restart scope.** In projects mode a daemon crash pauses dispatch for every local project (accepted by Kevin).

## Sources

Operator scope of 2026-11-06 (private; summarised in the decisions table);
[code evidence](2026-11-06-multi-project-gateways/code-evidence.md); the three prior-art reports cited above and their
notes in `docs/research/multi-gateway/notes/`; PR #6902 (unmerged plan); issues #5938 and #5974 (parked).

---

## Implementation Units

Each unit is a milestone; its tickets are the work packets. Milestone order follows the scope's suggested sequence
(a suggestion, not Kevin's decision), with the gateway track of scope §11.7 as M2 in parallel with M1.

| Unit | Milestone | Tickets | Independently testable by |
|---|---|---|---|
| U1 | M0 Contracts | MPG-001, 002 | unit tests; identity in every response |
| U2 | M1 Durable ownership | MPG-101..109 | MPG-109 live: A1, A5, A6 with today's per-repo daemons |
| U3 | M2 Gateways and remote CLI | MPG-201..210 | MPG-210 live: G1-G10 |
| U4 | M3 One daemon, many projects | MPG-301..311 | two-project test VM; A2, A3, A8 |
| U5 | M4 Scheduler and shared intent | MPG-401..408 | allocation table tests; A4, A7, A11, A12 |
| U6 | M5 Executors and delegation | MPG-501, 502 | A9, G8 |
| U7 | M6 Project-first dashboard | MPG-601..604 | browser tests; A10 |
| U8 | M7 MVP acceptance | MPG-701 | all of A1-A12 and G1-G10 |

Contracts: [M0-M1](2026-11-06-multi-project-gateways/tickets-m0-m1.md),
[M2](2026-11-06-multi-project-gateways/tickets-m2.md), [M3](2026-11-06-multi-project-gateways/tickets-m3.md),
[M4-M7](2026-11-06-multi-project-gateways/tickets-m4-m7.md).

## Ticket graph

**Kinds.** 42 implementation tickets, each blocked by its `kind:research` deep dive (`MPG-<n>R`, 42). Five
design or spike tickets have none: MPG-101 (spike), 301, 401, 403, 601 (design agents for the process model,
allocation, conflict ordering and dashboard). Research tickets of tickets that depend on a design ticket also depend
on it. Total 89.

**Lanes.** `lane:ownership`, `lane:gateway-cli`, `lane:gateway-trust`, `lane:multi-project`, `lane:scheduler`,
`lane:intent-sync`, `lane:executor`, `lane:dashboard`, `lane:acceptance`.

**Typed edges.** `depends_on` as listed in each contract. `serializes_with`: MPG-303/304/305 (`application/children.ex`;
merge in that order), MPG-001, MPG-204/205 and MPG-206 (`control_controller.ex`), MPG-103/108 (`shared_lease_dispatch.ex`).
**Filed** 2026-11-06 as #7581-#7669 under epic `mpg`, with 144 native blocked-by links; plan id to issue:
[issue-map.md](2026-11-06-multi-project-gateways/issue-map.md). Gates: none remain. Kevin answered Q2, Q4 and Q5 and let the Q1 and Q3 defaults stand (2026-11-06).

| Wave | Count | Tickets |
|---|---|---|
| 1 | 22 | 101, 301, 401, 403, 601; R001, R002, R201-R210, R407, R408, R501, R502, R701 |
| 2 | 29 | 001, 002, 203, 204; R102-R109, R302-R311, R402, R404-R406, R602-R604 |
| 3 | 7 | 102, 201, 205, 302, 404, 407, 502 |
| 4 | 10 | 103, 106, 202, 206, 303, 304, 305, 405, 408, 602 |
| 5 | 7 | 104, 105, 108, 207, 306, 406, 603 |
| 6 | 10 | 107, 208, 209, 307, 308, 309, 310, 311, 501, 604 |
| 7 | 3 | 109, 210, 402 |
| 8 | 1 | 701 |

**Critical paths (8 steps each).**
`MPG-101 → R102 → 102 → 103 → 104 → 107 → 109 → 701` and
`MPG-301 → R302 → 302 → 303 → 306 → 307 → 402 → 701`.
Waves 1-2 are capacity-bound (51 tickets, mostly research); later waves are dependency-bound. The graph was checked
mechanically: no cycles, no orphans (every ticket reaches MPG-701), every dependency exists.

**Discovery policy.** Findings that block an acceptance test become new tickets in the owning lane. Review findings
go back to the owning ticket. Everything else goes to a deferred list in the research doc; nothing grows the backlog
on its own.

---

## Verification Contract

- Each implementation ticket: its listed tests, run under an isolated `HOME` (never the real one), plus CI on the PR
  head. Each **[fails without]** check is shown failing with the production hunk reverted, per AGENTS.md.
- Launcher: `packaging/npm/aiur-cli/test/launcher-*.test.mjs`. Docs: `scripts/check-config-docs.py`,
  `website/docs-app/scripts/check-cli-reference.sh`.
- Live: MPG-109, MPG-210 and MPG-701 follow `docs/manual-testing.md` and record evidence with secrets and addresses
  redacted.

## Definition of Done

- All 89 tickets closed; every research doc exists at `docs/research/MPG-<n>.md`.
- A1-A12 and G1-G10 recorded as passing in MPG-701's evidence.
- Single-repository installs and existing `--instance` users pass their current tests unchanged.
- Docs updated: CLI reference (gateway namespace, `--gateway`, `--project`, ownership), configuration (machine
  sections, `instance.ownership`, server keys), concepts (gateways, ownership, shared intent).
