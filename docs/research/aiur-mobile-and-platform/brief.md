# aiur: Modular Platform, Mobile, and Watch Research Handoff

## 1. Context and assignment

Start with **`ce-brainstorm`**. Turn this brief into a clearly bounded series of features, clarify each feature’s scope with me, and agree on ordering based on **value added** before making implementation decisions. Once the complete scope is understood, use parallel background agents to deeply **`ce-plan` each feature**, decompose those plans into chunks, and then use parallel agents to research every chunk and produce implementation-ready tickets.

**This assignment is a research and planning project, not an implementation request.** Anticipate eventually building everything described here. The immediate objective is to resolve product questions, investigate the existing code and external constraints, design the boundaries and contracts, and do the thinking upfront so later coding agents can execute narrowly specified tickets without inventing product behavior or architecture.

aiur is an existing suite of coding-agent tools, primarily a dashboard with GitHub label/event-driven orchestration that launches agents to implement tickets. Existing functionality includes complexity tags, build orders, commands, an event bus, Stream Deck integration, and optional voice functionality. Inspect the repository rather than treating this description as complete documentation of current behavior.

A prior research spike proposed decomposing the monolith into independently reusable components, potentially as subpackages and/or separate repositories. **Locate and continue on that same refactor research branch.** There may be a draft pull request; verify rather than assume. Preserve the existing research and separate this expanded scope using feature IDs, directories, and explicit bucket boundaries. Do not create a competing mobile research track on an unrelated branch.

My preference is for the refactor to land before the mobile application, while researching the mobile work independently enough that it can follow shortly afterward. Treat that as a sequencing preference to evaluate against value and dependencies, not permission to make every improvement a prerequisite for mobile.

Throughout this brief, “existing” means reported existing behavior until verified in code. “Research” identifies a decision or capability that has not yet been established.

## 2. Required research workflow

### Phase A — Inspect, inventory, and brainstorm

Inspect the existing refactor plans, branch state, relevant components, configuration, tests, and any associated draft PR. Establish a verified baseline and identify which requested capabilities already exist, partially exist, or are genuinely new. Read before asking questions the repository can answer.

Use `ce-brainstorm` to organize the work into the three buckets below. Keep feature boundaries explicit even where features share infrastructure. Start our conversation with **ordering and value**, not framework selection or implementation details.

An appropriate opening question is:

> Which would remove the most day-to-day friction first: keeping the agent queue full, making agent and executor conversations accessible, or getting notified and responding from a phone or watch?

Then clarify the relative value of the other features, which dependencies genuinely block the most valuable outcomes, and which improvements could ship independently. Show the dependency consequences of different orders. Do not quietly turn “order these features” into “drop the rest from scope.”

Ask as many scope questions as necessary for each feature, **one question at a time**. Use concrete examples when a distinction is abstract. Do not re-ask settled questions from this brief. Distinguish questions I must answer from engineering questions research can resolve. Do not fill unresolved product behavior with silent assumptions.

Before launching deep planning, confirm the feature inventory, intended behavior, scope boundaries, acceptance goals, value-based order, and any assumptions I explicitly authorize. Technical unknowns may remain as named research questions; consequential product decisions must not be hidden inside implementation tickets.

### Phase B — Parallel feature planning

After the brainstorm and full scope are understood, dispatch parallel background planning agents, normally one per independent feature. Each agent must use `ce-plan` deeply, not merely generate a task list.

Give each planner the full relevant context, confirmed decisions, existing research, feature ID, non-goals, dependencies, and shared terminology. Require a feature-level plan covering repository findings, proposed boundaries, alternatives and recommendation, contracts, risks, acceptance criteria, UX/UI design requirements, and decomposition into coherent chunks.

A coordinating agent owns the master index and shared decisions. Assign agents disjoint document paths so they do not overwrite one another. Parallelize independent investigation, not contradictory decisions about the same contract. Reconcile shared interfaces and dependency assumptions before the chunk-level planning pass.

### Phase C — Parallel chunk research and ticket preparation

