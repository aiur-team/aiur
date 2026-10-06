---
design_task: DESIGN-E2
feature_id: MP-E2
owner: Kevin (operator)
status: open — not approved
blocks: [MP-E2-C1-T01, MP-E2-C1-T02, MP-E2-C1-T03, MP-E2-C1-T04, MP-E2-C2-T01, MP-E2-C2-T02, MP-E2-C2-T03, MP-E2-C2-T04, MP-E2-C2-T05, MP-E2-C3-T01, MP-E2-C3-T02, MP-E2-C3-T03, MP-E2-C3-T04, MP-E2-C4-T01, MP-E2-C4-T02, MP-E2-C4-T03, MP-E2-C4-T04, MP-E2-C4-T05, MP-E2-C5-T01, MP-E2-C5-T02, MP-E2-C5-T03, MP-E2-C6-T01, MP-E2-C6-T02, MP-E2-C6-T03, MP-E2-C6-T04, MP-E2-C7-T01, MP-E2-C7-T02, MP-E2-C7-T03, MP-E2-C7-T04, MP-E2-C7-T05, MP-E2-C8-T01, MP-E2-C8-T02, MP-E2-C8-T03, MP-E2-C8-T04, MP-E3-C6-T03, MP-E4-C4-T02, MP-E4-C6-T02, MP-E5-C4-T01, MP-E5-C4-T02, MP-N4-C4-T03, MP-N4-C5-T03, MP-N5-C2-T02, MP-N6-C3-T01, MP-N6-C3-T02, MP-N7-C2-T03, MP-N7-C3-T03]
blocks_note: "Phase D: the list is the tickets whose blocked_by names DESIGN-E2 (waived entries excluded). Earlier wording: every MP-E2 implementation ticket with a user-visible surface (see ../bucket-2-platform/MP-E2/chunks.md)"
shared_with: DESIGN-N6 (phone and watch response flow), DESIGN-E5 (voice controls), DESIGN-E4 (conversation anchors), DESIGN-N4/N5 (notification presentation and preferences)
base_main_sha: 45a290e3
date: 2026-10-06
---

# DESIGN-E2 — Kevin: design and approve Command request, response and escalation UX

Deliver the screens or interaction design, the states, the copy, and an explicit approval.
**MP-E2 implementation stays blocked until this task is approved.** Backend-only tickets
(MP-E2-C1, C2 and the store parts of C3) may proceed. They are listed in
[chunks.md](../bucket-2-platform/MP-E2/chunks.md) with the gate they wait on.

This task also owns the **shared Command request and response presentation**. DESIGN-N6
(phone and watch) and DESIGN-E5 (mic on Command answers) link here and only design their
device-specific layout. They do not redefine states, copy or option rules.

## 1. What already exists (do not redesign by accident)

Verified at `45a290e3`:

- The UI word is **Command**. The code word is Decision. Nav item `Commands`, route
  `/commands` and `/commands/:decision_id` (`src/lib/aiur_web/router.ex:142-143`).
- Inbox heading `Commands inbox` (`components/operator_control_center/decision_inbox.ex:42`).
- Banner `1 unit awaiting commands` / `N units awaiting commands`, CTA `Issue commands`
  (`components/operator_control_center/overview.ex:65,168-169`).
- Status badge `Deferred to Executor` (`decision_card.ex:127`). History rows
  `Deferred to Executor`, `Handed to the Executor`, `Executor answer`
  (`history.ex:224,241,266`).
- Action buttons `Defer to Executor` / `Notify Executor again`, and `Retry delivery`
  (`decision_action.ex:117,166`).
- A Command already carries `question`, `context.short_summary`, `options[]` (label,
  description, benefits, drawbacks, risk), `recommendation`, `consequence_of_delay`,
  `urgency`, `blocking` and `authority` (`src/lib/aiur/decision.ex`).
- Stream Deck answers through `answer_command` as operator `streamdeck`
  (`src/lib/aiur_web/streamdeck_channel.ex:152`, `streamdeck_commands.ex:19,73`).

## 2. What MP-E2 adds that needs a design

1. **Routing state.** A Command is now *with the Executor*, *with you*, or *with both*
   (contract §4). Today the human sees every open Command with no indication of who is
   expected to act.
2. **Escalation.** A Command moves from *with the Executor* to *with you* because the
   Executor escalated, did not act in time, or went offline. The human must see why.
