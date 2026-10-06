---
design_task: DESIGN-E4
feature_id: MP-E4
owner: Kevin
status: open (awaiting explicit approval)
blocks: every MP-E4 implementation ticket (MP-E4-C1..C8)
shared_with: DESIGN-E3 (Executor mode of the same view), DESIGN-E2 (inline Command cards), DESIGN-E5 (mic on the composer), DESIGN-E7 (delivery mode indicator), DESIGN-N6 (phone "open in context" lands on an anchor)
base_main_sha: 45a290e3
date: 2026-10-06
related_plan: ../bucket-2-platform/MP-E4/plan.md
related_contract: ../contracts/conversations-transcripts-anchors.md
---

# DESIGN-E4 — Kevin: design and approve the conversation view and event navigation

**Implementation of MP-E4 is blocked until this task is approved.** Research and
planning may continue. Do not mark this task complete without Kevin's explicit
written approval.

## 1. What you are designing

A full conversation view for any worker (and, through DESIGN-E3, the Executor):
the complete chronology, not the last 80 messages, with event jump points —
progress updates, pushes, PR opened, PR merged, Command requests and others —
that take you to the place in the conversation where the event happened.

You can send a message and answer this agent's open Commands from the view.
Nothing else is writable: no editing or deleting history, and pause, resume,
interrupt and spawn stay where they are (D15).

## 2. What exists today (for reference)

- Conversation drawer at `/chat/:owner/:repository/:identifier` (last 80
  messages, states Live / Ended / Stale / Unavailable / Continuity unknown,
  composer `Message agent…`, `Pause`, `Send`, mic controls).
- Agent log modal (last 80 messages of the workspace log).
- Stream Deck logs mode: event keys, each jumping to its place in the
  transcript, with a pinned LIVE key.
- Commands inbox `/commands` with no link to the conversation.

## 3. Surfaces

| Surface | What you design |
| --- | --- |
| Full conversation view | Layout of transcript, event navigation and session dividers; desktop and phone width. |
| Event navigation | Rail, list, timeline or filter chips; how a jump is shown (scroll + highlight); how unanchored events look (no jump). |
| Jump-point labels and icons | One per kind: progress, phase, push (with short sha), PR opened, PR merged, CI, review comment, Command requested/resolved, attention, Executor progress. |
| Anchor precision | Whether "exact" vs "approximate" (observed) placement is visible to you, and how. |
| Entry rendering | Agent message, reasoning, shell command + output, tool call/result, file diff, your messages, system notices, gap markers. |
| Session dividers | New session after restart, resume, `/clear`, compaction, takeover. |
| Composer and delivery states | Pending, queued for next boundary, in context, failed, unknown. |
| Inline Command card | An open Command of this agent, with options and answer, inside the conversation. |
| Links in | From the units table, Commands page ("Open in conversation"), build-order ticket context, Stream Deck, and later phone notifications. |
| Relationship to the drawer | Keep the drawer as a quick view with a "full conversation" link, or replace it. |

## 4. Decisions that need your input

1. **Layout** (yours to design): single chronology with an event rail, split
   events/transcript, or other.
2. **Default jump points**: which kinds are on by default; are CI results and
   comments noise?
3. **Reasoning and raw tool output**: shown, collapsed, or hidden by default?
4. **Secrets**: transcripts may contain secrets an agent printed. Mask likely
   secrets at display time, or show raw?
5. **Retention**: confirm "keep every transcript locally forever; no automatic
   pruning" (brief §3 history requirement).
6. **Drawer**: keep as quick view, or replace with the full view?
7. **Anchor precision visibility**: show "approximate position" for observed
   anchors, or hide the distinction?

## 5. States to design

| State | Must show |
| --- | --- |
| Loading (first page) | Skeleton; no false "empty". |
| Loading older | Inline indicator at the top; position kept. |
| Known empty | "No messages yet". |
| Partial history | "Earlier history is not available" gap row (imported or pre-journal). |
| Gap | Daemon down or source unreadable for a time span, with times. |
| Live | New entries append; "new messages below" when scrolled up. |
| Stale / source unavailable | Last known content with a clear stale marker and age. |
| Continuity unknown | After a daemon restart mid-turn. |
| Ended | Final state; history readable. |
| Unanchored event | Listed without a jump. |
| Jump target loading | Brief loading at the target; then highlight. |
| Read-only dashboard | Everything readable; no composer or answer controls. |
| Send failed / unknown outcome | Distinct; never shown as delivered. |
| Command already answered elsewhere | Card shows the answer and who answered. |
| Permission denied / offline | Standard dashboard handling; phone offline per DESIGN-N6. |

## 6. Acceptance conditions

- Every state in §5 has a screen or explicit spec with copy.
- Decisions 1–7 in §4 are answered in writing.
- Desktop and phone-width layouts are both specified (the phone reuses this view
  via WebView or native per MP-N1).
- Jump from a Commands page entry and from a merged-PR event is shown end to end.
- Kevin writes "DESIGN-E4 approved" on the research PR or in
  `context-and-decisions.md`.

## 7. Not in scope

- Editing, hiding or deleting transcript entries.
- New agent controls (pause/resume/interrupt/spawn) in this view.
- Running summaries (brief §3: not a committed requirement; never replaces the transcript).
- A combined cross-agent inbox.
