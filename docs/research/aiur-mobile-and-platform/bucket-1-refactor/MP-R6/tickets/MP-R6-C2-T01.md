---
ticket_id: MP-R6-C2-T01
feature_id: MP-R6
chunk_id: MP-R6-C2
bucket: 1-refactor
title: Daemon owns the Stream Deck visual contract — the canonical JSON moves to src/priv, the sidecar keeps a byte-checked mirror, and core compiles without packages/streamdeck
status: blocked
blocked_by: [DESIGN-R6, MP-R6-C1-T01]
prior_units: [U8]
prior_boundaries: ["SD #35", "WEB #34"]
prior_features: [ui-16]
prior_findings: []
size_owner: "DECK_WEB / DECK_PKG: only small edits, no file over 500 lines grows"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R6-C2-T01 — The daemon owns the Stream Deck visual contract

## Identity and outcome

- **Bucket / feature / chunk:** 1-refactor / MP-R6 / C2.
- **User value:** none visible. Key faces, colours and badges are unchanged on
  the deck and in the emulator. Building the daemon no longer needs the deck
  package's source tree. The protocol owner is the daemon, which `SD` #35 names
  as the precondition for the sidecar ever becoming its own repository.
- **Deliverable:**
  1. The canonical `key-face-contract.json` and `key-face-parity-vectors.json`
     move to PROPOSED `src/priv/streamdeck/`.
  2. `AiurWeb.StreamdeckKeyFaceContract` and its test read them from there.
  3. The sidecar keeps **mirror copies** at its current paths. A sidecar test
     fails if a mirror differs by one byte from the canonical file.
  4. An ExUnit source-scan test asserts that nothing under `src/lib`,
     `src/config` or `src/mix.exs` references `packages/streamdeck`.
- **Non-goals:**
  - changing any contract value;
  - changing the sidecar build (`tsc`, `rootDir: src`);
  - a new `packages/aiur-deck-protocol` (rejected below);
  - moving `packages/streamdeck` out of the monorepo (`ui-16`).

## Dependencies and blockers

- **Blocked by:** DESIGN-R6, including §2.1: is hardware re-proof required
  before this merges, or are the emulator plus automated tests enough?
- **Predecessor:** MP-R6-C1-T01. After it, the badge vocabulary comes from
  `Aiur.AgentEventFeed.directions/0`, and both tickets touch
  `streamdeck_key_face_contract.ex:14`.
- **May run concurrently with:** MP-R5 tickets and MP-R6-C3-T01.

## Verified starting point (base `45a290e3`)

- **Core:** `src/lib/aiur_web/streamdeck_key_face_contract.ex:10-12` reads the
  contract at compile time from
  `Path.expand("../../../packages/streamdeck/src/key-face-contract.json", __DIR__)`,
  with `@external_resource`, and raises if states or badges are not exhaustive
  (`:13-25`).
- **Core test:** `src/test/aiur_web/streamdeck_key_face_contract_test.exs:10-12`
  reads the vectors from
  `../../../packages/streamdeck/src/key-face-parity-vectors.json` at compile
  time.
- **Sidecar:**
  - `packages/streamdeck/src/key-face-contract.ts:1` imports
    `./key-face-contract.json` (`with { type: "json" }`);
  - `packages/streamdeck/test/key-face-contract.test.ts:7` imports
    `../src/key-face-parity-vectors.json`;
  - `tsconfig.json` has `rootDir: "src"` and `resolveJsonModule: true`, so the
    sidecar cannot import a JSON file outside `src/` without changing its
    build.
- **Packaging:**
  - `packages/streamdeck/package.json` is `"private": true`. The sidecar ships
    as a GitHub release archive built by `scripts/build-package.mjs` from
    `dist/` (`:45`), not via npm.
  - The Elixir release ships `src/priv` (Phoenix static assets already live
    there, for example `src/priv/static/conversation-voice-controller.js`).
- **CI:**
  - the `streamdeck` job runs `npm ci`, lint, `npm test` and build on every
    non-docs change (`.github/workflows/ci.yml:668-703`);
  - the Elixir jobs compile `src/`.
- **Other core references to the package path:** a grep for
  `packages/streamdeck` under `src/lib` finds only the contract module's
  `@contract_path`. Run it again at implementation.

## Chosen design — plan RQ2 answered

| Option | Verdict |
| --- | --- |
| A. Canonical in `src/priv/streamdeck/`, sidecar keeps a byte-checked mirror | **Chosen.** The release already ships `priv`. The sidecar build is untouched (`rootDir: src` holds). Drift is caught by a test that runs in the always-on `streamdeck` CI job. |
| B. Canonical in `src/priv`, the sidecar copies it in a `prebuild`/`pretest` script | Rejected. It adds generated files and npm lifecycle scripts, and running `vitest` alone would read a stale or missing copy. |
| C. New `packages/aiur-deck-protocol` | Rejected. A new package with one consumer fails MP-R1's promotion test (criterion 5) and adds a workspace for two JSON files. |
| D. `packages/aiur-style` | Rejected (plan § 3 C): that is the site design system. |