3. **Native questions.** Commands now also come from an agent's own ask-the-user tool.
   These carry 1–3 (Codex) or 1–4 (Claude) questions, each with 2–4 options and a
   free-text "Other". One native call can hold several questions.
4. **Executor-originated Commands.** The Executor itself asks. These go only to you, and
   the answer goes back to the Executor session (D12). They replace the hidden `aiur ask`
   store, which no dashboard surface shows today.
5. **Competing answers.** The first answer resolves the Command. You can replace an
   Executor answer until it is delivered (D11). The UI must show "answered by the Executor
   — not delivered yet — replace?" and the moment that becomes impossible.
6. **Suggested responses.** Two or three suggested responses, a recommended one marked,
   and a custom response.

## 3. Surfaces to design

| Surface | Scope for DESIGN-E2 | Linked task |
| --- | --- | --- |
| Dashboard Commands inbox (`/commands`) | Routing and escalation states, filters ("Needs you", "With Executor", "From Executor", "Resolved"), row anatomy | — |
| Command detail (`/commands/:id`) | Request block, context, suggested responses, custom response, escalation timeline, supersede, delivery state | DESIGN-E4 (link to conversation anchor) |
| Overview banner and fleet `Commands` column | Whether counts separate "needs you" from "with Executor" | DESIGN-N3 (meta-dashboard counts) |
| Agent conversation drawer | How an open Command for that agent appears inline (D15 allows answering there) | DESIGN-E4 |
| Mic on a Command answer | Placement only; dictate/converse choice is DESIGN-E5 (D16) | DESIGN-E5 |
| Stream Deck | Confirm the existing `answer_command` flow still fits: option keys and dictated custom response | DESIGN-R6 |
| CLI output (`aiur commands`, `aiur executor-answer`, `aiur executor-ack`, `aiur command request`, escalation messages) | Copy and the column set | — |
| Phone/watch | **Not here.** DESIGN-N6/N7 reuse §4–§6 | DESIGN-N6, DESIGN-N7 |

## 4. Shared Command presentation (normative for N6 and E5)

Kevin decides each item marked **[decide]**. The others are proposals to approve or change.

### 4.1 Request anatomy

- **Short label** (2–3 words, for notification titles and narrow rows). Source:
  `context.short_summary`, or the native `header` (≤12 chars). **[decide]** whether a
  missing label falls back to the first words of the question or to the Command kind.
  Recommended: **the first words of the question**, because the kind alone ("Decision")
  does not tell two Commands apart in a notification list.
- **Requester line:** worker `#<ticket>` with its agent, or "Executor". Plus age, e.g.
  "asked 12 min ago".
- **Routing chip:** `With Executor` · `Needs you` · `Needs you and Executor` ·
  `From Executor`. **[decide]** the exact wording. The code values are in the contract §4.
- **Question**, then **context** (collapsed long context), then **consequence of delay**
  when set.
- **Blocking marker** when the agent cannot continue.

### 4.2 Suggested responses

- Show 2–3 options. The recommended option is first and marked "Recommended".
- A native question with 4 options (Claude allows 4) shows all 4. The 2–3 rule applies to
  options aiur or the agent authors through `decision.requested`, not to native questions.
  **[decide]** confirm this exception.
- "Other / custom response" is always available as a text field (and mic, DESIGN-E5).
- Multi-question native Commands: **[decide]** one card per question with a single
  Submit, or a stepper. Partial answers are not delivered (the native tool needs every
  question answered). **This gate owns the layout for the dashboard and the phone**
  (§6 item 5); DESIGN-N6 D-4 decides only the watch fallback. Recommended: **one card
  per question with a single Submit**, because the operator sees every question before
  answering any.
- Multi-select questions (Claude `multiSelect`): **[decide]** checkbox presentation.
  Recommended: **checkboxes with a single Submit**, the platform-standard control.
- Option detail (benefits, drawbacks, risk) is behind disclosure on narrow screens.

### 4.3 Escalation timeline

A compact timeline on the detail view, for example:
"Asked 10:02 → With Executor → Executor did not act in 10 min → Needs you 10:12 →
Answered by you 10:20 → Delivered 10:20". Each escalation names its cause
(the contract §5 closed list, Phase D CR-E2-4 a: `executor_escalated`,
`executor_ack_timeout`, `executor_answer_timeout`, `executor_offline`, `executor_stalled`,
`executor_not_answerable`, `authority_human_required`, `executor_originated`; the earlier
`executor_timeout` is now the two timeout causes).

