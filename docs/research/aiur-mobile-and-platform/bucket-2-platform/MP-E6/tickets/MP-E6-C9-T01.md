---
ticket_id: MP-E6-C9-T01
feature_id: MP-E6
chunk_id: MP-E6-C9
bucket: 2-platform
title: Voice assistant docs (privacy disclosure, concepts, references) and end-to-end manual verification
status: blocked
blocked_by: [DESIGN-E6, E6-OQ7, MP-E6-C3-T02, MP-E6-C6-T03, MP-E6-C7-T02, MP-E6-C7-T03, MP-E6-C7-T04, MP-E6-C8-T01]
prior_units: []
prior_boundaries: [VOX]
prior_features: [integrations-51]
prior_findings: []
size_owner: n/a (docs only)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E6-C9-T01 — Docs and end-to-end verification

## Identity and outcome

- **Bucket / feature / chunk:** 2-platform / MP-E6 / C9.
- **User value:** the operator knows exactly what leaves the machine when using the
  assistant, how it relates to the real agent, and the feature is shown working end to end.
- **Deliverable:**
  1. `website/docs-app/apis/elevenlabs.md`: "What voice does" gains the assistant row; API
     key permissions table gains the Agents permission; privacy table replaced by contract
     §10's table (dictate, spoken reply, converse) including "Zero Retention Mode is
     Enterprise-only" and "aiur deletes each provider conversation after saving it locally".
  2. A section "Voice assistant" in an existing concepts page — `concepts/units.md` (where
     agent conversation and voice live today, `:39-54`) — covering: discussion vs
     instruction, drafts and Confirm, consults, what context it receives, transcripts kept in
     full.
  3. Audit `reference/configuration.md` (`voice.conversation.*`) and `reference/cli.md`
     (`aiur voice setup`, `aiur voice transcripts`) shipped by C3/C6.
  4. A recorded manual run.

## Dependencies and blockers

DESIGN-E6 (copy), E6-OQ7 (disclosure accepted), all user-visible E6 tickets.

## Verified starting point (base `45a290e3`)

`apis/elevenlabs.md:1-57` (no assistant content; privacy table `:48-55`);
`concepts/units.md:39-54`.

## Chosen design

Edit existing pages only (AGENTS.md "prefer editing an existing page"); the privacy table is
copied from contract §10 so docs and contract cannot diverge silently.

## Implementation steps

1. Update `apis/elevenlabs.md` and `concepts/units.md` as listed.
2. Audit the two reference pages against the shipped keys and commands.
3. Run the manual checklist below and attach results to the PR.

## Non-happy paths

Rows 10 and 11 below cover privacy failures; a disclosure that cannot be verified (row 11
fails) blocks completion and goes back to the owner (E6-OQ7).

## Compatibility and rollout

Docs only. Rollback: revert.

## Manual checklist

Launch per AGENTS.md "Manual testing" (wrapper tmux `scripts/aiurdev --test`), then a real
browser on the dashboard:

| # | Scenario | Expected |
| --- | --- | --- |
| 1 | open a worker drawer, choose Converse | panel opens; no mic prompt until Start |
| 2 | Start, brain-dump about the ticket | assistant replies by voice; transcript shows turns |
| 3 | ask "what did the agent last say?" | tool call answered from real conversation |
| 4 | ask it to tell the agent to add a test | instruction draft card appears; agent pane (`tmux capture-pane` on `0.1`) shows nothing yet |
| 5 | Confirm | agent pane shows the message labelled as voice-originated (if E7 `origin` accepted) |
| 6 | consult the agent | framed question visible in the agent pane; reply returns to the assistant |
| 7 | interrupt the assistant mid-sentence | playback stops |
| 8 | End; open history; Continue | open drafts carried |
| 9 | `aiur voice transcripts <id>` | full transcript printed |
| 10 | set `record_voice: true` on the agent via the provider console | next Start refused `privacy_preflight_failed`; `aiur voice setup --repair` fixes it |
| 11 | check the provider console after End | conversation deleted |

## Verification

```bash
python3 scripts/check-config-docs.py
env -C src/browser npm run test:units
```

## Completion and handoff

- [ ] Docs pages updated; all 11 rows recorded in the PR body.
- **Dependents:** DESIGN-N6/N7 phone/watch converse notes.
