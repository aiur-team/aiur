---
artifact_contract: ce-unified-plan/v1
artifact_readiness: requirements-only
product_contract_source: ce-brainstorm
date: 2026-10-06
base_main_sha: 45a290e3
branch: research/refactor-findings
---

# aiur Modular Platform, Mobile and Watch - Plan

## Goal Capsule

- **Objective:** plan, without implementing, a modular aiur platform: build queue, refactor, command escalation, conversations, voice and listener modes, then mobile and watch apps. Every feature ends in implementation-ready tickets gated by owner design tasks.
- **Product authority:** Kevin, the operator, through the brainstorm on 2026-10-06. Source brief: [brief.md](brief.md).
- **Open blockers:** the per-feature `DESIGN-*` owner tasks block implementation. Platform feasibility (push, watch, voice provider) stays a named research question until it is validated.

## Summary

aiur will keep its agent queue full on its own, become a set of independently reusable components, and give its operator low-friction ways to notice blockers and steer agents. First that happens in the dashboard, then by voice, then on phone and watch.

This pack plans all of that in order of value. Each feature's plan is decomposed into chunks and tickets that later coding agents execute without inventing product behaviour.

## Problem Frame

- **The Executor is overloaded.** It runs reviews, merges and conflict work while the ready-ticket pool drains, and active agents fall from about 10 to a few even when unblocked tickets exist.
- **Noticing a blocker is high friction.** The operator approximates an event listener by reading GitHub email.
- **Steering an Executor is limited.** It needs Claude Remote Control; there is no aiur-native Executor conversation (see [baseline/capability-baseline.md](baseline/capability-baseline.md) E3).

## Requirements

Feature IDs carry an `MP-` prefix, because bare R1–R14 already exist in the prior refactor plan ([baseline/existing-refactor-research.md](baseline/existing-refactor-research.md)). The full list is in [feature-inventory.md](feature-inventory.md), and the order is in [value-and-sequencing.md](value-and-sequencing.md).

- MP-REQ1. Every feature in the inventory gets a deep feature plan, chunks, and implementation-ready tickets meeting brief §9.
- MP-REQ2. Every feature gets a `DESIGN-<feature>` owner task. Its implementation tickets are blocked on that task.
- MP-REQ3. Existing refactor research (U0–U9, the boundary survey, the size ledger) is preserved and linked. New tickets cite `Prior-units`, `Prior-boundaries`, `Prior-features`, `Prior-findings`, `Size-owner` and `Base-SHA`.
- MP-REQ4. A public component directory page (listing components and planned features) is a deliverable of MP-R1. It is published after the refactor and generated from R1's final component map.
- MP-REQ5. Planning stops at a readiness report. No production code, scaffolding, deploys, merges or live orchestration changes.

## Key Decisions

Every decision below is `session-settled`: chosen by the operator on 2026-10-06.

