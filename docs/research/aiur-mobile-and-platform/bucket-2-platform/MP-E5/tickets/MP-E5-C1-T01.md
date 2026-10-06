---
ticket_id: MP-E5-C1-T01
feature_id: MP-E5
chunk_id: MP-E5-C1
bucket: 2-platform
title: Extract the drawer's voice markup into a reusable <.voice_input> function component
status: ready
blocked_by: ["DESIGN-E5 (waived for this ticket: behaviour-preserving extraction, DESIGN-E5 header)", MP-R5-C1-T02]
prior_units: [U8]
prior_boundaries: [VOX, WEB]
prior_features: [ui-07, ui-08]
prior_findings: []
size_owner: WEB (conversation_drawer.ex is 276 lines; no split needed)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E5-C1-T01 — Extract `<.voice_input>` from the conversation drawer

## Identity and outcome

- **Bucket / feature / chunk:** 2-platform / MP-E5 dashboard voice input / C1 reusable voice
  input component (behaviour-preserving).
- **User value:** none visible. It removes the copy-paste that already left the agent log
  modal without voice (`agent_log_modal.ex:43-57` has the composer but no mic), so C4 and C5
  can add voice to other surfaces by rendering one component.
- **Deliverable:** a new function component `AiurWeb.Components.VoiceInput.voice_input/1`
  (PROPOSED path `src/lib/aiur_web/components/voice_input.ex`) that renders exactly the markup
  at `conversation_drawer.ex:183-231`, and the drawer calling it.
- **Non-goals:** no new button, copy, state or surface; no JS change (MP-E5-C1-T02); no
  channel change (MP-E5-C2); no D16 choice (MP-E5-C3).

## Dependencies and blockers

- **Predecessors:** MP-R5-C1-T02 (the channel moved to the `Aiur.Voice` facade). This ticket
  does not touch the channel, but every E5 ticket is scheduled after R5-C1 so the plan-refresh
  paths are stable (wave 4 after wave 1).
- **Design gate:** DESIGN-E5 explicitly allows C1 before approval because nothing visible
  changes. A render-equality test (below) is the proof.
- **Contracts:** none consumed beyond today's DOM contract with
  `conversation-voice-controller.js` (the `data-voice-*` selectors).
- **May run concurrently with:** MP-E5-C1-T02 (JS split; different files), MP-E5-C2-*.

## Verified starting point (base `45a290e3`)

| Item | Evidence |
| --- | --- |
| Voice markup | `src/lib/aiur_web/components/operator_control_center/conversation_drawer.ex:183-231`: `div.agent-voice-tools` → `div.agent-voice-controls` with `button[data-voice-mic]` (`aria-label="Dictate message"`, `data-conversation-focus="dictation"`, `:185-198`), `button[data-voice-conversation]` (`aria-label="Start interactive voice chat"`, `data-conversation-focus="conversation"`, `:199-212`), `label.agent-voice-device-label` + `select[data-voice-device]` (`:213-218`), `canvas[data-voice-waveform]` 360×52 (`:220-227`), `p[data-voice-status]` `role="status" aria-live="polite"` with "Press the microphone to dictate. Review the text, then press Send." (`:228-230`) |
| Siblings the controller also binds | `textarea[data-voice-input]` (`:174-182`) and `button[data-voice-send]` (`:234`) stay in the drawer: they belong to the composer, not to voice |
| Form marker | `form[data-voice-composer]` (`:166-172`) |
| Controller binding | `conversation-voice-controller.js:27-55` queries each selector inside the hook element |
| Focus restore | `data-conversation-focus` values are read by `conversation-drawer-hook.js:25-38` (`activeFocusKey`) |
| Existing tests | `src/test/aiur_web/operator_control_center/conversation_drawer_test.exs:191` "renders dictation and interactive conversation controls in the standard composer"; browser spec `src/browser/tests/units.browser.spec.mjs:326-690` (selectors listed in the C1 RQ-E5-2 note below) |

**RQ-E5-2 (resolved).** The browser spec relies on: `[data-voice-status]`,
`[data-voice-input]`, `[data-voice-send]`, `[data-voice-mic]`, `[data-voice-conversation]`,
`[data-voice-waveform]`; button names "Start interactive voice chat", "Stop interactive voice
chat", "Cancel waiting for voice reply"; globals `window.AiurVoiceSocket` and
`window.AiurConversationVoiceController`; socket option `params._csrf_token`
(`units.browser.spec.mjs:347,412-464,597-654`). All are preserved.