Dispatch parallel background researchers for the chunks identified by the feature plans. Each researcher must inspect the actual implementation and current authoritative sources relevant to its chunk, then produce a **full implementation plan for every resulting ticket**.

Research all chunks upfront, including later delivery waves. Break large chunks into smaller tickets until each has a bounded outcome, explicit dependencies, known interfaces, a test strategy, and a clear completion condition. Parallel research does not imply that dependent implementation tickets can later run in parallel.

Do not leave tickets saying “figure out notifications,” “integrate voice,” or “handle edge cases.” Resolve the design and technical questions now, or mark the ticket explicitly blocked by a named research or owner decision. Recommend a selected approach with reasoning rather than leaving implementers an unexplained menu of options.

### Phase D — Cross-review and synthesis

Use independent reviewers to check cross-feature consistency, modularity, privacy/security, mobile/watch feasibility, failure handling, UX coverage, and ticket completeness. Resolve disagreements across plans rather than handing conflicting instructions to future coding agents.

Produce one dependency graph and value-based delivery sequence. Identify the smallest prerequisites for each valuable user outcome, work that can proceed concurrently, and features blocked on my design work. Record the repository commit and research dates against which the plans were prepared. Include a plan-refresh task where the eventual refactor changes paths or contracts; do not make implementers rediscover that mapping.

Stop after research, plans, ticket definitions, and owner tasks are ready. Do not implement production features, perform the refactor, scaffold applications, deploy services, merge code, or activate live orchestration. Propose any executable prototype or paid validation experiment separately rather than treating it as implicitly authorized.

## 3. Product goals and settled decisions

The main goal is to keep aiur **mostly out of sight and out of mind**, while dramatically reducing the effort required to notice a blocker, understand it, and steer an agent so work continues.

Today, I approximate an event listener by watching GitHub emails about commits, PR comments, and merges. Meanwhile, an executor coordinates agents but can become overloaded with reviews, merges, and conflicts. The workable-ticket pool drains, and the active-agent count can fall from roughly ten to only a few even when newly unblocked tickets could start.

The intended product must address both orchestration throughput and low-friction human steering.

Preserve these decisions:

- **Three buckets:** behavior-preserving refactoring of existing code; improvements/new capabilities in the existing platform; new mobile and watch applications. A new build queue or conversational component is not “just refactoring.”
- **Modularity:** components should be independently reusable. The mobile app must remain useful with only the relevant components installed; optional integrations must not become hidden mandatory dependencies.
- **Current operating model:** one aiur instance is associated with one repository and one executor. Support multiple instances and potentially multiple machines. Redesigning aiur into a multi-repository instance is outside this project.
- **Phone navigation:** the entry point is a meta-dashboard of instances. Opening an instance shows its dashboard; executor chat is a secondary button. Keep the existing per-instance inbox pattern, with counts at the meta level. No combined/global inbox.
- **Private access:** support my private tailnet setup without exposing agent read/write endpoints to the public internet or requiring port forwarding. Tailscale itself must be optional configuration, not a universal requirement.
- **Notifications:** encrypted event/command contents may pass through Apple/Google push infrastructure. Research a design where only authorized paired devices decrypt protected contents. Cloudflare must not be mandatory.
- **Interaction:** a notification contains a concise blocker summary and opens the relevant conversation with context, suggested options, and an explicit microphone button. Opening a notification must not automatically activate the mic.
- **Watch scope:** notifications, contextual command responses, voice, and a compact proactive instance/status list. Do not add pause/resume, agent-spawn controls, or a broader operations console.
- **History:** retain complete conversation transcripts locally and make them reviewable. A running summary is not a committed product requirement, and summaries must never replace or delete the full transcript.

## 4. Bucket 1 — Refactor existing code into modular components

This bucket changes boundaries and configuration, not product behavior. Keep additions in Bucket 2 or 3 even when scheduled alongside refactor work.

### R1 — Modular platform and independently reusable applications

Extend the existing decomposition research to cover the dashboard, GitHub event/label listeners and orchestration, build orders, existing command functionality, and relevant supporting services. Reconcile with the prior plan rather than inventing a second architecture.

The mobile application should likely remain in the monorepo as a fully separate application/package. Research the boundary that best fits the eventual modular design. Do not assume every module must move into its own repository immediately.