### 4.4 Answer outcomes the human can see

| Outcome | Proposed copy (draft) |
| --- | --- |
| Accepted, delivering | "Answer recorded. Delivering to #123…" |
| Delivered | "Delivered to #123 at 10:20" |
| Agent gone, answer queued | "Answer recorded. #123 is not running; it will receive it when it restarts." |
| Someone answered first | "Already answered by <the Executor / you on another device> at 10:19: '<answer>'" plus **Replace** while undelivered |
| Replacing an Executor answer | Confirmation: "Replace the Executor's answer? It has not reached #123 yet." |
| Too late to replace | "Already delivered at 10:20. Send a follow-up message instead." Link to the conversation |
| Command withdrawn (moot, dismissed, expired, agent finished) | "No longer needed: <reason>" — the answer form is disabled |
| Delivery failed | Existing `Retry delivery` |
| Stale view | "This Command changed. Refresh to see the latest." (409 `decision_conflict`) |

## 5. States to design (per surface)

Loading · empty ("No Commands need you") · offline/daemon unreachable · permission denied
(no dashboard credentials; supervisor token missing for the API) · error · stale (the
Command changed underneath) · resolved elsewhere · delivered · delivery failed ·
answer queued for a stopped agent · Executor offline (a banner that says Commands go
straight to you) · native capture unavailable for this harness (a capability note, not
an error).

## 6. Decisions that need Kevin

1. **Escalation timeouts.** Proposed defaults: the Executor must acknowledge within
   **5 min** and answer or escalate within **15 min** of routing. After that the Command
   becomes "Needs you". A blocking, high-urgency Command uses half these values. Change
   or approve. (Contract §5; configurable as `decisions.escalation.*`, inside the existing
   `decisions:` section, `config/schema.ex:57`; Phase D CR-E2-4 b.)
2. **Visibility of "With Executor" Commands.** Proposed: every open Command is visible in
   the inbox, but only "Needs you" Commands count in the banner and send notifications
   (N5 defaults, D18). Alternative: hide "With Executor" Commands behind a filter.
3. **Wording** of the four routing chips and the escalation causes. Recommended: the
   §4.1 draft chips, and each cause as a short sentence ("Executor did not act in
   10 min"), because the code values are not readable copy.
4. **Option count exception** for native questions with 4 options (§4.2). Recommended:
   **yes, show all 4**, because hiding a native option would change the agent's question.
5. **Multi-question layout** (§4.2), for the dashboard and the phone. Recommended: **one
   card per question with a single Submit** (§4.2). The watch fallback is DESIGN-N6 D-4.
6. **Executor-originated Commands:** one inbox with a "From Executor" filter (proposed),
   or a separate section.
7. **Can the human hand a "Needs you" Command back to the Executor?** Today's
   `Defer to Executor` exists. Proposed: keep it only for `supervisor_*` authority; hide
   it for `human_required` and Executor-originated Commands.
8. **Native questions while the agent is held.** The agent is waiting inside a tool call.
   Proposed copy on the unit row: "Waiting for your answer" instead of "Running".
9. **Backend-only tickets before approval** (Phase D, CR-E2-4 d). The header above says
   backend-only tickets (C1, C2, store parts of C3) may proceed before this task is
   approved. Confirm, or require approval first. Recommended: **confirm**, because those
   tickets add no user-facing surface and unblock MP-E2-C1, C2 and the C3 store parts.
   [ ] confirm  [ ] wait for approval.
10. **Codex `default_mode_request_user_input` flag** (reconciliation owner item). The free
   spikes MP-E2-C4-T00 and C5-T00 can run now and report first; decide after reading them
   whether to enable the flag in production. Recommended: **keep off until both spike
   reports show the native question holds the turn without a timeout, then enable**,
   because an unproven flag could stall Codex workers. [ ] enable  [ ] keep off.

## 7. Acceptance conditions

- Every state in §5 has a design for the dashboard inbox and the detail view.
- §4 is approved as the shared presentation, and DESIGN-N6 and DESIGN-E5 link to it.
- Copy for §4.4 is final.
- The decisions in §6 are recorded with Kevin's answers.
- Kevin explicitly approves. Nobody else marks this task complete.

## 8. Not in scope

- Permission and approval prompts (D10). They never appear as Commands.
- Phone and watch layouts (DESIGN-N6, DESIGN-N7).
- The mic button behaviour (DESIGN-E5).
- The Executor conversation surface (DESIGN-E3).
