# Status: partial, not synthesized

The code review stopped early on 2026-09-26: first the account session limit was hit, then Claude credits ran out.

- `raw/` holds 24 of 32 review units, one JSON file per unit. Each file lists its findings with severity, locations, evidence and recommendation.
- Units still incomplete: tests-1a, tests-1b, tests-4, skills-prompts, and the four cross-cutting duplication sweeps (by name, by body, by concept, by constant).
- Not verified: no P0/P1 finding has had its skeptic check yet. Treat every severity as the reviewer's own claim.
- Not written yet: `code-review.md`, `findings.json`, `by-boundary.md`.

## Website continuation checkpoint

`in-progress/nonelixir-web.json` records full reads of the 16 website files in
the 178-file unit. The other 162 paths remain unreviewed in this continuation.
Three P2 findings have isolated source probes: a false-passing reduced-motion
check, a readiness deadline that cannot cancel its in-flight request, and copy
feedback that does not wait for clipboard success. These are additional
provisional findings, outside the 853 inherited findings in `raw/`.

Reproduce with Node 24:

```sh
node tooling/website_review_probe.mjs /path/to/frozen-snapshot
```

The probe transpiles source into a disposable temporary directory, checks the
baseline and a broken freeze-offset mutation, and uses controlled browser API
doubles for the other two cases. It does not launch a browser or Aiur. It is
research evidence, not manual UX verification. Output is retained in
`in-progress/website-review-probe.json`; each input carries a SHA-256 hash.
No production implementation changed. This partial unit is deliberately not
counted among the 23 raw unit artifacts.

## Stream Deck lifecycle continuation

The same partial unit now records 45 complete file reads: the 16 website paths
plus 29 Stream Deck source, test and configuration paths. There are 133 paths
remaining. Two additional P2 findings concern duplicate monitor restart chains
and removal events from a different product of the same vendor. Five provisional
findings now sit outside the inherited `raw/` totals.

```sh
node tooling/streamdeck_lifecycle_probe.mjs /path/to/frozen-snapshot
```

On Linux with Node 24, the probe confirms that a genuinely absent executable
produces both error and close notifications, then drives the frozen runtime with
injected timers and device/monitor doubles. One failure schedules two replacements;
cleanup loses ownership of one child or timer. A same-vendor, different-product
removal also closes a healthy backend and leaves no reopen timer. Results are in
`in-progress/streamdeck-lifecycle-probe.json`. These are conditional source-level
reproductions, not hardware testing or estimates of incident frequency.

The pure device reducer already separates idle reads, disconnects, suspend and
bounded recovery. Preserve that seam in planning. The demonstrated gaps concern
monitor termination ownership and device identity at the event adapter boundary.

## Channel and command continuation

The partial unit now has 54/178 complete reads, 124 remaining paths, and eight
provisional P2 findings. The nine added reads cover the channel, controller,
command model, voice session, selected complete tests and HID report helpers.
The much larger controller test file remains only partially reviewed; the JSON
coverage notes identify the ranges read.

```sh
node tooling/streamdeck_channel_probe.mjs /path/to/frozen-snapshot
```

The probe demonstrates text loss on an offline Send press, `QUEUED` state on an
offline Implement press, ignored server errors for `say`/`control`, and no cursor
request when history navigation reaches the first eight-item server page. An
answer-command error is the positive control: it does reach its error callback.
Input travels through the actual controller's HID decoder. The channel uses a
synthetic socket; the surface contributes only its unchanged `agentLess`
predicate, so these checks do not claim pixel, hardware or live-service coverage.

Preserve the existing server ownership of delivery, queueing and durable Command
answers. The missing client contracts are acceptance receipts, retained pending
intent and cursor-driven history navigation. A new package boundary alone would
not repair them.

## Audio completion continuation

The partial web/Stream Deck unit now records 71/178 complete reads, with 107
paths remaining and ten provisional P2 findings. Seventeen added full reads
cover audio adapters/contracts and the voice-host/relay tests. A composed
source probe demonstrates two boundary defects: release seals transcript
delivery before the server's requested final can arrive; overlapping holds
consume a delayed start reply without retaining its originating hold identity.
Earlier settled text survives the first case. The second needs only ordered,
delayed replies; server-side session guards can discard the mislabelled audio.

Reproduce with `node tooling/streamdeck_audio_probe.mjs /path/to/frozen-snapshot`.
Results and source hashes are in `review/in-progress/streamdeck-audio-probe.json`.
The capture and channel are injected ports; no hardware, provider or daemon was
run. No production files changed. Continue with audio tests, playback/cancellation
candidates, rendering and the remaining controller tests. Raw review coverage
remains 23/32, and claim coverage remains 50/60; this is still a partial unit.

