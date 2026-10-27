# MP-R6 partial acceptance evidence — 2026-10-18

Refs [#3462](https://github.com/aiur-team/aiur/issues/3462); keep the issue open.
The acceptance capstone is incomplete. This report records partial evidence,
not completion of the feature acceptance contract.
Automated acceptance baseline: `main` at
`dc85ed0de4ddcf5b0de6f7873c91f4b5d54a1492`.

Automated checks passed as recorded below. The Executor later supplied
read-only live dashboard observations, attributed below. Loaded-build proof,
TUI interaction, disconnected-sidecar behavior and physical dictation remain
unproven. No hands-on checks are claimed to have run in an issue workspace.

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
accepting a warm no-op compile.

Neither harness failure involved a sidecar file read.

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
emulator require no sidecar.

Anchors currently serve `StreamdeckLogs`;
`History` re-exports them and non-deck conversation use remains planned.

## Attributed Executor live observations

The [Executor's live acceptance comment](https://github.com/aiur-team/aiur/pull/5173#issuecomment-6256387359)
records a read-only run on 2026-10-18, 23:00–23:16 UTC. These are the
Executor's observations, not checks performed in this workspace. Capture
names in that comment are labels. The later [issue #5181](https://github.com/aiur-team/aiur/issues/5181)
records screenshot paths on the Executor host; those files were not inspected
or copied by this workspace.

### Release directory and startup correlation

The runtime release stamp records source SHA
`d5b129fc6eb446fc5daa434a1cd2d80f70c2bb37`, built at
`2026-10-18T22:58:37Z`, with `dirty=yes`. Runtime checkout HEAD matched;
only `.aiur/config` and `.aiur/model-usage.json` were modified tracked files
(operator state, not source changes).

BEAM pid 1920122 started at 22:59:18Z, 41 seconds after the stamp, using that
release directory. Runtime `aiurdev status` answered with a 22:59:56Z handoff,
seven agents adopted, a listener present and main green. The Executor did
not RPC-read the stamp inside the node; startup correlation is not that proof.

### Browser emulator: read-only targeting and selection

Headless Chromium opened the live dashboard's `/streamdeck`. The browser
path is a LiveView requiring no sidecar, but a physical sidecar was connected
to the same daemon. This run does not prove operation with the sidecar
disconnected.

Capture label `01-grid` showed eight agent keys, page 0 of 62,
`data-grid-total=495`, and “8 live · 487 left”. Focus on #3153 and #5103
showed five command-mode keys with matching identifiers and matching
“CONTROLLING” strips. Focus followed the pressed key.

Commands for #3323 and #3153 showed different Command sets matching focus.
Opening a closed #3323 Command showed its detail without option keys and a
disabled Mic key marked “SIDECAR”. No Command was answered; this proves
read-only targeting and selection only.

Logs for #5103 and #3153 showed only “INFO Ticket opened” plus LIVE.
Selecting event 0 moved `aria-current` from LIVE to that event and showed
“[INFO] Ticket opened” at offset 0/0. There was no meaningful transcript
jump. Their workspace logs had 18,144 and 11,823 lines respectively.

The Executor did not determine whether that shallow projection was expected
for adopted agents after restart or was a projection gap. Re-selecting LIVE
on stuck #5103 and observing for 45 seconds produced no new event; the agent
was not producing events. LIVE updating was not exercised.

The Executor avoided pressing running or paused agent keys because those
keys can pause or resume work. No focused-identifier comparison with the TUI
ran. The comment also reports a roughly 40 px key-block shift in logs and
commands modes and only a Mic key in command-detail row 2, without assigning
severity.

### Follow-up tracking and capture locations

[Issue #5181](https://github.com/aiur-team/aiur/issues/5181) now tracks the
single-event Logs view and the roughly 40 px key-grid offset between modes.
The Logs gap remains open; a meaningful transcript jump and LIVE updates
still need proof after investigation. The layout observation is deferred as
DF-014 in `docs/build-order/deferred-findings.md`.

The issue identifies these captures on the Executor host:

- `~/.aiur/tmp/acc5173.bVwF/03-3153-logs.png`
- `~/.aiur/tmp/acc5173.bVwF/12-5103-logs.png`
- `~/.aiur/tmp/acc5173.bVwF/22-3323-commands.png`
- `~/.aiur/tmp/acc5173.bVwF/23-3323-command-detail.png`
- `~/.aiur/tmp/acc5173.bVwF/01-grid.png`

These are attributed source locations, not artifacts published by this PR.

### Sidecar connection and remaining voice evidence

The Executor observed the physical sidecar reconnect after daemon restart
and send `channel.grid` by 23:00:22Z. At 23:15:05Z its journal reported 496
agents and provider usage. This is attributed connection/grid evidence,
not proof of physical focus, dictation or rendered hardware behavior.

The operator dotenv contained an ElevenLabs key (its value was not read),
but no required speech fixture existed on the host. No physical voice run,
external voice-latency test, partial/final transcript or latency measurement
was produced. The workspace's mocked tests do not fill that gap.

## Remaining post-deploy checks

These checks require the Executor's repository root or physical equipment
and were not run here. Complete steps 1–3 and either voice step 4 or 5.
The PR repeats every exact step under `## Local tests` as a
`Post-deploy check:`; the partial observations above do not complete them.

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
Its change is the build-home live agent band and CI wiring.

A scoped
`git diff --exit-code` against the acceptance baseline confirmed no changes
to the MP-R6 anchor/event-feed modules, deck modules and emulator, canonical
JSON, sidecar, classification docs or deck/anchor acceptance tests.

The acceptance counts above refer to the stated baseline; local pre-PR gates
validate the integrated head separately and are recorded in the PR body.

## Findings and disposition

The automated checks found no P0/P1 acceptance blocker. The later live Logs
finding is tracked in #5181 and remains open. Its layout observation is
deferred in DF-014. LIVE updates, a meaningful transcript jump, TUI and
voice are still unproven; this report does not count them as passing.

Keep #3462 open until the remaining checks produce dated evidence. This
report and its PR must reference the issue with `Refs #3462`, without a
closing keyword. Automated success and partial dashboard observations do
not prove complete rendered UX, physical audio behavior or latency.
