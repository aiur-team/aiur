# Multi-Agent Messaging, Roles & Workflow Orchestration — Research Brief

_Part of the `research/optimization-pillars` wave. Maps to Pillar 3 (role/phase-based workflows) and Pillar 4 (agent-to-agent messaging & viewability)._

**Research value: high** — Converging primary-source evidence (framework docs, the A2A spec, token-routing papers, and Anthropic's own multi-agent postmortem) directly supports both halves of the ask: role/skill scoping and typed inter-agent messaging.

## Framework comparison table

| Framework | Roles model | Inter-agent messaging | Workflow/state | Persistence | Borrow? |
|---|---|---|---|---|---|
| **LangGraph** | Nodes = agents, no role schema | Handoff tools return `Command{update, goto}` — state patch + next hop; supervisor's `create_handoff_tool` passes full message history by default | Explicit directed state graph, conditional edges | Checkpointer (memory/Postgres) with time-travel replay | **Yes** — `Command{update, goto}` is a clean "state patch + next actor" primitive, close to a GenServer reply tuple |
| **CrewAI** | First-class `role/goal/backstory` injected into system prompt | Sequential: task output feeds next task's context. Hierarchical: manager delegates via tool calls, **delegation off by default** | Only sequential/hierarchical, no general graph | Task-output chaining, not durable | **Yes** — role/goal/backstory as prompt scaffold; "delegation off by default" as safety default |
| **AutoGen/AG2** | `ConversableAgent` + system message, no taxonomy | GroupChatManager broadcasts to shared topic; speaker chosen via auto/round-robin/graph-eligibility function | Conversation-as-state | Chat history only | Partial — pluggable graph-eligibility speaker selection maps well to phase-gated turn order |
| **OpenAI Agents SDK** (Swarm lineage) | Agent = prompt + tool list | `transfer_to_X()` swaps active agent; **only active agent's instructions are in context, history isn't rewritten** | None — stateless routine chain | Session-scoped only | **Yes** — "handoff swaps persona, not history" is the cleanest phase-transition mental model |
| **Semantic Kernel / MS Agent Framework** | Named agents in 5 canned patterns (Handoff/GroupChat/Magentic-One); SK+AutoGen merging into unified MAF (RC Feb 2026) | Handoff = explicit control transfer; GroupChat = broadcast | Same 5 patterns, all checkpointed | Built-in checkpoint/pause/resume | Marginal — repackages LangGraph/AutoGen ideas |
| **Google A2A** | `Message.role` = user\|agent only, no agent-specialization taxonomy | `Message{messageId, parts[], taskId?, contextId?, referenceTaskIds?}`; `Task` has lifecycle states; `Artifact` is the deliverable | Task-lifecycle state machine | Server-side task store, SSE streaming | **Yes, as schema shape only** — `contextId`+`referenceTaskIds`+typed `Part` union worth copying conceptually, not the HTTP transport |
| **MCP** | N/A — tool/resource exposure | Vertical (agent↔tool), not agent↔agent | JSON-RPC request/response | N/A | Irrelevant to agent-to-agent messaging; matters only if Aiur later exposes skills as tools to external agents |

## Roles & workflow recommendation

Convergent pattern across CrewAI, Claude Code's community subagent catalog, and Anthropic's own orchestrator-worker system: **role = scoped prompt/persona + scoped tool/skill subset + token budget**, not a separate messaging concept. The Claude Code subagent ecosystem independently converges on almost exactly Aiur's proposed set — reviewer, test-writer, refactor-architect, security-auditor, deployment-guard — with tool access gated by role (read-only Read/Grep/Glob for reviewers/auditors vs Read/Write/Edit/Bash for implementers). This validates architect/engineer/reviewer/tester/investigator/coordinator/maintainer as a reasonable v1 preset set: coordinator ≈ CrewAI's manager (delegation, off by default); maintainer ≈ a longer-lived deployment-guard analog.

Token savings are real but come from *routing/exposure*, not role labels alone: RCR-Router reports 25–47% token reduction from per-role budget-constrained context routing; a separate dynamic-instruction-assembly technique reports up to 95% reduction in per-step context by retrieving only the relevant tool specs for that role. Caution: Anthropic's own multi-agent system still burns ~15× the tokens of single-agent chat despite specialization — role-scoping cuts waste, it doesn't make multi-agent free. Reserve role presets for ticket-sized work where the parallelism/quality gain (Anthropic measured +90.2%) justifies the multiplier, not every phase.

> _Aiur note:_ Aiur's refactor loop already runs a de-facto reviewer role (background adversarial reviewers on the biggest PRs, e.g. the T-014/T-016 keystone reviews). Formalizing that as a `reviewer` preset with read-only tools is the lowest-risk first role.

## Typed-message envelope + inbox/thread design

Borrow A2A's envelope *shape*, not its transport:

```elixir
%Aiur.AgentMessage{
  id: uuid, thread_id: uuid,        # ~ A2A contextId
  ref_ids: [uuid],                  # ~ A2A referenceTaskIds
  from: {agent_id, role}, to: {agent_id, role} | :broadcast,
  subject: string,
  parts: [%Part{kind: :text | :diff | :data, content: ...}],  # A2A's typed Part union
  urgency: :low | :normal | :blocking,
  expects_reply: boolean, in_reply_to: uuid | nil,  # email-style threading
  delivered_at: :turn_boundary | :immediate
}
```

Inbox = per-agent GenServer state (or ETS) keyed by `thread_id`. Default delivery is **turn-boundary digest** — deliver at the next natural pause rather than interrupting an active generation — mirroring AG2's broadcast-then-let-selector-decide pattern. `expects_reply: true` with no reply after N turns should surface as a coordinator-visible stall, the analog of AG2's implicit eligibility-check signal.

## A2A/MCP: adopt-later rationale

A2A solves cross-vendor/cross-org discovery (Agent Card + HTTP/SSE + OAuth2/mTLS) — irrelevant when Aiur owns both ends of every conversation. A 2026 adoption retrospective found real production friction even among teams that *do* need cross-vendor A2A — auth/identity management, task-lifecycle edge cases, cross-boundary debugging — concluding "you probably do not need a full agent-to-agent protocol" for single-org systems. MCP is a different axis (agent↔tool). **Recommendation:** build the envelope above natively on the existing event bus now; keep field names A2A-shaped so a later adapter to real A2A is a translation layer, not a rewrite.

## Risks

- Role-scoped skill budgets can starve an agent mid-task if under-provisioned — needs an escalation path, not a hard cap.
- Turn-boundary delivery can silently strand `expects_reply` messages if a role never reaches a natural pause (long tool loop) — needs a timeout/stall signal alongside digest delivery.
- Copying A2A field names without its semantics risks a de-facto incompatible dialect that still costs a future migration.

## v1 cutline

**In:** role presets (prompt + tool subset only, no new process model); `AgentMessage` struct + inbox GenServer + turn-boundary delivery; `thread_id`/`in_reply_to` threading.
**Out:** A2A/MCP wire compatibility; cross-org discovery; hierarchical manager/delegation authority (coordinator starts as router only, not evaluator); hard token-budget enforcement (measure first, enforce later).

## Sources
- [LangGraph handoffs docs](https://docs.langchain.com/oss/python/langchain/multi-agent/handoffs)
- [CrewAI hierarchical process](https://docs.crewai.com/en/learn/hierarchical-process)
- [AG2 GroupChat docs](https://docs.ag2.ai/latest/docs/api-reference/autogen/GroupChat/)
- [OpenAI Swarm README](https://github.com/openai/swarm)
- [A2A key concepts](https://a2a-protocol.org/latest/topics/key-concepts/)
- [A2A adoption reality check 2026](https://www.glukhov.org/ai-systems/comparisons/a2a-protocol-2026-adoption)
- [MCP vs A2A comparison](https://www.truefoundry.com/blog/mcp-vs-a2a)
- [RCR-Router paper](https://arxiv.org/pdf/2508.04903) — 25–47% token reduction via role-aware routing
- [Dynamic system instructions paper](https://arxiv.org/pdf/2602.17046) — up to 95% per-step context reduction
- [Anthropic multi-agent research system](https://www.anthropic.com/engineering/multi-agent-research-system) — orchestrator-worker pattern, 15× token cost, +90.2% quality
- [Claude Code subagents catalog](https://github.com/VoltAgent/awesome-claude-code-subagents)
- [Semantic Kernel handoff orchestration](https://learn.microsoft.com/en-us/semantic-kernel/frameworks/agent/agent-orchestration/handoff)