## Audio resource checkpoint

All audio source and test paths in the partial unit have now been read: 21
additional complete reads bring coverage to 92/178, leaving 86 paths. The unit
has thirteen provisional findings (eleven P2 and two P3), still outside raw
review totals. A real bounded child flushes bytes on SIGINT through the actual
Node adapter, but capture/session discard the tail before transcription. This
is separate from finding 09's discarded final transcript after upload.

`node tooling/streamdeck_audio_resource_probe.mjs /path/to/frozen-snapshot`
reproduces that drain failure, playback's unresolved write after sink failure,
and the fetch iterator's missing body cancellation. Results are retained in
`review/in-progress/streamdeck-audio-resource-probe.json`. Playback/TTS symbols
have no production callers in the frozen repository search and are absent from
the audio barrel: their two findings are latent P3 defects, with no claimed
live device or quota impact. The whole directory also includes provider-shaped
TTS code with an outward import, despite its narrower barrel's extraction claim.
Resolve that scope before treating the directory as an independent package.

No hardware, provider, daemon or package suite was run; this was source review
and targeted probe execution. Next review work is rendering, voice-panel host
wiring, controller tests and remaining scripts/configuration. Overall claim
coverage stays 50/60 and completed raw review units stay 23/32.

## Surface state checkpoint

Seventeen additional full reads bring the partial unit to 109/178 files,
leaving 69. Finding 14 reproduces a wrong active-microphone caption when the
selected device is outside the visible settings page: the compositor emits
Mic 7, Mic 0, Mic 7 for page offsets 6, 0, 6 with Mic 7 selected throughout.
The recording rasterizer proves the panel model, not pixels or hardware.
Reproduce with `node tooling/streamdeck_surface_probe.mjs /path/to/frozen-snapshot`;
results are in `review/in-progress/streamdeck-surface-probe.json`.

The reviewed key cache/write queue already protects pending versus committed
content, partial writes and fresh-writer recovery. Preserve those contracts.
Strip cache/signature state is eager, but production recovery invalidates on
backend replacement; no permanent stale-pixel claim is established yet.
Typewriter row identity and role filtering remain candidates requiring caller
analysis. Continue with remaining surface/controller tests, renderers and
scripts. Fourteen partial-unit findings (twelve P2, two P3) are not included in
the inherited raw totals; overall counts remain 23/32 units and 50/60 claims.

## Provider contract checkpoint

All touchStrip source/test paths are now read: eighteen additional paths bring
the partial unit to 127/178, leaving 51. Finding 15 identifies producer-consumer
drift: the server emits semantic session/weekly slots without durations, while
the client reclassifies by duration. A real two-window shape becomes no data; a
weekly-only shape becomes session usage. The client tests use an older shape.

`node tooling/streamdeck_provider_probe.mjs /path/to/frozen-snapshot` checks
the producer's source-level output keys and executes the actual client model
against synthetic values in that shape, with the old shape as a positive
control. The server is source-traced, not executed, and no live prevalence is
claimed. Results are in `review/in-progress/streamdeck-provider-probe.json`.
A shared serialized contract fixture is needed across the proposed boundary.

Provider painter freshness/age handling remains a candidate for the complete
art-renderer pass. The report-encoding benchmark already disclaims hardware
latency coverage; do not promote its fourfold arithmetic into measured savings.
Fifteen partial-unit findings (thirteen P2, two P3) remain outside raw totals.
Overall counts remain 23/32 review units and 50/60 claims. Continue with art,
key rendering, logs/controller tests and scripts; no production changes made.

## Key rendering checkpoint

Twenty-five additional complete reads bring the partial web/Stream Deck unit to
152/178 files, leaving 26. The report writer preserves output versus feature
transport routing and the original failure even when recovery notification
throws. The key-face tests already share a JSON parity table with Elixir: reuse
that approach for provider wire contracts without claiming complete pixel parity.

The rasterizer consumes the footer's unknown-aware percent, not the duplicate
raw progress field. Existing tests distinguish unknown from measured zero.
Fresh and stale progress deliberately paint identically in two tests, despite
a header comment claiming stale alpha; carry this unresolved display requirement
into planning rather than declaring a newly demonstrated regression. The cache
is bounded in source, but its serviceability test does not constrain the bound.