## Chosen design

- One stateless function component. Attributes:
  - `id` (string, required) — prefix for any id it renders (none today; reserved).
  - `legacy_conversation` (boolean, default `true`) — renders today's "Start interactive voice
    chat" button. C3-T03 changes this per E5-OQ2; until then every caller passes the default.
  - `status_copy` (string, default today's sentence).
- It renders **only** the `div.agent-voice-tools` subtree. The textarea, Send button and form
  stay with the caller, because each surface owns its own submit event (V7).
- Rationale: the plan's alternative "copy markup per surface" already failed once
  (`agent_log_modal.ex` lacks voice). A component with no behaviour flags beyond the legacy
  button keeps C1 behaviour-preserving.

## Implementation steps

1. Create `src/lib/aiur_web/components/voice_input.ex` (PROPOSED) with `use Phoenix.Component`,
   the three attrs, and the `:183-231` markup moved verbatim.
2. In `conversation_drawer.ex`, replace `:183-231` with
   `<AiurWeb.Components.VoiceInput.voice_input id={"#{@id}-voice"} />`.
3. Add `src/test/aiur_web/components/voice_input_test.exs` (PROPOSED).
4. No CSS change: class names are identical.

## Non-happy paths

- Read-only dashboard: unchanged; the whole form is behind `:if={@composer_writable}`
  (`conversation_drawer.ex:167`), so the component is never rendered.
- Non-unique target: unchanged (`:238-240`).
- n/a for privacy, concurrency, retries — no runtime behaviour changes.

## Compatibility and rollout

No config, migration or flag. Rollback is a revert. HTML output is byte-equivalent for the
attribute set (verified by test), so the dashboard CSS and the browser spec are unaffected.

## Verification

Tests (all PROPOSED names):

| Test | Expected |
| --- | --- |
| `voice_input_test.exs` "renders every data-voice control the controller binds" | Parsed HTML contains exactly one each of `[data-voice-mic]`, `[data-voice-conversation]`, `[data-voice-device]`, `[data-voice-waveform]`, `[data-voice-status]` with today's aria-labels and copy |
| `voice_input_test.exs` "omits the legacy conversation button when legacy_conversation is false" | No `[data-voice-conversation]` (guards C3-T03's switch) |
| `conversation_drawer_test.exs` "voice tools subtree is identical to the pre-extraction markup" | Compare `Floki.find(html, ".agent-voice-tools")` attribute lists (tag, attributes, text; not whitespace) against a fixture captured from base `45a290e3` and stored in the test |
| existing `conversation_drawer_test.exs:191` | passes unchanged |
| browser `units.browser.spec.mjs` voice tests (`:326`, `:354`, `:382`, `:494`, `:545`, `:622`, `:659`) | pass unchanged |

Commands:

```bash
env -C src mise exec -- mix test test/aiur_web/components/voice_input_test.exs test/aiur_web/operator_control_center/conversation_drawer_test.exs
env -C src/browser npm run test:units
make -C src fmt-check lint
```

Run in an implementation worktree with `GITHUB_TOKEN`/`GH_TOKEN` unset and hash-check
`~/.aiur/github-budget/agent-token` before and after: a local `mix test` boots aiur and can
overwrite it.

**Mutation check.** The structural-equality test is a deliberate regression guard for an
extraction (it passes on `main` by construction, so it is labelled "guards C1 extraction" in
its name and not counted as coverage of new behaviour, per AGENTS.md). The
`legacy_conversation: false` test must fail if the `:if={@legacy_conversation}` hunk is
removed from the component.

Manual: open `/chat/<owner>/<repo>/<id>` with a running agent and confirm the drawer looks the
same; press Dictate and confirm text streams into the box (AGENTS.md wrapper-tmux recipe for
the agent, a real browser for the page).

## Completion and handoff

- [ ] Component exists; drawer uses it; no visible change.
- [ ] All existing drawer and browser voice tests pass unchanged.
- [ ] Docs: none (no user-facing change, AGENTS.md "Docs ship with the change" exemption for
      internal refactors).
- **Dependents:** MP-E5-C3-T01, MP-E5-C4-T01, MP-E5-C4-T02, MP-E5-C5-T01, MP-E5-C5-T02.
