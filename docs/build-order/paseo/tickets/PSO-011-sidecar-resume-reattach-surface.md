# PSO-011 — Sidecar resume, re-attach, and surface reporting

**Kind:** executable

**Provenance:** planned in plan v1

**Complexity:** 2 — policy over PSO-006 primitives inside the driver; small surface, precise rules

**Risk:** medium

**Phase hint:** 3

**Depends on:** PSO-005, PSO-006, PSO-007, PSO-003

**Serializes with:** PSO-009, PSO-010 — all three edit `src/session.ts`; rebase in order 009, 010, 011

**External gates:** none

**Requirements:** R6, R10, R12

**Decisions:** DEC-004, DEC-005, DEC-012

**Design evidence:** 00-design.md sections 5, 6, 7, 9; 01-spike-report.md sections 3, 9, 11; Paseo `packages/protocol/src/messages.ts` (`resume_agent_request`, `AgentDirectoryFilterSchema`), `packages/protocol/src/agent-deep-link.ts`

**Researched at:** 8199f5373 (aiur main), paseo 726067b4, aiur-claude 1.1.0

**Suggested labels:** `complexity:2`, `model:claude`, `phase:3`, `build-lane:paseo-sidecar`; never `agent:todo`

## Outcome

A Paseo-backed thread survives an aiur restart and never duplicates: `thread/resume` re-attaches to the same Paseo agent, `thread/start` re-attaches to a live agent for the same issue and workspace before creating one, and both replies carry a `surface` with the Paseo deep link so core shows 📱 and the link (PSO-003). Every agent the sidecar creates carries the three aiur labels.

## Context and evidence

- Core resume: `Aiur.SessionHandle` stores `thread_id` per issue; `GenericBackend` (PSO-007) sends `thread/resume {threadId}` when a handle exists and falls back to `thread/start` on a JSON-RPC error, mirroring `Aiur.Codex.Handshake.start_or_resume_thread/5`. The sidecar's thread id **is** the Paseo `agentId` (DEC-004), so the handle round-trips unchanged.
- Paseo accepts many agents in one cwd and never refuses (spike section 9). Without re-attach, every aiur restart or re-dispatch would spawn another provider process in the same workspace, the exact two-processes hazard the RC history documents.
- Deep link: `paseo://h/<serverId>/agent/<agentId>` from `packages/protocol/src/agent-deep-link.ts`; `serverId` comes from `/api/status` (PSO-006 `DaemonSession.serverId`). Spike section 11.
- Identity for labels: core sends `cwd` on `thread/start` and `title` (`"<identifier>: <issue title>"`) only on `turn/start`. `src/lib/aiur/agent_environment.ex` sets `AIUR_AGENT_WORKSPACE`, `AIUR_GITHUB_REPO`, and no issue-identifier variable. aiur workspace paths are `<root>/<owner>/<repo>/<issue_id>` (`src/lib/aiur/workspace/layout.ex:32-46`, `issue_workspace_path/2`), so the issue id is the cwd basename.

## Scope

In `src/session.ts` (the `SessionDriver` implementation started by PSO-009):

- **Labels and title.** On create: `labels = {aiur_issue: identity.issue, aiur_repo: identity.repo, aiur_instance: identity.instance}` where `identity` is computed by a new pure module `src/identity.ts`:

```ts
export interface AiurIdentity { issue: string; repo: string; instance: string }
export function deriveIdentity(params: { cwd: string; aiurIssue?: string; env: NodeJS.ProcessEnv; hostname: string }): AiurIdentity;
```

  `issue` = `params.aiurIssue` when core provides it, else the last path segment of `cwd` (sanitized to `[A-Za-z0-9._-]`), `repo` = `env.AIUR_GITHUB_REPO ?? ""`, `instance` = `env.AIUR_INSTANCE_KEY ?? hostname`. Title `"aiur <issue>"` on create; PSO-009 updates it to `"aiur <issue>: <title>"` (truncated to 60) on the first `turn/start` that carries a title, through `update_agent` or the SDK equivalent if one exists, else leave the create title.