Deliver a component/dependency map, public interfaces, required versus optional dependencies, configuration ownership, and migration plan. Identify minimum useful capability combinations and how clients detect unavailable functionality. Include a capability/dependency matrix showing what remains usable without the dashboard, orchestration, build orders, voice, or other optional modules. State minimum companion requirements rather than pretending an unavailable capability can still work. Prevent dependencies on monolith internals from leaking into the new clients.

### R2 — Standalone shared event bus

Ensure the existing publish/subscribe event bus is its own reusable component. Investigate its current producers, consumers, event shapes, lifecycle, delivery behavior, and coupling.

It should provide a coherent foundation for commands, progress updates, queue readiness, and event-to-conversation navigation. Research event identity, ordering, reconnection, replay/reconciliation, and versioning as needed. Do not assume the current bus is durable or invent a new mandatory broker without evidence.

### R3 — Optional Tailscale integration and configuration

Verify whether Tailscale is currently mandatory or implicitly assumed. Make Tailscale-specific behavior an explicit optional configuration concern while preserving my supported private-tailnet deployment.

Map URL/address ownership, connectivity checks, discovery assumptions, authentication, and behavior without Tailscale. Keep “Tailscale is optional for the ecosystem” separate from “my configured instance remains private.” Disabling Tailscale must not silently make sensitive endpoints public.

### R4 — Existing Cloudflare/GitHub App relay

Inspect the existing Cloudflare integration associated with the custom domain I described as “Ayer dot dev”; verify the actual configured domain rather than assuming its spelling. Verify the original purpose, GitHub App relationship, request flows, credentials, and deployment assumptions; I do not remember exactly why it was introduced.

Determine whether existing code can usefully support mobile notifications or relay responsibilities. Preserve a replaceable provider boundary and surface configuration appropriately. Do not assume the GitHub relay already solves mobile push, authentication, or encryption. Do not require Cloudflare, my domain, or my personal infrastructure for others to use the app.

### R5 — Existing ElevenLabs speech-to-text capability

Extract or confirm the independent packaging of the existing ElevenLabs speech-to-text/relay capability. The user supplies an API key and opts in. Surface the necessary configuration and document responsibilities for capture, transport, transcription, and delivery to the intended agent.

Preserve existing behavior; adding dashboard UI or live conversation belongs in Bucket 2. Missing keys or an absent voice module must not break ordinary text interaction.

### R6 — Stream Deck integration

Ensure the physical Stream Deck integration is a separate reusable package. Preserve its existing hold-to-dictate workflow and command/agent targeting.

Inspect the event-organized conversation/log functionality associated with this integration. Identify reusable event-to-log associations and distinguish shared data/access interfaces from hardware-specific presentation. The dashboard must not need Stream Deck hardware or its package installed merely to access shared conversation data.

## 5. Bucket 2 — Improve and extend the existing platform

### E1 — Build queue

**Problem:** the executor spends time on reviews, merging, and conflict resolution while agents finish and the ready-ticket pool empties. Tickets that have become actionable are not always promoted quickly enough.

Create a separately bounded **build queue** component. It has an **optional dependency on build orders**, not a required one. An executor should also be able to create a queue from its understanding of tickets or a user-specified task set.

With build orders available, use their existing dependency tree: when a PR merges and prerequisites are satisfied, newly actionable tickets become eligible and receive the existing readiness/to-do label so normal orchestration picks them up. Verify the actual label and readiness semantics in the code. The executor should not have to manually promote each newly unblocked ticket.

Research merge-to-ticket association, multiple prerequisites, capacity limits, competing writers, duplicate or missing events, restart recovery, retries, failed work, manual overrides, and queue reconciliation. Explain how an executor-created queue works without build-order data. Do not conflate planning queue membership with bypassing existing admission, permissions, or capacity checks.

Scope questions should resolve the desired queue controls and visibility, ordering among simultaneously ready tickets, and what happens when dependency information changes. Keep this coordinated with later refactor work but explicitly classified as new functionality.

### E2 — Native command capture, executor awareness, and human escalation