1. **Value order:** MP-E1 → MP-R1–R7 → MP-E2 → MP-E3/E4 → MP-E5/E6/E7 → MP-N1–N7. Rejected: mobile soon after the refactor. Mobile reuses the finished command, conversation and voice contracts.
2. **MP-E1 ships before the refactor, on a seam.** It is its own component behind narrow interfaces, so the refactor moves it rather than rewrites it. Rejected: refactor first.
3. **Build-queue ordering:** among tickets that become ready at the same time, critical path first (most downstream dependents), then priority labels, then age.
4. **Promotion:** every ready ticket gets `agent:todo` at once, and the existing dispatcher's capacity and admission gates decide who starts. Rejected: promote only up to free slots.
5. **Queue without a build order:** an ordered list plus optional "after #N" dependencies, using the same promotion machinery.
6. **Failed prerequisite** (PR closed unmerged or ticket in error): dependents stay waiting, and one needs-attention alert names the failed prerequisite and every ticket it blocks.
7. **Queue controls:** CLI commands (add, remove, reorder, hold or release, show) plus a read-only dashboard view (DESIGN-E1).
8. **Dependency change after promotion:** remove `agent:todo` if no agent has claimed the ticket; if work has started, leave it and raise an attention.
9. **MP-E2 escalation follows the Command's declared authority.** `supervisor_allowed` and `supervisor_preferred` go Executor-first; `human_required` goes to the Executor and the human at the same time. With no live Executor, a command goes to the human at once.
10. **Native capture:** only native ask-the-user tools (Claude AskUserQuestion, Codex request_user_input) become commands. Permission and approval prompts stay with the sandbox and approval policy.
11. **Competing answers:** the first recorded answer resolves the command, and a human can supersede an Executor's answer until it is delivered.
12. **The Executor as requester** uses the same command system, marked Executor-originated. It goes straight to the human, and the answer is delivered into the Executor's session.
13. **MP-E7 shared listener package:** steer, sync and async listener modes, shared with Khala as one package (the contract is today in `@khala/contracts/m1/listening-mode`). The default mode is sync.
14. **MP-R7:** extract the per-model shims and wrappers into one harness-adapter package. This is behaviour-preserving and feeds MP-E7.
15. **MP-E4 conversation write access** is limited to sending messages (through the listener mode) and answering that agent's open commands. Logs are never rewritten, and controls stay where they are today.
16. **Mic activation always offers an explicit choice of buttons** (dictate or converse) on the dashboard, phone and watch, with no default mode.
17. **Raw audio is never retained.** Full transcripts are retained locally and stay reviewable.
18. **Notification defaults:** blocker commands are always on, plus every 25% of build-order progress and completion. PR merges and other events are opt-in.
19. **Pairing grants full access to every instance on the paired machine.** It is revocable per device, and a remote unpair-everything is first-class (MP-N2).
20. **The component directory page goes live after the refactor.**

The brief's own settled decisions (§3) carry forward unchanged: three buckets, modularity, one instance per repository and Executor, meta-dashboard navigation, private access with optional Tailscale, encrypted push through Apple and Google, no automatic mic, a narrow watch scope, and full transcript history.

## Scope Boundaries

- Out of scope: implementation, scaffolding, deploys and merges; multi-repository instances; a combined or global inbox; watch pause, resume or spawn controls; retaining raw audio; any mandatory Cloudflare, Tailscale or personal infrastructure.
- Brief §3 non-goals carry forward.

## Outstanding Questions

These are research questions, resolved by planning agents with evidence:

- MP-Q1. *(Recommended in MP-E7: a spec-first package published from Khala; owner item E7-D1.)* A home and release path for the package shared with Khala (E7).
- MP-Q2. *(Answered in MP-N4: a purpose-built opaque relay; Khala and `hooks.aiur.dev` cannot carry push; the publisher holds the APNs/FCM keys.)* The push relay: whether Khala (an end-to-end encrypted Matrix product) or the existing `hooks.aiur.dev` tunnel can carry encrypted push, and what each relay sees.
- MP-Q3. *(Answered in MP-E6: ElevenLabs Agents with a built-in LLM and a daemon-held session; OpenAI Realtime second; a paid spike is pending.)* The ElevenLabs conversational offering, compared with alternatives, for E6.
- MP-Q4. *(Answered in MP-N1/N7: React Native on Expo with WebView dashboards; SwiftUI and Wear OS watch apps.)* The mobile framework, the WebView/native boundary, and the Android watch target (N1, N7).
- MP-Q5. *(Answered in MP-R2: the topic exchange carries exported coordination events; PubSub carries internal invalidation only.)* Which bus owns which facts. The prior research flags two buses; the instance registry today is `~/.config/aiur/instances`.

Owner design questions live in `owner-design-tasks/`. Machine-level settings live in `~/.aiur/machine`, not `~/.aiur/config` (reconciliation RC-03).