No new finding is promoted: fifteen provisional findings remain outside the
853 inherited raw findings. No canvas suite, device, daemon or manual UX test
was run. All 25 input hashes match the frozen Git blobs. Continue with art,
logs/controller/surface tests and scripts. Overall coverage remains 23/32
completed review units and 50/60 claims; production implementation is unchanged.

## Art and packaging checkpoint

Eighteen complete reads bring the partial unit to 170/178 files. All art
source/tests and listed packaging/preview/USB scripts are now read. The eight
remaining paths are demo, dial and logs source/tests, plus the controller and
surface tests. No new finding is promoted; fifteen provisional findings remain.

The complete painter tests change the freshness candidate's disposition: the
provider test explicitly attributes omitted staleness wording to an operator
directive. Keep the display policy as a planning question, not a newly proven
renderer regression. This does not weaken finding 15's separate session/weekly
wire mismatch. Existing tests also preserve no-data versus measured-zero and
transcript row identity; package extraction must keep those distinctions.

The archive includes the bundled runtime and render assets, and its smoke test
executes main through absent-device startup. Thus main is not wholly untested
in composition. That smoke does not render packaged assets or verify that the
supplied commit metadata matches built dist. Preview scripts independently
construct descriptors, so their images cannot prove live surface/controller
behavior. The painter also imports a runtime classifier from channel.ts, a
dependency to address before extracting a presentation package.

This was source/test review, not execution of canvas, packaging, diagnostics or
manual UX tests. All 18 hashes match frozen Git blobs. Overall completion stays
23/32 review units and 50/60 claims; no production implementation changed.

## Web and Stream Deck unit complete

All 178 manifest files have now been read in full. The authoritative unit is
`review/raw/nonelixir-web.json`; the former partial JSON points there. Sixteen
findings (fourteen P2, two P3) bring raw totals to 24/32 units and 869 findings.
The 181 inherited P0/P1 findings still need skeptic checks; claim coverage is
unchanged at 50/60. This is unit completion, not research completion.

Finding 16 reproduces a reading-position shift: setLogs captures previousStarts
after replacing eventStarts, so its attempted rebase retains the old absolute
index. After an older row disappears, the probe reads next row instead of
reading target without input. Unchanged-refresh is a positive control. Run
`node tooling/streamdeck_log_refresh_probe.mjs /path/to/frozen-snapshot`; output
is in `review/in-progress/streamdeck-log-refresh-probe.json`. Server bounded-tail
and identity-based refresh code was traced, not executed; no live prevalence
is claimed.

The demo's duration-bearing provider fixtures explain why it cannot catch the
real normalized-wire mismatch. Older two-row logs helpers have no repository
callers beyond their tests, but are publicly re-exported: investigate consumers
before removal. Unpromoted identity, lifecycle and packaging observations remain
explicit synthesis questions. No production changes or manual UX claims.

## Duplication census checkpoint

The parse-only census covers all 1,032 frozen `src/lib/**/*.ex` files and
28,722 literal definition clauses. `function-census-summary.json` records every
input hash, per-name counts and 126 exact-body candidate clusters (297 sites),
filtered to physical definition spans and canonical bodies of at least five
lines. This is syntax evidence, not equivalent behavior or removable LOC.
Heads/guards and lexical alias/import context still require review. Quoted
generated definitions and macro expansion are explicitly outside this census.

Twenty-three clusters have initial source-span assessments in
`review/in-progress/duplication-triage.json`; two fall below the final physical
threshold. Startup wrappers are not grounds for a shared process abstraction.
Decision validation, usage persistence, log rotation and control-call helpers
are stronger ownership candidates, pending context and inherited-finding review.
105 final exact-body clusters remain to assess; both duplication units
remain incomplete. Counts stay 24/32 review units and 50/60 claims.

Reproduce with `elixir tooling/function_census.exs /path/to/frozen-snapshot`
then `python3 tooling/function_census_summary.py /path/to/census.json`.
`python3 tooling/test_function_census.py` checks module scope, quoted-code
exclusion, clause/head handling, metadata stability and literal sensitivity on
synthetic files. No project modules are compiled and no production code changes.

The next ten cluster assessments distinguish same-body scope routing from
different telemetry/usage key contracts, adapter callback boilerplate from
backend mutation semantics, and same string parsing from different float
acceptance. Lifecycle digests and renderer-local separator/elapsed formatting
are concrete ownership candidates. No candidate is yet a measured saving or
a promoted deduplicated finding; inherited-finding reconciliation remains open.

