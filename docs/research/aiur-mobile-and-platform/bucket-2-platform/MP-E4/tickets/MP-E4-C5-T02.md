---
ticket_id: MP-E4-C5-T02
feature_id: MP-E4
chunk_id: MP-E4-C5
bucket: 2-platform
title: "Entry rendering: messages, reasoning, commands, tool results, diffs, operator messages, gaps, session dividers"
status: blocked
blocked_by: [DESIGN-E4, MP-E4-C5-T01]
prior_units: [U8]
prior_boundaries: [WEB]
prior_features: []
prior_findings: [DESIGN-E4 decisions 3 (reasoning/tool output) and 4 (secret masking)]
size_owner: "U8 WEB owner (new component module)"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E4-C5-T02 — Entry rendering

## Identity and outcome

- Bucket 2 · MP-E4 · C5 · T02.
- **User value:** every entry kind is readable — agent prose as Markdown,
  commands with their output, file edits as diffs — with reasoning and raw tool
  output shown, collapsed or hidden as Kevin decided.
- **Deliverable:** `AiurWeb.Conversation.Components.entry/1` with one clause per
  kind (contract §5), a gap row, a session divider, truncation markers, and the
  DESIGN-E4 masking choice.
- **Non-goals:** event rail (T03); composer (C6); editing or hiding entries
  (D15 — no such control exists).

## Dependencies and blockers

- **DESIGN-E4 decisions 3 and 4** decide defaults for reasoning/tool output and
  secret masking. Do not choose them here.
- MP-E4-C5-T01.

## Verified starting point

- Markdown renderer: `AiurWeb.Markdown.render/1` (`src/lib/aiur_web/markdown.ex:28-40`).
- Redaction: `Aiur.SecretRedactor.redact/1` (`src/lib/aiur/secret_redactor.ex:50`),
  already used to reject secret-looking ids (`opaque_identifier.ex:19-22`).
- Today's drawer renders the bounded `LiveConversation` projection
  (`operator_control_center/conversation_drawer.ex`, 276 lines) and the agent
  log modal reads the workspace log (`agent_log_modal.ex:148-162`); neither
  renders diffs from a durable source.
- Diff text arrives in `output` of `diff` entries (Codex `fileChange` diff,
  `codex/transcript.ex:232-245`; Claude edit diff, `claude/transcript.ex:285-294`).

## Chosen design

| Kind | Rendering (defaults pending DESIGN-E4) |
| --- | --- |
| `message` (agent) | `Markdown.render/1` of `body` |
| `reasoning` | per decision 3: shown / collapsed `<details>` / hidden (hidden still counts in "N hidden" so nothing silently vanishes) |
| `command` | `$ <command>` line, exit badge when non-zero, `output` in a collapsible pre block |
| `tool_result` | tool name + success badge; `output` collapsible |
| `diff` | file title; unified diff lines classed `+`/`-`/`@@`; long diffs collapsed after 200 lines |
| `operator_message` | right-aligned operator bubble; `executor_operator` styled per DESIGN-E3 |
| `system` | muted line; alerts flagged |
| `gap` | full-width row "No record from <from> to <to>" + reason copy per DESIGN-E4 |
| session divider | between sessions: start reason and time ("Resumed after restart", "New session after /clear", …) |

- **Truncation:** when `body_truncated` / `output_truncated`, render the marker
  "Middle of this output not stored (N bytes)". Never imply completeness.
- **Masking (decision 4):** if approved, apply `SecretRedactor.redact/1` to
  `body` and `output` at render time only (storage is never rewritten, D15),
  and show "masked" on the entry; a per-entry "show raw" control appears only
  in a writable dashboard. If not approved, render raw with the page-level
  warning from C8-T02.
- **Safety:** all text is escaped by HEEx; Markdown output goes through
  `AiurWeb.Markdown` (existing sanitizer path) only.

## Implementation steps

1. `components.ex`: `entry/1` dispatch on `kind`, `gap/1`, `session_divider/1`,
   `truncation_marker/1`.
2. CSS in the existing dashboard stylesheet (compile-time embedded; recompile
   needed).
3. Replace T01's placeholder.

## Non-happy paths

- Unknown `kind` (a future `v`) → a generic row with the kind name; never a crash
  (readers accept unknown fields, contract §13).
- Invalid UTF-8 cannot reach here (T01 replaces it at write).
- Extremely long single line → CSS wrap; no horizontal page scroll at 390 px.

## Compatibility and rollout

- Rendering only. Rollback: revert to the placeholder.

## Verification

```bash
env -C src HOME="$(mktemp -d)" -u GITHUB_TOKEN -u GH_TOKEN mise exec -- mix test \
  test/aiur_web/conversation/components_test.exs
```

| Test | Expected | Fails without |
| --- | --- | --- |
| "each kind renders its distinguishing element" (table test) | e.g. `$ git status`, `@@` line with diff class | each clause |
| "truncated output shows the not-stored marker" | marker text with byte count | marker branch |
| "hidden reasoning is counted, not dropped" (if decision 3 = hidden) | "1 reasoning block hidden" | the count |
| "masking replaces a token-shaped string and labels it" (if decision 4 = mask) | redacted text + "masked" | `redact/1` call |
| "unknown kind renders a generic row" | row with kind | fallback clause |
| "markdown script tag is escaped" | no `<script>` in output | Markdown path |

Browser: extend `tests/conversation-view.browser.spec.mjs` with a fixture of each
kind; check at 390 px and 1280 px that no entry overflows horizontally.

## Completion and handoff

- [ ] All kinds rendered per DESIGN-E4; masking behaviour matches decision 4.
- Dependents: C5-T03, MP-E3-C6 (same components).
- Docs: C5-T04.
