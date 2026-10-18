# MP-R6 acceptance evidence — 2026-10-18

Issue: [#3462](https://github.com/aiur-team/aiur/issues/3462).
Automated acceptance baseline: `main` at
`dc85ed0de4ddcf5b0de6f7873c91f4b5d54a1492`.

Automated checks passed as recorded below. Live daemon restart, rendered
CLI/TUI/dashboard proof and physical dictation remain post-deploy checks.
This report does not claim that those hands-on checks ran in an issue workspace.
No production code or tests are changed by this acceptance report.

## Contract and merged members

The research plan is absent from current main. The acceptance contract was
recovered from commit `6732f5f9f448b1857a9643993849635f85321e19`, path
`docs/research/aiur-mobile-and-platform/bucket-1-refactor/MP-R6/plan.md`, §7.
Current source paths were resolved independently rather than copied from the
research line numbers.

All three member PRs are merged and their merge commits are ancestors of the
baseline:

| Member | PR | Merge commit | Merged (UTC) |
| --- | --- | --- | --- |
| MP-R6-C1-T01 | [#3525](https://github.com/aiur-team/aiur/pull/3525) | `8222adb5f416e2804f4e709534165ab1d69acaa8` | 2026-10-08 20:13:17 |
| MP-R6-C2-T01 | [#4216](https://github.com/aiur-team/aiur/pull/4216) | `6d5a552c066b349ee959f8d4d99c75c1ced699f2` | 2026-10-16 17:59:17 |
| MP-R6-C3-T01 | [#5023](https://github.com/aiur-team/aiur/pull/5023) | `560228383a4fcd466651c068e7fa570100fc595d` | 2026-10-18 06:59:50 |

## Automated acceptance

Commands run from the repository root unless noted. ExUnit commands run from
`src/`, with four concurrent cases. Existing tests were used; no new tests
require an author-side production-revert check.

### Anchoring and deck behavior

```sh
mise exec -- mix test --max-cases 4 \
  test/aiur/conversation/anchors_test.exs \
  test/aiur_web/streamdeck*test.exs \
  test/aiur_web/stream_deck_grid_test.exs \
  test/aiur_web/live/streamdeck*test.exs \
  test/aiur/regression/compile_time_paths_test.exs
```

Result: **259 tests and one property, zero failures, one excluded**.
The excluded test is the live ElevenLabs voice-latency measurement, tagged
`:external`; neither `ELEVENLABS_API_KEY` nor `AIUR_VOICE_FIXTURE` was supplied.
Mocked channel voice/targeting tests passed; this is not a live dictation proof.

The C1 merge leaves `streamdeck_logs_test.exs` unmodified: its diff against
C1's parent is empty. The passing current oracle covers the evolved main
implementation, including log rows, paging, LIVE, emulator, commands and focus.

The neutral module's eight existing tests also ran in isolation with:

```sh
mise exec -- elixir -r src/lib/aiur/conversation/anchors.ex \
  -e 'ExUnit.start(max_cases: 4); Code.require_file("src/test/aiur/conversation/anchors_test.exs")'
```

Mutation runs used a detached worktree at the baseline. Before each run,
`git -C "$qa_worktree" status --porcelain` was asserted to equal exactly
` M src/lib/aiur/conversation/anchors.ex`; the production mutation was the
only change. The module was restored after each mutation.

- Mutation A: replace `DateTime.compare(at, edge) != :lt` with `== :gt`.
  Result: exit 2, eight tests, two failures, including the exact-boundary test.
- Mutation B: return `{:bus, id}` instead of `{:bus, kind, id}`.
  Result: exit 2, eight tests, one failure: emitted/consumed twins.
- Restored source: eight tests, zero failures; worktree clean.

### Visual contract and sidecar independence

```sh
scripts/build-gate npm test --prefix packages/streamdeck
scripts/build-gate npm run build --prefix packages/streamdeck
cmp src/priv/streamdeck/key-face-contract.json packages/streamdeck/src/key-face-contract.json
cmp src/priv/streamdeck/key-face-parity-vectors.json packages/streamdeck/src/key-face-parity-vectors.json
```

Results: **80 test files, 1,123 tests passed**; test typecheck and sidecar build
passed. Both mirrors are byte-identical, and both language agreement suites
passed. The built `dist/key-face-contract.json` is JSON-equal to the canonical
copy (TypeScript reformats its whitespace, so built bytes are not identical).

`rg -n 'StreamdeckKeyFaceContract' src/lib/aiur/` returns no matches.
The package-independence source scan passed. The only current `src/lib`
mentions of `packages/streamdeck` are the two documented prose exceptions
in the emulator and its components; neither reads a compile input.

The isolated compile initially failed because a dashboard icon module reads
`deps/heroicons` relative to the worktree. Setting `MIX_DEPS_PATH` alone did
not supply that path. A worktree-local `src/deps` symlink to the existing
dependencies corrects the harness; `packages/streamdeck` remains absent.
A second attempt failed on `phoenix_html` assets because dependency `priv`
links inside the relocated cache are relative. The private cache was moved
into the worktree's normal `src/_build` layout, preserving those links.
The final retry uses `mise exec -- mix compile --force --warnings-as-errors`
from that worktree's `src/`, recompiling all core sources rather than
accepting a warm no-op compile. Neither harness failure involved a sidecar
file read.

Final result: **pass**, `Generated aiur app`, with **2,034 source files**
compiled while the sidecar directory was absent. The worktree was then
restored, verified clean and removed. No live daemon was rebuilt or restarted.


Direct producer and dashboard CSS checks also passed:

```sh
mise exec -- mix test --max-cases 4 test/aiur/agent_event_feed_test.exs test/aiur_web/dashboard_css_theme_test.exs
```

Result: **43 tests, zero failures**.

### Protocol and documentation

Member diffs preserve channel event names and payload shapes; focus and
voice handlers are untouched. C2 leaves the existing sidecar JSON bytes unchanged; C3 changes
only documentation. No wire-compatibility claim is made about unrelated main
changes since those merges.

The classification table in `docs/streamdeck-channel.md` identifies shared
anchors, deck DTOs, presentation and transport. Its canonical paths resolve.
`website/docs-app/guide/stream-deck.md` explicitly says the dashboard and
emulator require no sidecar. Anchors currently serve `StreamdeckLogs`;
`History` re-exports them and non-deck conversation use remains planned.

## Post-deploy checks

These checks require the Executor's repository root or physical equipment.
They were not run here. The PR repeats every step under `## Local tests`.

1. From the Executor repo root, update to main, run `scripts/aiurdev restart`,
   and confirm the loaded build's repo/commit stamp matches that main SHA.
2. Follow `docs/manual-testing.md` from the Executor repo root to launch
   `scripts/aiurdev --test --force --allow-remote`; use the printed tmux
   socket/session, select a running agent, press Enter, send a unique message
   through chat input, and capture rendered agent prose, command/tool rows
   and message delivery in the real chat pane.
3. Open the launched dashboard and `/streamdeck` without a connected sidecar;
   focus an agent, select a log event and confirm its transcript jump, LIVE
   updates and command targeting. Capture screenshots and compare focused
   identifiers with the TUI. Confirm the dashboard has no sidecar requirement.
4. On the owner's physical Stream Deck with microphone and configured voice
   provider, focus an agent, hold Mic, speak, release and Send; confirm the
   intended agent receives the text. Repeat holds to confirm accumulation,
   then answer a focused Command by voice and confirm operator/streamdeck
   attribution. Switch focus and confirm delivery follows it; the Executor
   must never be a target. Capture deck/dashboard evidence.
5. With an operator-provided 16 kHz mono s16le speech fixture containing
   “country” and `ELEVENLABS_API_KEY`, run from `src/`:
   `AIUR_VOICE_FIXTURE=/path/to/speech.raw mise exec -- mix test --max-cases 4 --only external test/aiur_web/streamdeck_voice_latency_test.exs`.
   Record nonempty partial/final transcription and measured partial lag and
   release-to-final milliseconds; do not substitute mocked timings.

## Base integration

The pre-PR gate integrated `main` at
`ec46c7c73b788fe5bae034eea5f7c3e53a041292` after the acceptance run.
Its change is the build-home live agent band and CI wiring. A scoped
`git diff --exit-code` against the acceptance baseline confirmed no changes
to the MP-R6 anchor/event-feed modules, deck modules and emulator, canonical
JSON, sidecar, classification docs or deck/anchor acceptance tests.
The acceptance counts above refer to the stated baseline; local pre-PR gates
validate the integrated head separately and are recorded in the PR body.

## Findings and disposition

No P0/P1 acceptance blocker or P2/P3 feature finding was observed in the
completed automated checks. No deferred-ledger entry is warranted.
Hands-on acceptance remains unproven until the listed post-deploy checks
produce dated captures; automated success is not evidence of rendered UX
or physical audio behavior.