“Commands” are aiur’s existing mechanism for an agent to ask for input when stuck. Inspect the actual model and UI terminology.

Research how relevant native question/input-request features of Claude and Codex can surface as aiur command requests, including when the executor itself needs input. Do not assume harnesses expose identical hooks or that every permission prompt is an ordinary product question.

For worker requests, the executor must always be made aware. Support an executor-first policy and an option to surface requests to executor and human simultaneously. In executor-first mode, the executor may answer when the answer is routine or established by context; questions requiring human preference or judgment remain unresolved and are surfaced to me. Confirm the default during scoping rather than mistaking a previous suggestion for a settled choice.

Preserve response delivery to the requesting worker/session, or to the executor when it is the requester. Executor awareness must not unnecessarily reroute every human response through another conversation.

Research unanswered triage, absent/offline executors, conflicting answers, simultaneous phone/watch/dashboard responses, requests already resolved elsewhere, and how clients reconcile resolution. Never allow a request to disappear because the executor was notified but did not act. Define suggested responses, typically two or three, as part of the request’s contextual interaction.

### E3 — First-class executor communication

Today I often rely on Claude Remote Control to talk to the executor. Add aiur-native communication through the dashboard so this is not the only path and a Codex executor can also expose its conversation.

Support reading the executor conversation and providing input through a harness-aware, normalized interface. Distinguish executor information from worker information while keeping the one-executor-per-instance model. Surface status, blockers, and background-agent information when available.

Research session identity, reconnecting, history availability, input delivery during ongoing work, and harness-specific limitations. Clarify any steering/interruption behavior that changes current operation. Do not create a second unrelated conversation system or require the mobile app merely to access executor chat.

### E4 — Dashboard agent conversations, logs, and event navigation

Surface full worker and executor conversation/log streams in the web dashboard. Reuse the existing milestone model rather than recreating associations from scratch.

Relevant jump points include executor progress updates, reported to occur every few minutes, commits, PR creation, and other already-supported events. Extend to useful milestones such as merges and command requests where appropriate. Selecting a milestone should take the user to the corresponding conversation context.

Support reviewing the full chronology and navigating by event; I will design the exact layout. Preserve the underlying relationship between event, instance, agent/session, and conversation position. Research absent logs, missing associations, long histories, loading, ordering, and restart/session boundaries.

I want read and interaction/write access from the dashboard. Clarify whether “write” means sending messages, issuing commands, or steering an agent. Do not interpret it as permission to rewrite historical logs.

### E5 — First-party dashboard voice input

Add microphone-based input to relevant dashboard surfaces, including command responses and individual agent/executor views. Reuse the optional ElevenLabs capability and the existing targeting/routing behavior.

Plan explicit recording controls, capture/transcription feedback, delivery state, cancellation, errors, microphone permission handling, and the no-key/no-voice fallback. Clarify whether users review/edit a transcription before it is sent; this has not been decided.

Share services and contracts with mobile and watch where practical, without forcing identical UI. Keep simple speech-to-text input distinct from the conversational component below.

### E6 — Independent conversational voice component

Create a separately reusable conversational component, initially in the monorepo, for low-friction back-and-forth discussion. Its purpose is a fast, communication-oriented assistant that understands a brain dump, asks useful questions, clarifies intent, and helps formulate instructions—not simply exposing a coding model through a microphone.

Research ElevenLabs capabilities beyond the currently used transcription API, including whether an existing conversational offering can provide the desired experience without rebuilding an entire voice stack. Compare alternatives only as necessary to make a supported recommendation. Do not preselect an API or assume a service supports the needed model, context, or interaction behavior.

Provide configurable role/skill pre-context. The component must support conversations about an individual worker’s ticket and conversations with the executor about the overall project. Define its relationship to the actual agent: what context it receives, when it consults the agent, what becomes an instruction, and when a discussion remains only a discussion.

Retain full transcripts locally and make them reviewable later. Storage optimization is not a reason to discard history. Model context management may use retrieved history or summaries if justified, but a persistent running-summary feature is not mandatory. Raw audio retention is a separate, unresolved question; do not infer it from transcript retention.

