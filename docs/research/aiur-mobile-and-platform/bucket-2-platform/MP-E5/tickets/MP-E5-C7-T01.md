---
ticket_id: MP-E5-C7-T01
feature_id: MP-E5
chunk_id: MP-E5-C7
bucket: 2-platform
title: Dashboard voice end-to-end verification and docs audit
status: blocked
blocked_by: [DESIGN-E5, MP-E5-C3-T01, MP-E5-C4-T01, MP-E5-C4-T02, MP-E5-C5-T01, MP-E5-C5-T02, MP-E5-C6-T01, MP-E5-C6-T02, MP-E5-C6-T03, MP-E5-C8-T02]
prior_units: []
prior_boundaries: [VOX, WEB]
prior_features: [ui-07, ui-08]
prior_findings: []
size_owner: n/a (no production code)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E5-C7-T01 — End-to-end verification and docs audit

## Identity and outcome

- **Bucket / feature / chunk:** 2-platform / MP-E5 / C7 docs and end-to-end verification.
- **User value:** the feature is shown working on the real dashboard against a real agent,
  and every doc page the feature changed is correct.
- **Deliverable:** (1) a recorded manual run of the checklist below, attached to the final PR
  (screenshots and `tmux capture-pane` text); (2) a docs audit PR fixing any page still wrong;
  (3) removal of the `voice:dictation` alias once no shipped client uses it (MP-E5-C2-T01
  compatibility note) — or a dated note saying why it stays.
- **Non-goals:** new behaviour.

## Dependencies and blockers

All E5 user-visible tickets; DESIGN-E5 approval.

## Verified starting point (base `45a290e3`)

Docs pages that mention voice: `website/docs-app/apis/elevenlabs.md` (`:3-57`),
`website/docs-app/concepts/units.md` (`:39-54`), `website/docs-app/guide/gui.md` §"Writable
controls" (`:82`), `website/docs-app/guide/stream-deck.md` (voice input, linked from
`elevenlabs.md:57`).

## Chosen design — checklist

Launch per AGENTS.md "Manual testing — the only definition": wrapper tmux
`scripts/aiurdev --test`, wait for a running agent, then use a **real browser** on the
dashboard (the dashboard is a web surface; the TUI recipe provides the running agents and
Commands).

| # | Surface | Scenario | Expected on screen |
| --- | --- | --- | --- |
| 1 | worker drawer | load page | no mic permission prompt |
| 2 | worker drawer | Dictate → speak → Stop | partial then final text; status "ready"; nothing sent |
| 3 | worker drawer | edit → Send | agent pane (`capture-pane` on `0.1`) shows the message |
| 4 | worker drawer | Dictate → Cancel / Escape | field restored; drawer stays open |
| 5 | agent log modal | 2–4 | same |
| 6 | Command detail | Dictate custom response → Record | Command answered; agent receives it |
| 7 | Command detail | answer the same Command from another tab during dictation → Record | conflict copy; text kept |
| 8 | revision form | Dictate revised response → Record revision | revision recorded |
| 9 | Executor composer | Dictate → Send | Executor conversation shows the message |
| 10 | any | key removed from `.aiur/config` and daemon restarted | unavailable presentation per E5-OQ4; typing works |
| 11 | any | browser permission denied | permission copy; typing works |
| 12 | any | 5-minute dictation | session-limit copy; text kept |
| 13 | paired phone (if MP-N6 build exists) | device ticket → dictate → revoke device mid-session | session ends within 15 s |

## Implementation steps

1. Run the checklist; record results in the PR body with screenshots.
2. Read each docs page above against the shipped behaviour; fix in the same PR.
3. Check `voice:dictation` usage in shipped clients (`git grep -n "voice:dictation"` in
   `src/priv/static`, `packages/`); remove the alias if none.

## Non-happy paths

Rows 7, 10–13 cover them.

## Compatibility and rollout

Docs only, plus the optional alias removal (revert to restore).

## Verification

```bash
tmux -L claude-driver new-session -d -s aiur-driver -x 220 -y 60 \
  "bash -c 'unset TMUX; AIUR_DEBUG=1 exec mise exec -- ./scripts/aiurdev --test' 2>&1 | tee /tmp/aiur-driver-startup.log; sleep 3600"
env -C src/browser npm run test:units
python3 scripts/check-config-docs.py
```

Cleanup: `mise exec -- ./scripts/aiurdev stop`; `tmux -L claude-driver kill-server`.

## Completion and handoff

- [ ] All 13 rows recorded (row 13 marked "n/a — MP-N6 not built" if so).
- [ ] Docs pages correct; contract §10 privacy table reflected in `elevenlabs.md`.
- [ ] Alias decision recorded.
- **Dependents:** MP-N6 device validation reuses rows 1–4 and 13.
