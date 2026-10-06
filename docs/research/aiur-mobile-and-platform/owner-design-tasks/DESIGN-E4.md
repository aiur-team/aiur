---
design_task: DESIGN-E4
feature_id: MP-E4
owner: Kevin
status: open (awaiting explicit approval)
blocks: [MP-E3-C6-T01, MP-E4-C1-T01, MP-E4-C1-T02, MP-E4-C1-T03, MP-E4-C2-T01, MP-E4-C2-T02, MP-E4-C3-T01, MP-E4-C3-T02, MP-E4-C3-T03, MP-E4-C4-T01, MP-E4-C4-T02, MP-E4-C5-T01, MP-E4-C5-T02, MP-E4-C5-T03, MP-E4-C5-T04, MP-E4-C6-T01, MP-E4-C6-T02, MP-E4-C7-T01, MP-E4-C8-T01, MP-E4-C8-T02, MP-E6-C8-T03, MP-N6-C2-T03]
blocks_note: "Phase D: the list is the tickets whose blocked_by names DESIGN-E4 (waived entries excluded). Earlier wording: every MP-E4 implementation ticket (MP-E4-C1..C8)"
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
   events/transcript, or other. Recommended starting point: **one chronology with an
   event rail**, because it keeps the transcript the primary record and the Stream Deck
   already proves the "event jumps into the transcript" model.
2. **Default jump points**: which kinds are on by default; are CI results and
   comments noise? Recommended: **on — progress, push, PR opened, PR merged, Command;
   off — CI results and review comments** (one filter chip turns them on), because those
   two are the most frequent and least often the reason for a jump.
3. **Reasoning and raw tool output**: shown, collapsed, or hidden by default?
   Recommended: **collapsed**, because the full chronology must stay one tap away while
   the default view stays readable.
4. **Secrets**: transcripts may contain secrets an agent printed. Mask likely
   secrets at display time, or show raw? Recommended: **mask by default, with a reveal
   control for loopback dashboard sessions**; device principals always receive the
   redacted body (Phase D, security review M5). Reason: the transcript is now served to
   phones, and the redactor already exists for voice.
5. **Retention**: confirm "keep every transcript locally forever; no automatic
   pruning" (brief §3 history requirement). Measured disk cost (MP-E4-C1-T00,
   preliminary, 2026-10-06; Phase D, CR-E4-9): lower bound 112 KB per hour per agent
   (p50); upper bound 228 KB/h (p50) and 3.0 MB/h (p90) at the 64 KiB body cap. The final
   C1-T00 figure replaces these before you approve. Recommended: **confirm keep-forever**, because
   brief §3 requires full history; at the p50 upper bound that is about 2 GB per
   agent-year of continuous work (p90: about 26 GB). Revisit if the final C1-T00 figure is
   much larger.
6. **Drawer**: keep as quick view, or replace with the full view? Recommended: **keep
   it, with a "Full conversation" link**, because the drawer is the fast path from the
   units table.
7. **Anchor precision visibility**: show "approximate position" for observed
   anchors, or hide the distinction? Recommended: **show a subtle marker**, because a
   silent approximate jump would read as an exact one.
8. **Inline Command card placement** (Phase D, review T-8; used by MP-E4-C6-T02). Where an
   open Command of this agent appears in the conversation. Options: (a) at its anchor
   position in the chronology, with a pinned "Open Command" chip at the top that jumps to
   it; (b) always pinned at the top. When the Command has no anchor: (i) pinned at the top
   with "position unknown"; (ii) a link to `/commands/:id` only. Recommended: **(a) and
   (i)**, because the card then sits next to the work that caused it and is never lost.
   The card's content and states stay DESIGN-E2 §4's.

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
- Every decision in §4 (1–8, including 8 card placement) is answered in writing.
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