Explicitly clarify single-response dictation versus live conversational mode, activation controls, interruption/turn-taking, how conversation outcomes are sent to agents, and context recovery when returning later. **The last mic-mode question was never answered.** Do not treat either mode as the chosen default.

## 6. Bucket 3 — New mobile and watch applications

### N1 — Cross-platform application architecture

Target **both iOS and Android**, with minimal platform-specific duplication. React Native is a candidate, not a selection. Research current suitable frameworks and WebView-oriented approaches against the actual dashboard, necessary native integrations, watch requirements, maintenance burden, and independent packaging.

Much of the app may reuse the existing dashboard in a WebView. Native implementations or deliberate UI duplication are acceptable where they materially improve notifications, microphone/voice interactions, the meta-dashboard, or other platform-specific UX.

Investigate current distribution/review requirements and native functionality expectations using authoritative sources. Do not assume that wrapping a dashboard guarantees approval or that adding one native feature automatically resolves review concerns.

Deliver an evidence-based comparison and recommended approach, a surface-by-surface web/native boundary, code-sharing strategy, watch implications, capability model, and packaging plan. Avoid turning framework choice into a commitment before the research is done.

### N2 — Machine-level onboarding, pairing, and instance discovery

Pairing is **machine-level and durable**, not per repository, run, instance, or executor session. The app should discover the aiur instances on a paired machine without repeated manual pairing.

Expose optional mobile setup through aiur’s global machine configuration. Users who skip it during setup must be able to enable it later. A settings page may display a pairing QR code at any time. The app’s first-run flow can guide users to that page and scan the code.

Support multiple paired machines and changing sets of instances. Research the minimum discovery/registry responsibility, stable identities, credentials, expiration, revocation, re-pairing, URL changes, reachability, and stale/offline instances. Do not silently require the entire orchestration stack just to pair or discover available components.

Separate device authorization from mere network reachability. Do not assume being on the same tailnet alone is sufficient authorization to read or control an agent.

### N3 — Meta-dashboard and navigation

The phone’s top-level view is a list of aiur instances, each associated with its repository and executor.

Show relevant high-level information: instance/repository identity, active-agent count, executor state, blockers/commands requested, build-order percentage when applicable, and executor background-agent information when supported. Missing optional capabilities should be absent or clearly unavailable, not misleading zero values. Distinguish unreachable/stale data from live idle status.

Opening an instance takes the user to its dashboard. Executor chat is a secondary button, not the default landing view. Keep the existing per-instance inbox. Show each instance’s pending count in the meta-dashboard, using the existing terminology after verifying whether the UI says “commands requested,” “commands needed,” or something similar.

Do not add a combined inbox or reinterpret the attention/count indicator as a manual “ping executor” action. Research refresh and state synchronization; leave visual design and detailed interaction patterns to my design task.

### N4 — Private, encrypted, rich background notifications

The outcome is timely, expressive awareness when an agent or executor needs input, including when the phone app is not foregrounded, without making the aiur machine publicly accessible.

Investigate an outbound relay/push design, potentially reusing suitable existing infrastructure. Cloudflare is optional. Protected event/command contents may traverse Apple/Google infrastructure encrypted, with decryption limited to authorized paired devices. Specify exactly what any relay or provider can see, including routing metadata.

Research current iOS, Android, and watch capabilities for encrypted payloads, notification rendering, background execution, device/key state, delivery delays, app termination, connectivity, and action handling. Do not promise an indefinitely awake application, guaranteed immediate delivery, or reliable background fetching just because a push arrives. Validate the user outcome independently from those assumptions.

Resolve how a concise blocker summary can appear while protected data remains encrypted in transit, and how richer context is obtained privately. Investigate disconnected tailnets, suspended apps, unavailable hosts, locked devices, delayed notifications, stale requests, and keys unavailable to an extension or companion device.

Plan suitable physical-device validation before implementation is considered complete. Document constraints honestly rather than relying exclusively on simulator behavior or a “silent push wakes everything” assumption.

### N5 — Notification preferences and progress updates

