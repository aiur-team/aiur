---
ticket_id: MP-E5-C3-T01
feature_id: MP-E5
chunk_id: MP-E5-C3
bucket: 2-platform
title: Explicit Dictate / Converse choice in <.voice_input> (D16)
status: blocked
blocked_by: [DESIGN-E5, E5-OQ1, E5-OQ6, MP-E5-C1-T01, MP-E5-C1-T02, MP-E5-C2-T01, MP-E5-C2-T03]
prior_units: [U8]
prior_boundaries: [VOX, WEB]
prior_features: [ui-07]
prior_findings: []
size_owner: BROWSER (controller), WEB (component)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E5-C3-T01 — The D16 mic choice

## Identity and outcome

- **Bucket / feature / chunk:** 2-platform / MP-E5 / C3 D16 mode choice.
- **User value:** the operator always chooses, by an explicit click, whether speech becomes
  editable text (Dictate) or a discussion with the assistant (Converse). No mode is a
  default and nothing records on page load (D16, V1).
- **Deliverable:** `<.voice_input>` renders the choice in the form E5-OQ1 selects:
  - **(a) two always-visible buttons** "Dictate" and "Converse"; or
  - **(b) one mic button** that opens a two-option chooser (a `role="menu"` popover with two
    `menuitem` buttons, focus moved to the first item, `Escape` closes).
  The Dictate option starts today's dictation, now joining `voice:dictate` with the v1
  payload (MP-E5-C2-T01). The Converse option is shown per contract §7 from
  `voice.conversation` and wired in MP-E5-C3-T02. Device-picker placement follows E5-OQ6.
- **Non-goals:** the converse panel (MP-E6-C7); the legacy auto-submit button (C3-T03);
  state copy and Cancel (C6).

## Dependencies and blockers

- **Owner:** DESIGN-E5 approval; E5-OQ1 (layout a or b); E5-OQ6 (device picker placement).
  The ticket specifies both layouts so the implementer only applies the answer; no layout is
  invented here.
- **Predecessors:** C1-T01/T02 (component, split JS), C2-T01 (v1 join), C2-T03 (capability
  data).
- **May run concurrently with:** C4/C5 only after this lands (they render the same
  component).

## Verified starting point (base `45a290e3`)

| Item | Evidence |
| --- | --- |
| Today's two buttons | `conversation_drawer.ex:185-212` (Dictate message; Start interactive voice chat) |
| Mode routing in JS | `toggle(mode)` → `start(mode)` with `"dictation"` / `"conversation"` (`conversation-voice-controller.js:8-9,127-132,134-189`); topic chosen at `:221` |
| No mic before a click | `getUserMedia` is called only inside `start()` (`:155`); spec `units.browser.spec.mjs:382-492` stubs it |
| Capability data | `data-voice-stt-state` from MP-E5-C2-T03 |

## Chosen design

- The component gets `attr :layout, :atom, values: [:buttons, :chooser]`. The value is a
  single module attribute `@d16_layout` set from the E5-OQ1 answer, not a config key: the
  owner chose one product behaviour, and a config switch would be an unrequested option.
- Data attributes: Dictate control `data-voice-mode="dictate"`; Converse control
  `data-voice-mode="converse"`. The controller binds `[data-voice-mode]` and calls
  `start("dictation")` for `dictate`. The legacy `[data-voice-mic]` selector stays as an
  alias on the Dictate control so existing tests keep their handle.
- Converse visibility per contract §7 and client-capability-model §5 ("the choice sheet shows
  both options, each with its own state"): Converse renders with
  `aria-disabled="true"` and the reason text when `voice.conversation` is not
  `available`/`degraded`, unless E5-OQ4 says hide (then omitted when `not_installed`).
- The controller sends the v1 join payload: `{v: 1, mode: "dictate", surface, target,
  client_session_id}` where `surface` and `target` come from `data-voice-surface` /
  `data-voice-target` on the component root (set by each caller: the drawer passes
  `agent_composer` and `{kind: "worker", ticket}` from the composer's `target_key`).
- `client_session_id`: `crypto.randomUUID()` per activation.

## Implementation steps

1. Component: layout attr, mode controls, surface/target attrs, Converse disabled state.
2. Controller: bind `[data-voice-mode]`; join `voice:dictate` with the v1 payload; keep
   `voice:conversation` only for the legacy button.
3. Drawer call site passes `surface="agent_composer"` and the target.
4. CSS for the chooser in `dashboard.css` per the approved design.
5. Update `website/docs-app/concepts/units.md` §"Agent conversation and voice" (`:39-54`) and
   `website/docs-app/guide/gui.md` §"Writable controls" (`:82`).

## Non-happy paths

- `voice.stt` unavailable: Dictate is disabled with its reason (E5-OQ4 presentation, C6-T01).
- Chooser open when the drawer re-renders: the hook's `updated()` rebinds
  (`conversation-drawer-hook.js:30-38`); the popover's open state lives in the DOM element the
  patch preserves (stable `id`).
- Keyboard: both layouts reachable by Tab; chooser closes on `Escape` and returns focus to the
  mic button (`data-conversation-focus` restore, `conversation-drawer-hook.js:25-38`).

## Compatibility and rollout

- The legacy auto-submit button is unaffected until C3-T03.
- Browser cache: revalidated assets (`endpoint.ex:33-39`).
- Rollback: revert; dictation returns to the old button.

## Verification

| Test | Expected |
| --- | --- |
| browser "page load never requests the microphone" | `getUserMedia` spy 0 after load, after opening the chooser (layout b), after a LiveView patch |
| browser "Dictate starts dictation only" | click Dictate → join topic `voice:dictate`, payload `v: 1`, `mode: "dictate"`, `surface: "agent_composer"`, `target.kind: "worker"` |
| browser "Converse never starts dictation" | click Converse (enabled via fixture) → no `voice:dictate` join; emits the hand-off event of C3-T02 |
| browser "Converse is shown disabled with its reason when unavailable" | fixture `voice.conversation` `unavailable/not_installed` → control has `aria-disabled="true"` and the reason text; clicking does nothing |
| `conversation_drawer_test.exs` "renders the D16 choice" | both `data-voice-mode` values present (layout a) or the chooser trigger with two items (layout b) |

```bash
env -C src/browser npm run test:units
env -C src mise exec -- mix test test/aiur_web/operator_control_center/conversation_drawer_test.exs test/aiur_web/components/voice_input_test.exs
make -C src fmt-check lint
```

Run Elixir tests in an implementation worktree with `GITHUB_TOKEN`/`GH_TOKEN` unset and
hash-check `~/.aiur/github-budget/agent-token` before and after.

**Mutation checks.** Make the Converse control call `start("dictation")`: "Converse never
starts dictation" fails. Render Converse enabled regardless of capability (replace the
unavailable branch with the available markup): the "disabled with its reason" test fails.

Manual: AGENTS.md wrapper-tmux recipe to get a running agent; in a real browser open the
drawer, confirm no permission prompt until a choice is clicked, dictate, review, Send.

## Completion and handoff

- [ ] Choice rendered per E5-OQ1 on the drawer; tests green; docs updated in this PR.
- [ ] DESIGN-E5 copy used verbatim.
- **Dependents:** MP-E5-C3-T02, MP-E5-C3-T03, MP-E5-C4-*, MP-E5-C5-*, MP-E5-C6-*;
  DESIGN-N6/N7 reuse the same choice.