The mirror rule is: **edit the canonical file, then copy it.** The sidecar test
names both paths and prints the `cp` command when they differ.

## Implementation steps

1. `git mv` both JSON files into `src/priv/streamdeck/`, then copy them back to
   `packages/streamdeck/src/`, so both exist with identical bytes.
2. `streamdeck_key_face_contract.ex:10`: change `@contract_path` to
   `Path.expand("../../priv/streamdeck/key-face-contract.json", __DIR__)`.
   Verify the relative depth: the module is at
   `src/lib/aiur_web/streamdeck_key_face_contract.ex`.
3. `streamdeck_key_face_contract_test.exs:10`: point `@vectors_path` at
   `src/priv/streamdeck/key-face-parity-vectors.json`.
4. Add a sidecar test, PROPOSED `packages/streamdeck/test/protocol-mirror.test.ts`:
   - read both canonical files via `new URL("../../../src/priv/streamdeck/<name>", import.meta.url)`;
   - read both mirrors;
   - `expect(mirror).toEqual(canonical)` as byte buffers;
   - the failure message is
     `copy src/priv/streamdeck/<name> to packages/streamdeck/src/<name>`.

   Tests compile under `tsconfig.test.json`, which sets `rootDir: "."` and
   includes `test` (verified at base). The files are read with `fs`, not
   imported.
5. Add a core test, PROPOSED `src/test/aiur_web/streamdeck_package_independence_test.exs`:
   scan `src/lib/**/*.ex`, `src/config/*.exs` and `src/mix.exs` for the
   substring `packages/streamdeck`, and assert there are none. This is the RC-11
   source-scan pattern; MP-R1-C1's checker absorbs it later.
6. One-time manual proof (plan § 7.4). In a throwaway worktree, run
   `mv packages/streamdeck /tmp/x && env -C src mise exec -- mix compile --force`.
   Expect success. Restore the directory, and record the result in the PR body.

## Non-happy paths

- **Someone edits only the sidecar mirror:** the mirror test fails in the
  `streamdeck` job.
- **Someone edits only the canonical file:** the same test fails, and the
  Elixir compile-time exhaustiveness check still guards states and badges.
- **The sidecar is extracted to its own repository later:** it vendors the
  canonical file from a tagged aiur release. The mirror test is then replaced
  by a version check. That is out of scope here.
- **The packaged sidecar:** `dist/` still contains the JSON, because `tsc`
  emits imported JSON from `src/`. `npm run test:package`
  (`scripts/test/build-package.test.mjs`) covers the archive.

## Compatibility and rollout

- No runtime change. The values are byte-identical.
- The release now carries `priv/streamdeck/*.json`, about 2 KB. No config
  change.
- Rollback means reverting the PR.

## Verification

```bash
env -C <worktree>/src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- mix test \
  test/aiur_web/streamdeck_key_face_contract_test.exs test/aiur_web/streamdeck_package_independence_test.exs \
  test/aiur_web/streamdeck_logs_test.exs test/aiur_web/stream_deck_grid_test.exs test/aiur_web/streamdeck_strip_test.exs \
  test/aiur_web/live/streamdeck_live_test.exs
env -C <worktree>/packages/streamdeck npm test
env -C <worktree>/packages/streamdeck npm run build
env -C <worktree>/packages/streamdeck npm run test:package
```

Mutation checks:

- Change one colour in the mirror only. `protocol-mirror.test.ts` fails.
- Point `@contract_path` back at `packages/streamdeck/...`. The independence
  test fails.

Both agreement tests (`key-face-contract.test.ts`,
`streamdeck_key_face_contract_test.exs`) pass **unmodified apart from the
path**.

Hardware or emulator re-proof follows the DESIGN-R6 §2.1 answer:

- either open `/streamdeck` and confirm the key faces match;
- or, on the owner's deck, confirm the grid colours and log badges.

State which one was run.

## Completion and handoff

- [ ] The canonical files are in `src/priv/streamdeck/`, and the mirrors are
  byte-identical.
- [ ] Core compiles with the package directory absent (manual proof recorded).
- [ ] The independence and mirror tests are green; both mutations go red.
- [ ] Docs: add one sentence to `docs/streamdeck-channel.md` (protocol doc)
  saying where the canonical visual contract lives and that the sidecar
  mirrors it. That is done in MP-R6-C3-T01 if the two land together.
- **Dependents:** MP-R6-C3-T01 (docs); MP-R1-C1 (checker absorbs the
  independence test).