The primary alert is a command request/blocker requiring human attention, from either a worker or the executor. Integrate with the selected escalation policy so notifications represent unresolved human-relevant work rather than every internal request indiscriminately.

Support configurable progress notifications, specifically PR merges and build-order percentage thresholds—for example, every ten percentage points. Research which other existing events, such as commit pushes or PR comments, are useful optional signals.

Clarify preference scope, defaults, interruption/noise limits, duplicate suppression, progress recalculation, large jumps across thresholds, and completion behavior. Do not assume every event should notify by default or send a burst of outdated alerts after reconnecting.

Settings must remain capability-aware: build-order options depend on build orders, and unsupported events should not appear to be functional.

### N6 — Contextual command response on phone and watch

The required flow is:

> A short blocker notification → open the relevant conversation/context → see the explanation and suggested options → choose an option or explicitly activate the microphone.

Use a concise couple-word notification summary, such as “Migration decision” or “Merge conflict.” The destination should resolve the correct machine, instance, agent/executor, and command, and place the user at the relevant context rather than a generic inbox or unrelated chat.

Display the agent’s suggested responses, typically two or three, along with the context needed to choose. Provide an explicit mic button. Do not auto-record when the notification is tapped, and do not require recording inside a notification banner.

Research appropriate phone/watch layouts, response acknowledgement, connection failure, stale/resolved requests, retries, duplicate submissions, and switching from a notification into an existing conversation. Preserve existing response targeting while respecting executor awareness and competing responders.

Do not silently decide whether mic activation starts a single dictated response or an ongoing voice conversation. Capture that as a scope decision shared with E5/E6 rather than implementing conflicting behavior across clients.

### N7 — Watch applications

Include Apple Watch support and investigate the appropriate Android-compatible watch target, framework, and distribution approach. Do not assume the phone framework automatically covers both watches.

The watch should provide notifications, the relevant compact command context, suggested response options, explicit microphone/voice interaction, and a proactive compact list of instances and statuses. Relevant summary information includes executor status, active agents, blockers, and build progress when available.

Do not add pause/resume, manual spawning, or general orchestration controls. Preserve the low-friction steering goal rather than shrinking the whole dashboard onto a watch.

Research companion versus standalone connectivity, authorization/key handling, microphone and transcription paths, background delivery, battery constraints, and whether any step must continue on the phone. Identify platform differences instead of promising complete parity before validation. Full-history browsing on the watch is not an established requirement; clarify appropriate context depth during design.

## 7. Cross-feature contracts and failure behavior

Investigate and specify shared contracts once, then reference them consistently across feature plans. At minimum, account for machine/instance identity, repository identity, executor and worker/session identity, capabilities, events, command requests and resolution, conversations/transcripts, event-to-conversation anchors, build progress, queue readiness, and notification destinations.

These are responsibilities to research, not a predetermined schema or demand for new services. Prefer existing models where sound. Define ownership so the event bus, command system, conversation access, voice component, pairing/discovery, and push transport do not become tightly coupled through hidden dependencies.

Make capability absence, stale data, restart recovery, duplicate events, multiple paired devices, and conflicting responses explicit. A feature must not silently become nonfunctional because an optional component is missing.

Keep secrets, provider credentials, pairing credentials, and device encryption keys appropriately separated. Document where opted-in cloud voice processing sends audio, transcript, or model context; encrypted push and private agent access must not be presented as a claim that all chosen voice processing is local. Distinguish privacy constraints for notification transport from the optional voice provider’s processing requirements.

Specify how deep links and actions are authenticated and scoped. Define permission and failure behavior before a coding agent implements a path capable of reading sensitive logs or instructing an agent.

## 8. My UX/UI tasks must block implementation

For **every feature**, create an explicit owner task such as:

> **DESIGN-E5 — Kevin: design and approve dashboard voice-input UX/UI.**
>
> Deliver the relevant screens or interaction design, navigation and states, copy, and explicit approval. Feature implementation remains blocked until this task is complete.

Create corresponding tasks for setup/pairing, meta-dashboard, per-instance navigation, executor and worker conversations, event navigation, command requests and responses, voice controls, conversational mode, notification presentation/preferences, build-queue surfaces, and watch interactions.

