---
ticket_id: MP-R5-C4-T02
feature_id: MP-R5
chunk_id: MP-R5-C4
bucket: 1-refactor
title: Delete the unwired Stream Deck sidecar ElevenLabs TTS (key-holding code that contradicts the daemon-only-credential rule)
status: blocked
blocked_by: [DESIGN-R5]
prior_units: [U7]
prior_boundaries: ["SD #35", "VOX #36"]
prior_features: [integrations-51, ui-16]
prior_findings: []
size_owner: n/a (deletion)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R5-C4-T02 — Delete the unwired sidecar ElevenLabs TTS

## Identity and outcome

- **Bucket / feature / chunk:** 1-refactor / MP-R5 / C4.
- **User value:** the sidecar source no longer contains a provider client
  that takes an `apiKey`. That contradicts contract V4 ("provider credentials
  are held only by the daemon") and the sidecar's own docs (`audio/index.ts:13`,
  `relay.ts:4`). Nobody can wire it by accident later.
- **Deliverable:** delete four files:
  - `packages/streamdeck/src/audio/elevenlabs-tts.ts`;
  - `packages/streamdeck/src/audio/node-fetch.ts`;
  - `packages/streamdeck/test/audio/elevenlabs-tts.test.ts`;
  - `packages/streamdeck/test/audio/node-fetch.test.ts`.
- **Non-goals:**
  - `packages/streamdeck/src/audio/tts.ts` stays. It holds no credential; it
    only defines an "unavailable" TTS provider shape (tested by
    `test/audio/tts.test.ts`).
  - Deck spoken replies, if ever wanted, come from the daemon (contract §4 note).

## Dependencies and blockers

- **Blocked by:** DESIGN-R5 §3.2 ("delete the unwired sidecar TTS":
  recommended delete). If the owner chooses "keep", this ticket is closed as
  not-doing, and the file gets a header comment that it must never be wired
  (contract §4).
- **May run concurrently with:** every other ticket; no shared files.

## Verified starting point (base `45a290e3`) — plan RQ3 answered

Import graph (from `git grep` over `packages/streamdeck` and `scripts`):

- `src/audio/elevenlabs-tts.ts:18-19` imports `./tts.js` (types) and
  `./node-fetch.js`.
- `src/audio/node-fetch.ts:10` imports only **types** (`FetchLike`,
  `FetchResponse`) from `./elevenlabs-tts.js`.
- Nothing else imports either file. `src/audio/index.ts` (the audio barrel,
  `:22-67`), `src/main.ts` and `scripts/` do not reference them. Only their
  own tests do (`test/audio/elevenlabs-tts.test.ts:9`,
  `test/audio/node-fetch.test.ts:2`).
- **Conclusion:** the two files are an island, unreachable from `main.ts`.
  `channel.ts:286` defines its own, unrelated `FetchLike`.

Coverage: `packages/streamdeck/vitest.config.ts:9-24` requires 100% on
`src/**`. Deleting covered files with their tests keeps the thresholds.

## Chosen design

Delete all four files in one commit. Make no other edits. Before deleting,
re-run the grep at the implementation head:

```bash
git -C <worktree> grep -n -E "elevenlabs-tts|node-fetch" -- packages/streamdeck scripts
```

Expected output: only the four files themselves. Anything else means the
island got wired; stop and report.

## Implementation steps

1. Run the grep above.
2. `git rm` the four files.
3. Run the sidecar checks.

## Non-happy paths

- **A new importer appeared after the base:** stop. Do not delete. Report it to
  the DESIGN-R5 owner, because wiring would violate V4.

## Compatibility and rollout

- The sidecar's runtime is unchanged (dead code), and so is the packaged
  artifact contents' behaviour.
- `streamdeck-package.yml` rebuilds the nightly when `packages/streamdeck/**`
  changes (`:29`). That is expected.
- Rollback means reverting the commit.

## Verification

```bash
env -C <worktree>/packages/streamdeck npm ci
env -C <worktree>/packages/streamdeck npm run lint
env -C <worktree>/packages/streamdeck npm test          # typecheck:test + vitest with 100% coverage
env -C <worktree>/packages/streamdeck npm run build
env -C <worktree>/packages/streamdeck npm run test:package
```

Expected: all pass. This is a pure deletion, so the AGENTS.md mutation rule
does not apply: there is no new test. State that in the PR body.

## Completion and handoff

- [ ] The four files are gone, and the grep returns nothing.
- [ ] The sidecar CI job is green (`.github/workflows/ci.yml:668-703`).
- [ ] Docs: none. The sidecar docs already say it holds no key.
- **Dependents:** the voice-session contract §4 note about the unwired TTS can
  be removed (CR-R5-3).
