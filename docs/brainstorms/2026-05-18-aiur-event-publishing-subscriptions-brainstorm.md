---
date: 2026-05-18
topic: Aiur — agent event publishing + subscription system
branch: main
issue: https://github.com/its-everdred/symphony/issues/46
status: ready-for-planning
---

# Aiur — agent event publishing + subscription system

## What We're Building

A cross-agent event bus and subscription model so agents can:

- **Emit events** about their own work (progress, decisions, blockers, research-complete, attention requests, self-pause requests).
- **Auto-receive events** from GitHub (ticket label / comment / status / description, PR open / close / merge / review / comment) and git (new commits — agent's own, externally pulled, or rewritten via rebase).
- **Subscribe** to other tickets / branches / PRs (auto-subscribed to direct blockers and to comments on the agent's own issue+PR; manual subscriptions persist across agents and sessions).
- **Receive events as a single bundled digest** at turn start — never as a mid-turn interrupt.
- **Inspect each other's workspaces** directly on disk (single-machine assumption) when the metadata in an event isn't enough.
- **Inter-agent comms via GitHub comments** — if agent 3 wants to tell agent 2 something, it posts a comment on agent 2's issue or PR; agent 2 is auto-subscribed and receives it in its next digest.

A new **Aiur skill** at `.claude/skills/aiur/` (with `.codex/skills/aiur/` symlinked to it) instructs both runtimes on how to emit, subscribe, read events, and inspect peer workspaces.

## Why This Approach

Today an agent sees only its own ticket. If issue 1 blocks 2 blocks 3, agent 3 has no signal when 1 lands — it has to poll or be told manually. If agent 3 notices a flaw in agent 2's design, there's no channel to inform agent 2. Symphony already has the orchestrator-side data (running set, workspaces, GitHub poll); Aiur adds the publish/subscribe layer on top so this context flows naturally between agents and surfaces in the pane for the operator.

## Key Decisions

### Topic format (AMQP-style routing)

```
<source>.<issue>.<category>.<sub>
```

Four top-level sources:

| Source | Examples |
|---|---|
| `agent` | `agent.MT-25.progress.work-complete`, `agent.MT-25.decision.architecture`, `agent.MT-25.attention.scope-question`, `agent.MT-25.pause.request`, `agent.MT-25.research.brainstorm-complete` |
| `git` | `git.MT-25.commit.agent`, `git.MT-25.commit.external`, `git.MT-25.commit.rewrite`, `git.MT-25.merge.new` |
| `ticket` | `ticket.MT-25.issue.label.added`, `ticket.MT-25.issue.comment.posted`, `ticket.MT-25.issue.status.changed`, `ticket.MT-25.issue.description.edited`, `ticket.MT-25.pr.opened`, `ticket.MT-25.pr.merged`, `ticket.MT-25.pr.review.posted`, `ticket.MT-25.pr.comment.posted` |
| `system` | `system.MT-25.agent.started`, `system.MT-25.agent.finished`, `system.MT-25.pr.opened` |

Subscription patterns support AMQP wildcards: `*` matches one segment, `#` matches zero or more.

```
ticket.MT-11.#              → all of MT-11's ticket+PR activity
git.MT-11.#                 → all git activity on MT-11's branch
*.MT-11.#                   → everything from MT-11 (operator's "watch this ticket")
agent.*.attention.#         → all attention events across all agents (operator monitoring)
```

### Routing class by name prefix

Routing is implicit in the event name's prefix:

| Prefix | Routing class | Effect |
|---|---|---|
| `attention.*` | `:attention` | ❗ lights up in the agent list; visible in digest; clears when operator opens the pane |
| `pause.*` | `:pause` | Soft self-pause: agent finishes current turn, then halts. ❗ shown. Resumes on operator reply. |
| everything else | `:digest` | Goes into the per-issue events log + the next turn's digest |

### Single digest at turn start

Events drain at turn boundary, never mid-turn. When the agent starts a new turn, it sees a single bundled message containing every event since `last_seen_event_id`:

```
[events since 12:01]
  • ticket.MT-11.pr.merged  PR #47 "fix auth" merged
  • git.MT-11.commit.external  a1b2c3 "fix auth" by upstream@example.org
  • agent.MT-14.decision.architecture  "switching from polling to webhooks"
[end events]
```

This is the same drain timing as the operator-message queue from issue #31 — events ride alongside queued operator messages and join the same checkpoint cycle.

### Subscriptions stored on disk per issue

```json
// <logs-root>/MT-25.subscriptions.json
{
  "subscribed_to": [
    {"topic": "*.MT-11.#",  "reason": "blocks"},
    {"topic": "*.MT-14.#",  "reason": "manual"},
    {"topic": "ticket.MT-25.#", "reason": "self-comments"}
  ],
  "last_seen_event_id": 4287
}
```

- **Auto-sub on direct blocker** when GitHub reports `MT-25 is blocked by MT-11`: add `*.MT-11.#` with `reason: "blocks"`. Transitive chains skipped — agent on issue 3 sees only its direct blocker 2.
- **Auto-sub on own comments**: agents are auto-subscribed to `ticket.<self>.issue.comment.#` and `ticket.<self>.pr.comment.#` + `ticket.<self>.pr.review.#`. (No self-sub for agent-emitted events — agent reads its own emit log directly.)
- **Manual sub** via the agent's `aiur_subscribe(topic)` / `aiur_unsubscribe(topic)` tools. Persists across sessions and across agent restarts on the same issue.
- **Cannot force-sub others**: there is no API for agent N to subscribe agent M to anything. Agents control only their own inbound feed.

### Self-loop filtering at delivery

Agents share an account (one GitHub user, one git identity). When an event is being delivered to a subscriber, the dispatcher checks whether the event's source identifier matches the subscriber's issue identifier — if so, the event is dropped at delivery (not at publish). The event still lands in the publishing agent's emit log; it just doesn't loop back as a received event.

### Emit API reuses `emit_alert`

No new tool to learn. Agents emit events through the existing `emit_alert(name, message)` tool. Aiur intercepts based on name prefix and routes to subscribers in addition to its existing alert behavior (log, sound, pane notification).

```elixir
emit_alert("progress.work-complete", "Pushed PR #47")        # → digest
emit_alert("attention.scope-question", "OK to drop X?")      # → ❗ + digest
emit_alert("pause.request", "Need scope approval")           # → ❗ + self-pause + digest
```

Reserved system scopes from the existing `Alerts` module (`task.*`, `agent.*`, `chat.*`) remain system-owned. The new `agent.<self>.*` (and the source-prefixed `git.*`, `ticket.*`, `system.*`) are Aiur's namespaces.

### Manual subscribe / unsubscribe tools

```elixir
aiur_subscribe("ticket.MT-14.#")              # watch all of MT-14
aiur_subscribe("git.MT-14.commit.#")         # narrower — just commits
aiur_unsubscribe("git.MT-14.#")              # remove a subscription
```

Topic strings accept the same wildcard syntax as auto-subscriptions. Subscriptions persist to `<logs-root>/<issue>.subscriptions.json`.

### Agent self-pause

Emitting `pause.request`:

1. ❗ appears next to the agent in the agent list immediately.
2. The agent finishes its current turn (soft pause, not hard interrupt).
3. Agent's `work_state` transitions to `:paused`.
4. Operator opens the pane, sees the event + agent's last messages.
5. Operator types a reply → agent unpauses, ❗ clears, the reply is treated as the next operator turn.

### Visual signal in the agent list

`attention.*` and `pause.*` events from any agent flip that agent's circle in the agent list to ❗ (heavy exclamation, distinct from the existing state circles 🟢 / 🟡 / 🔴 / ⚫). The flag persists until the operator opens that agent's conversation pane (which clears it). The operator-side "did I read it" state is per-operator-pane, not per-event.

### Pane render: new `:event` role

Received events render inline in the conversation pane transcript as a new `:event` role with its own muted color and tag:

```
 event   ticket.MT-11.pr.merged  PR #47 "fix auth" merged
 agent   ack — my dependency just landed
 event   git.MT-11.commit.external  a1b2c3 "merge upstream"
```

Same coalescing / wrapping rules as other roles. Events do NOT block or interrupt — they're displayed when they arrive, and they're also included in the next turn's digest for the agent.

The pane shows **received** events; events the agent itself emitted live in a separate emit log (so the operator can see what the agent SAW, distinct from what it SAID).

### Bootstrap: everything since last seen

`<logs-root>/<issue>.subscriptions.json` tracks `last_seen_event_id`. On agent start (or restart), the orchestrator builds a startup digest of every event from subscribed topics with id > `last_seen_event_id`, delivers it as the first turn's pre-digest, and advances the cursor.

### Git event detection

A per-repo notify script + workspace-level symlinks + HTTP callback into BEAM.

```
~/.symphony/hooks/
└── its-everdred-symphony/
    ├── notify.sh                     ← shared callback, one source of truth per repo
    ├── post-commit                    ← thin shim: exec notify.sh "commit"
    ├── post-merge                     ← thin shim: exec notify.sh "merge"
    ├── post-rewrite                   ← thin shim: exec notify.sh "rewrite"
    └── .secret                         ← per-install random token for callback auth

<workspace>/.git/hooks/post-commit    → symlink → ~/.symphony/hooks/<repo>/post-commit
<workspace>/.git/hooks/post-merge     → symlink
<workspace>/.git/hooks/post-rewrite   → symlink
```

The notify script POSTs to `http://127.0.0.1:4000/aiur/git` with the SHA, author, subject, and event kind. Symphony's HTTP server has a new `/aiur/git` endpoint that maps workspace → issue, distinguishes agent-authored vs external commits by comparing the author email, and publishes `git.MT-25.commit.{agent,external,rewrite}` events. Hooks run in the background (`curl &`) so git operations are never blocked.

Hook installation happens in `Workspace.run_after_create_hook` for every new workspace and is idempotent. The shared script per repo means upgrades are one-edit / all-workspaces.

### GitHub event detection

For v1: piggyback on the orchestrator's existing 30-second tracker poll. On every poll, compare `state.last_polled_issues` to the new fetch and publish `ticket.MT-25.label.added` / `ticket.MT-25.status.changed` / `ticket.MT-25.description.edited` events for diffs. Comments and PR review events require a deeper poll (GitHub timeline API or webhooks).

Webhooks are the right long-term answer but require public-facing URLs (or ngrok-style tunnels) and are out of scope for v1. v2: add a webhook endpoint at `/aiur/github` and instruct operators to point GitHub at it via the existing webhook config.

### Single-machine assumption + workspace inspection

All agents run on the same machine. Each workspace is at `~/code/symphony-workspaces/<issue_id>/`. When an agent receives an event with a SHA or workspace identifier, it can directly `git show <sha>` or read files in another agent's workspace path — no push required. The Aiur skill instructs the agent:

- Workspace root: `$SYMPHONY_WORKSPACE_ROOT` (env var the agent can read)
- Read-only convention: never modify files in another agent's workspace
- For uncommitted changes: read the working tree directly (`cat <peer-workspace>/path/to/file.ex`)
- For committed changes: use `cd <peer-workspace> && git show <sha>`

This lets an agent on issue 3 inspect work-in-progress on issue 1 BEFORE issue 1's agent has pushed anything.

### Inter-agent comms via GitHub comments

The canonical inter-agent channel is **GitHub comments**:

- Agent 3 wants to tell agent 2 about a flaw → posts a comment on issue 2 (or its PR).
- Agent 2 is auto-subscribed to its own issue/PR comments → receives the event in its next digest.
- No direct agent-to-agent RPC. All inter-agent comms are auditable in GitHub history.
- An agent **cannot** force another agent to subscribe to its own ticket — only its own subscribed feed is mutable.

### Skill layout

```
.claude/skills/aiur/
├── SKILL.md                          ← frontmatter + concise body (<50 lines), points to references
└── references/
    ├── overview.md                    ← what Aiur is, when to use it
    ├── event-taxonomy.md              ← full event-name table with examples
    ├── emit-and-subscribe.md          ← emit_alert and aiur_subscribe API reference
    ├── inter-agent-comms.md           ← "use GitHub comments to tell another agent something"
    └── peer-workspaces.md             ← workspace inspection rules (read-only, paths, examples)

.codex/skills/aiur                    → symlink → ../../../.claude/skills/aiur
```

Symlink lets both runtimes load the same content natively, eliminates duplication. The directory IS the marketplace artifact — `tar -czf aiur-skill.tgz .claude/skills/aiur/` packages it ready to submit. AGENTS.md unchanged.

### Events log file format

```
<logs-root>/<repo>.<issue>.events.log
```

Append-only, one event per line:

```
2026-05-18T01:42:00Z [recv] agent.MT-11.progress.work-complete Pushed PR #47
2026-05-18T01:42:01Z [emit] agent.MT-25.attention.scope-question OK to drop X?
2026-05-18T01:45:12Z [recv] git.MT-11.commit.external a1b2c3 "fix auth" by upstream@example.org
2026-05-18T01:50:00Z [recv] ticket.MT-11.pr.merged  PR #47
```

Tags `[recv]` and `[emit]` differentiate received vs emitted. Pane and existing per-issue log show **received** only; `[emit]` lines are in the same file for operator forensics and agent self-inspection but don't ride into the pane feed.

## Standard agent-emitted event vocabulary

**Principle:** agent-emitted events should add information that auto-events (`git.*`, `ticket.*`, `system.*`) cannot infer from observable state. Routine "I started" / "I finished" signals are skipped because label moves and commits already broadcast them. Agent events carry judgment, rationale, or context the system can't see.

### Research milestones

- `agent.MT-25.research.brainstorm-complete` — pointer to doc + key decision captured
- `agent.MT-25.research.plan-complete` — pointer to plan + scope/risk note
- `agent.MT-25.research.investigation-complete` — what was learned, dependencies surfaced

### Progress (only the irregular one)

- `agent.MT-25.progress.milestone` — agent-defined intermediate checkpoint with rationale. Routine start/end is inferred from `git.*.commit.agent` (first) and `ticket.*.issue.label.added` (workflow transitions).

### Decisions

- `agent.MT-25.decision.architecture` — major architectural choice + why
- `agent.MT-25.decision.scope` — scope cut, added, or refined + why
- `agent.MT-25.decision.deferred` — explicit defer to a follow-up + which issue

### Attention / pause

- `agent.MT-25.attention.scope-question` — needs operator clarification (agent keeps working on safe parts)
- `agent.MT-25.attention.approval-needed` — needs operator approval before proceeding
- `agent.MT-25.attention.review-feedback` — review feedback that needs operator visibility
- `agent.MT-25.attention.dependency-discovered` — newly found blocker (slug is freeform)
- `agent.MT-25.pause.request` — truly blocked; halt after this turn

### Handoff

- `agent.MT-25.handoff.document-updated` — handoff doc has new content + why notable

### Implicit signals (subscribe to these auto events instead of agent equivalents)

| Wanted info | Auto event |
|---|---|
| Agent started work | `git.MT-X.commit.agent` (first one) |
| Implementation done | `ticket.MT-X.issue.label.added` matching `agent:human-review` |
| Review approved | `ticket.MT-X.pr.review.posted` |
| Code merged | `ticket.MT-X.pr.merged` |
| Agent finished | `ticket.MT-X.issue.status.changed` (closed) or `agent:done` label |
| Handoff to next | `ticket.MT-X.issue.label.removed` |

## Documentation split: shared-instructions vs Aiur skill

Reflexes vs capabilities:

**`prompts/shared-agent-instructions.md`** (loaded on every prompt → ~25 lines): the standard vocabulary list above, the `emit_alert(name, message)` one-liner, the "use GitHub comments to talk to another agent" rule, the `pause.request` self-pause rule.

**`.claude/skills/aiur/` skill** (loaded on demand): topic taxonomy diagram, routing class details, `aiur_subscribe` syntax with AMQP wildcards, peer-workspace inspection guide, auto-subscription rules, events log format, bootstrap mechanics, edge cases.

| Shared instructions | Aiur skill |
|---|---|
| Vocabulary the agent uses reflexively | Mechanics the agent looks up when needed |
| 1-line API ("emit_alert(name, message)") | Deep API reference (`aiur_subscribe` patterns, wildcards) |
| "Use GitHub comments" rule (2 lines) | `inter-agent-comms.md` with examples + flow diagrams |
| The pause.request reflex | How attention vs pause routing classes work mechanically |
| | Peer-workspace inspection guide |
| | Auto-subscription rules |
| | Events log file format |

## Open Questions

None remaining — see Resolved Questions section.

## Resolved Questions

| Question | Answer |
|---|---|
| Agent UX for receiving events | Single bundled digest at turn start |
| Subscription storage | Per-issue JSON file on disk |
| Blocker chain depth | Direct blockers only |
| Self-loop avoidance | Filter at delivery (shared account assumption) |
| Emit API | Reuse `emit_alert(name, message)` |
| Routing class | By name prefix (`attention.*`, `pause.*`, else digest) |
| Topic taxonomy | `<source>.<issue>.<category>.<sub>` with AMQP `*` / `#` wildcards |
| PR vs issue events | Symmetric: `ticket.MT-25.issue.*` and `ticket.MT-25.pr.*` |
| Manual subscribe API | `aiur_subscribe(topic)` / `aiur_unsubscribe(topic)` tools |
| Self-pause behavior | Soft: finish current turn, then halt |
| Attention indicator | ❗ in agent list, cleared on operator pane open |
| Pane render | New inline `:event` role |
| Bootstrap | Everything since `last_seen_event_id` |
| Git event detection | Per-repo notify script + workspace symlinks + HTTP callback |
| GitHub event detection | v1: poll-based diff; v2: webhook |
| Inter-agent comms | GitHub comments (no direct agent RPC) |
| Skill location + dedup | `.claude/skills/aiur/` canonical; `.codex/skills/aiur` symlinks to it |
| Workspace inspection | Direct filesystem reads across peer workspaces; read-only convention |
| Events log format | Append-only `<repo>.<issue>.events.log` with `[recv]` / `[emit]` tags |
| Event payload schema | Minimal: `{topic, ts, message}` + source-specific optional fields |
| Standard agent-emitted vocabulary | Lean set (research / decision / attention / pause / handoff / progress.milestone); routine start/end inferred from auto events |
| Doc split: shared vs skill | Shared-instructions = vocabulary + reflexes; skill = mechanics + reference |
| Rate-limiting | None for v1; rely on between-turn bundling. Revisit if digests overflow context. |
| Operator CLI surface | v1 ships without dedicated commands; operators tail the events log file directly. |
| GitHub webhook | Include `/aiur/github` endpoint in v1, disabled by default; users with public deployments enable it via config. v1 poll-diff path always works. |

## Scope Boundaries

### In scope (v1)

- Topic-based pub/sub with AMQP wildcard patterns
- Auto-subscriptions: direct blockers, own-issue + own-PR comments
- Manual subscribe / unsubscribe via agent tools
- Emit through `emit_alert` with prefix-based routing
- `attention.*` + `pause.*` UI signaling (❗ in agent list, pane render)
- Per-issue events log with `[recv]` / `[emit]` tags
- Inline `:event` role in conversation pane
- Per-repo git hook + HTTP callback for commits / merges / rewrites
- Tracker-poll-based GitHub event diff (labels, status, description)
- `.claude/skills/aiur/` + `.codex` symlink with SKILL.md + `references/`
- Peer-workspace read-only inspection documented in skill

### Out of scope (v2 or later)

- Repo-level watchdog clone for external-push detection (covers the rare "human pushed direct to remote without any local clone" case)
- Cross-machine agent topology (Aiur assumes single-machine for v1)
- Rate-limited / batched delivery beyond turn-boundary bundling
- Subscription editing UI in the pane (manage via the existing tools and the on-disk JSON)
- `bin/symphony events tail` / `bin/symphony subscriptions list` operator commands

### Webhook endpoint scope

The `/aiur/github` webhook is included in v1 but **disabled by default**. Users with publicly-reachable Symphony deployments enable it by setting a webhook secret in WORKFLOW.md and configuring GitHub to POST there. v1 always works via the 30s poll path; the webhook is a real-time enhancement when available.

## Related

- Issue #31 — pane-side message queue: same "between turns" drain timing as Aiur events; both ride the same checkpoint hook
- Issue #47 — `bin/symphony repo`: installs the Aiur git hooks during repo bootstrap
- PR #44 (merged) — `AgentPubSub` + `IssueLog` infrastructure that Aiur extends