Each task must state what I need to design, the affected surfaces, decisions requiring my input, and acceptance conditions. Include applicable loading, empty, offline, permission-denied, error, stale/resolved, and success states. Link shared design tasks to all affected features instead of duplicating inconsistent requirements.

For a pure backend/refactor feature, still create the owner gate: explicitly confirm that no user-facing change is intended, or design/approve any affected configuration/setup UX. Do not invent unnecessary screens just to satisfy the checklist.

Research and planning may continue before design approval. **Feature implementation may not.** Reflect the blocking dependency on every affected implementation ticket. Do not mark my task complete without my explicit approval. Tickets whose behavior depends on an unresolved design must stay blocked, not let an implementer improvise.

## 9. Required depth of every implementation-ready ticket

Each ticket must be self-contained enough for a new coding agent to execute with limited context. Include the following information, using concrete repository evidence rather than generic instructions:

| Area | Required content |
|---|---|
| Identity and outcome | Bucket, feature, chunk, ticket ID; user value; exact deliverable; scope and non-goals. |
| Dependencies and blockers | Predecessor tickets, shared contracts, my UX/UI design gate, unresolved research, and what may run concurrently. |
| Verified starting point | Relevant commit, current behavior, exact files/packages/symbols, tests, configuration, and reusable code. Distinguish proposed future paths from existing ones. |
| Chosen design | Selected approach and rationale; inputs/outputs; ownership; interfaces, payloads, state transitions, and invariants as applicable. |
| Implementation steps | Ordered changes; proposed file changes; pseudocode or examples where helpful; integration points; no concealed architecture decisions. |
| Non-happy paths | Capability absence, privacy/security boundaries, permissions, concurrency, idempotency, retries, stale state, disconnects, and recovery relevant to this ticket. |
| Compatibility and rollout | Configuration changes, migrations, backward compatibility, feature gating, deployment/packaging implications, and rollback where applicable. |
| Verification | Concrete automated tests and fixtures, expected results, exact available validation commands, manual/device tests, and observable success/failure behavior. |
| Completion and handoff | Acceptance checklist, dependent tickets, documentation updates, sources, and any remaining explicitly assigned blocker. |

Not every ticket needs a migration or state machine. Mark genuinely irrelevant sections as such with a reason; do not pad plans with boilerplate. Conversely, do not substitute “add appropriate tests” for actual test cases.

Current external technical claims must be backed by authoritative documentation or reproducible evidence, with dates and relevant versions. Record uncertainties and the validation required to settle them. Never invent repository symbols, APIs, platform guarantees, or completed tests to make a plan look finished.

The standard is that later coding agents execute a chosen, reviewed plan. When judgment is still required, expose it as a specific blocker now rather than expecting an implementer to solve it unnoticed.

## 10. Final research deliverables and completion gate

Organize artifacts on the existing research branch with an index, for example:

```text
research/
  aiur-mobile-and-platform/
    README.md
    context-and-decisions.md
    feature-inventory.md
    value-and-sequencing.md
    dependency-map.md
    contracts/
    bucket-1-refactor/<feature-id>/
    bucket-2-platform/<feature-id>/
    bucket-3-mobile-watch/<feature-id>/
    owner-design-tasks/
    cross-feature-reviews/
```

Adapt paths to repository conventions; the important requirement is the hierarchy **bucket → feature → chunk → ticket**, with shared contracts and owner blockers discoverable from the index. Preserve and link the original refactor research.

The final handoff must contain the verified baseline; complete feature scopes and decisions; unanswered questions with owners; value-based delivery waves; dependency graph; independently researched feature plans and chunk/ticket plans; framework, notification, voice, and watch recommendations; my blocking UX/UI task list; integration/security/device-validation plans; and cross-review findings with their resolution.

Conclude with a clear readiness report: what is sufficiently planned, what is blocked on me, what remains technically unverified, and which implementation tickets become eligible first after the required approvals. Do not claim a feature is ready while its essential design or platform feasibility remains unresolved.

**Do all the research and planning upfront. Do not start building until I explicitly authorize implementation.**