- **Re-attach on `thread/start`** (DEC-005): before `createAgent`, call `findAgent({cwd, labels: {aiur_issue, aiur_instance}})`. If a match has status in `idle | running | initializing`, adopt it: subscribe status and timeline, return `{id: agent.id, created_at: Date.parse(agent.createdAt), surface}`. If the match is `running`, `cancel` it first so the new aiur turn owns the input queue, and log it. `error` or `closed` matches are ignored (a `closed` non-archived one is archived to keep the list clean). Only then create.
- **`thread/resume {threadId}`** (DEC-004): `agentRef(threadId).refresh()`; status `closed` or a not-found error → throw `DriverError("thread_not_found")` (PSO-005 maps it to `-32001`, core falls back to `thread/start`, which then re-attaches or creates). `error` status → also `thread_not_found` (a broken agent must not be resumed). `running` → `cancel` first. Otherwise adopt as above and return `{id, created_at, surface}` with `surface` present. If the agent's `cwd` differs from the workspace core will send on the next `turn/start`, log a warning and still resume; PSO-009 rejects a `turn/start` whose `cwd` differs from the thread's.
- **Surface** (DEC-012): `surface = {kind: "paseo", label: "Paseo", url: deepLink(serverId, agentId)}` on every `ThreadInfo` returned from `start` and `resume`. Never log the URL at default verbosity (mirror core's rule for the RC URL, even though this one is not a secret).
- **Idempotency.** Pass `idempotencyKey = "aiur:" + instance + ":" + issue + ":" + sha1(cwd)` on `createAgent` so a retried `thread/start` after a lost reply does not create twice (the SDK exposes `requestId`; check whether `create_agent_request.idempotencyKey` is reachable through `PaseoAgentCreateOptions` and, if not, rely on re-attach alone and record it).

## Non-goals

- Turn mapping, steer, interrupt (PSO-009); the tool bridge (PSO-010); the core-side surface rendering (PSO-003); the core resume passthrough (PSO-007).
- Importing pre-existing Paseo sessions not created by aiur.
- Cross-instance adoption: an agent with a different `aiur_instance` is never adopted.

## Existing owner and reuse target

Builds on PSO-006 `findAgent`, `agentRef`, `cancel`, `archive`, `deepLink`, `DaemonSession.serverId`, and the `FakeDaemon`. Adds `src/identity.ts`.

## Contract and invariants

### Requirements

- PSO-011-R1. Every agent created by the sidecar carries `aiur_issue`, `aiur_repo`, `aiur_instance` labels and a title starting with `aiur <issue>`.
- PSO-011-R2. `thread/start` for an issue and workspace that already has a live agent from the same instance returns that agent's id; no second agent is created.
- PSO-011-R3. `thread/resume` with a live agent id returns the same id and a `surface`; with a `closed`, `error`, or unknown id it fails with `thread_not_found` and nothing is created.
- PSO-011-R4. A `running` agent that is adopted is cancelled first; adoption of an `idle` agent sends nothing to it.
- PSO-011-R5. `surface.url` equals `paseo://h/<serverId>/agent/<agentId>` with both segments URL-encoded, on start and resume alike.
- PSO-011-R6. `deriveIdentity` prefers an explicit `aiurIssue`, falls back to the cwd basename, and never returns an empty `issue` (throws `DriverError("invalid_params")` when both are empty).

Invariants: no Paseo call outside `src/paseo/client.ts`; adoption never changes the agent's labels or mode.

## Refreshable implementation notes

- After PSO-009 lands, `session.ts` owns per-thread state `{agentId, handle, unsubscribe[], activeTurn}`; adoption must populate it exactly as create does, so factor a private `adopt(agent)` used by both paths.
- Whether core sends `aiurIssue` on `thread/start` depends on PSO-001/PSO-007; the cwd-basename fallback makes this ticket independent of that choice. If a later core ticket adds the param, `deriveIdentity` already honors it.
- `AIUR_INSTANCE_KEY` is the per-instance identity variable core uses for its own state dirs (`src/lib/aiur/config/paths.ex`); if it is not exported into the agent environment, the hostname fallback applies. Note which one was observed in the PR.

### Key technical decisions

- Issue identity from the cwd basename rather than a new protocol parameter, because the workspace layout guarantees it and it keeps the sidecar independent of core changes.
- `error`-status agents are not resumed: a resumed broken session would fail the first turn with less diagnostic value than a clean create that re-attaches transcript history through Paseo's own session persistence.
- Adopt-then-cancel for `running` agents rather than refuse, because core only calls `thread/start` when it believes it owns the issue.

## Acceptance and verification

### Agent gate

`test/session/resume.test.ts` and `test/identity.test.ts` with `FakeDaemon`:

- `deriveIdentity`: explicit issue wins; basename fallback; sanitization; empty both → throws; repo and instance fallbacks.
- create sets labels and title; `createdRequests[0].labels` asserted.
- start with a live idle twin → adopted, no create request recorded, surface present.
- start with a running twin → `cancel_agent_request` recorded before adoption.
- start with a closed twin → archived, then a new agent created.
- start with a twin from another instance → not adopted.
- resume live → same id, surface url exact string; resume `closed` → `thread_not_found`; resume unknown → `thread_not_found`; resume `error` → `thread_not_found`; resume `running` → cancel then adopt.
- surface url encodes a server id with reserved characters.
- Coverage 100% on `src/identity.ts` and the resume/adopt paths in `src/session.ts`.

### At-merge gate

- CI job `aiur-paseo` green; the PSO-005 conformance suite still green (no dispatch changes).

### Human/manual evidence

- Against the spike daemon: start the sidecar for a scratch workspace, send `initialize` + `thread/start`, kill the sidecar, start it again, send `thread/resume` with the returned id, confirm the same `agentId` and that `paseo` lists one agent for that cwd. Paste the frames on the PR.

## Failure, security, migration, and accessibility cases

- Adopting an agent that another aiur instance owns would steal its input queue; the `aiur_instance` label check is the guard, and a missing label means never adopt.
- The deep link is not a capability token, but keep it out of default logs to hold one rule with the RC URL.
- No migration: agents created before this ticket lack labels and are simply never adopted.

## Surfaces

- Reads: `fetch_agents_request` with label filter, agent snapshots.
- Writes: `create_agent_request` (labels, title, idempotency), `cancel_agent_request`, `archive_agent_request`.
- Contracts: `ThreadInfo.surface` (consumed by PSO-005 and core PSO-003), `deriveIdentity`.

## Sibling boundaries and open gates

PSO-009 owns turn state and the title update; PSO-010 owns the tool bridge lifecycle across adoption (the bridge must be started for an adopted agent too; coordinate through the shared `adopt` helper); PSO-012 proves restart re-attach end to end.

## Plan context

- [Design and decisions](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/build-order/paseo/00-design.md)
- [Spike report](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/build-order/paseo/01-spike-report.md)
- [Pack index](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/build-order/paseo/README.md)
- [Requirements plan](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/plans/2026-09-09-001-feat-paseo-integration-plan.md)
- Your issue's native parent is the Build Order root; native `blockedBy` edges are the dependency graph — the root issue renders the full picture.