Tooling validation used Elixir 1.19.5 / OTP 28.5. Ensure both `elixir` and
`erl` are on PATH: the standalone research directory has no mise version
selection. A rerun without that setup failed before parsing; with both installed
binaries on PATH, all fixture assertions passed. The full production-source
parse was deterministic and all 1,032 hashes matched the frozen Git commit.

## Duplication context checkpoint: 51 of 126 clusters

Thirty more exact-body clusters have source-span assessments, bringing the
triage to 53 total clusters, 51 in the final population and two below its size
threshold. Seventy-five final candidates remain. The name, near-duplicate,
concept and constant sweeps and inherited-finding reconciliation remain open;
review-unit and claim completion counts are unchanged.

Concrete constraints for the package plan:

- Git origin discovery and ordered ticket-branch candidates already have
  plausible existing owners; do not create a generic utility package for them.
- Filesystem preconditions that allow missing files differ from post-write
  checks requiring a visible regular file, even when names match. Preserve
  symlink/type error distinctions; lstat prechecks are not atomic guarantees.
- Decision request validation, persisted codec shape checks and collision-aware
  key normalization are cohesive candidates with distinct contracts. Retain
  field-tagged errors, redaction order and duplicate-key rejection.
- Usage coverage decoders have matching success shapes but different error
  tags. Keep checkpoint/block failure attribution at their format boundaries.
- Daemon streams have different filenames; history servers have different
  topics and messages. Matching bodies that reference attributes do not imply
  equivalent destinations or permission to merge processes.
- Financial-data access currently requires both authorized capability and a
  verified context. Any shared gate must preserve both conditions.

All sites recorded in the triage were checked against the census source
hashes. These are source-grounded ownership candidates, not measured savings,
production fixes, or completed raw review units. No production code changed.

## Duplication context checkpoint: 91 of 126 clusters

Forty additional exact-body clusters have been assessed at all listed sites.
The triage now contains 93 clusters, including two outside the final size
threshold; 35 final-population clusters remain. No raw unit is promoted yet.

Additional package constraints grounded in surrounding code:

- Outcomes and run-summary reconciliation bodies match, but only the latter's
  availability predicate requires `run.valid?`. Keep this distinction explicit.
- Web and cost-report unknown-provider labels differ: the web splits underscore
  names into words, while the report capitalizes the full name.
- Ad-hoc source change detection compares members; open-ticket detection omits
  body excerpts when comparing tickets. Preserve their notification policies.
- Poll branch selection is a coherent shared subroutine across CI/comments;
  ordered guesses, explicit overrides and the known-branch flag belong together.
- Positive-number parsing recurs under different variable names. These sites
  are evidence for the pending near-duplicate pass and must not be counted as
  independent extraction opportunities merely because exact hashes differ.
- Projection task startup falls back from a supervisor to `Task.start`; any
  shared helper must expose that policy and preserve caller lifecycle ownership.

Recorded source sites match the frozen census hashes. These assessments make
no production-execution, runtime-prevalence, or cost-saving claims. Name,
near-body, concept and constant sweeps, inherited-finding reconciliation, and
the wider research completion checklist remain open.

## Exact-body assessment checkpoint: 126 of 126 clusters

All 126 exact-body candidate clusters (297 sites) now have source-span
assessments in duplication-triage.json. Two additional reviewed clusters fall
below the final size threshold. This completes the candidate assessment pass,
not the duplication review units: repeated-name, renamed/near-body, concept,
constant and inherited-finding reconciliation work remains.

The final pass records concrete constraints:

- Existing Protocol.MapAccess.message_timestamp and Events.CommentFilter
  workpad detection match local copies; prefer existing ownership where the
  dependency direction fits.
- Presence-preserving atom/string lookup differs from MapAccess.get's truthy
  fallback. Nil/false values must not change meaning during consolidation.
- CLI table cutoffs are 96 versus 120 columns. Log rotation policies are
  4 MiB/eight generations versus 1 MiB/two generations. Same bodies do not mean
  those constants should become one policy.
- Claude reset timestamps admit fractional seconds; Codex accepts integer
  seconds. Preserve provider format contracts even when conversion bodies match.
- Comment-list ingestion deliberately drops an old validator after storing a
  nil-etag list. Shared ingestion must retain that explicit invalidation.
- GraphQL cost handling must preserve reported versus assumed provenance and
  the caller's failure/304 contract.

All recorded sites were rechecked against frozen census hashes, and final
candidate IDs/sites exactly match the census population. No raw review unit
is promoted; completion totals remain 24/32 units and 50/60 claims. No
production files changed and no savings are claimed.
