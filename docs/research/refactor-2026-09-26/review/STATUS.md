# Status: partial, not synthesized

The inherited code review stopped early on 2026-09-26: first the account session limit was hit, then Claude credits ran out.

- `raw/` holds 28 of 32 review units, one JSON file per unit. Each file lists its findings with severity, locations, evidence and recommendation.
- Units still incomplete: skills-prompts, and three cross-cutting duplication sweeps (by name, by concept, by constant).
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

## Renamed-body census checkpoint

The optional `--renamed` mode of function_census.exs canonicalizes variable
spellings by first appearance. The default census output remains identical to
the previous full parse. Renamed output was reproduced twice and all 1,032
input hashes matched the frozen census. Fixtures check renaming, repeated
variable use, literal changes, distinct module attributes and explicit calls.
No project source was compiled or executed.

`renamed-census-summary.json` lists 41 cross-module candidate clusters (138
sites) containing different exact-body hashes under the existing size limits.
These overlap the exact-body population and must not be added to its count.
The heuristic preserves attributes, literals and explicit call names but does
not model lexical binding; bare identifiers can also denote zero-argument
calls. It is a candidate finder, not semantic equivalence or an exhaustive
near-duplicate detector.

Three groups have initial source assessments: a fifth AIUR_DEBUG reader in
Opencode slot attachment, a third financial-access gate in AnalyticsLive, and
a third presence-preserving map accessor in BuildOrder progress rendering.
Thirty-eight groups remain. Findings stay grouped with the existing policy
candidates; no raw duplication unit is promoted.

Reproduce with `elixir tooling/function_census.exs /path/to/frozen-snapshot
--renamed` (arguments on one line), then
`python3 tooling/renamed_census_summary.py /path/to/renamed-census.json`.
Use Elixir 1.19.5 / OTP 28.5 on PATH. The existing research fixture command
also exercises the new mode. No production files changed.

## Renamed-body assessment checkpoint: 41 of 41 groups

All 41 renamed-variable candidate groups (138 overlapping sites) now have
source-span assessments; 38 groups were added in this pass. Candidate IDs and
site lists exactly match the census, and source hashes were rechecked. This
completes this heuristic's assessment pass, not the wider duplication units.

New planning evidence includes an existing AgentList.RenderState.safe_call
owner; shared dashboard/Streamdeck chat transport adapters; dependency-edge
cache merging that preserves absent versus complete lists; and repeated keyed
queue/task-start mechanics. These are ownership candidates, not automatically
independent packages or measured savings.

The token input family currently accepts numeric prefixes, unlike strict
identifier parsing. Task/monitor helpers retain caller-owned lifecycle duties;
same-shaped cleanup and publication callbacks must not be given a common
success meaning. Timestamp and field-reader families occur across multiple
hash groups because heads, unused variables and error clauses vary: reconcile
those families rather than adding candidate counts into a deletion estimate.

Remaining duplication work: repeated-name families, concept and constant
sweeps, inherited-finding reconciliation, and final raw-unit findings. Broader
research totals remain 24/32 review units and 50/60 verified claims. No
production code changed.

## Duplication reconciliation checkpoint

`tooling/duplication_overlap.py` indexes closed source-line intersections
between the 869 inherited raw findings and all 167 exact/renamed candidate
groups. 131 groups overlap at least one listed finding location; 36 do not.
These populations overlap each other and are not counts of distinct defects.
Seven nonstandard location expressions remain explicit for manual review.
Broad ranges can create unrelated overlaps; omitted locations can hide real
matches. The index does not prove duplication or verify any inherited claim.

Six findings have initial semantic reconciliation notes in
`duplication-reconciliation.json`: build-order-20, web-rest-10, web-occ-17,
agent-runtime-32, github-a-09 and build-order-05. Original IDs are preserved.
The notes distinguish corroborated helper subsets from unverified broader
claims and narrow generic-helper recommendations where a local owner already
exists. The P1 metrics overflow claim still needs its independent skeptic
check; repeated helper bodies do not establish that failure or its prevalence.

Reproduce the index with `python3 tooling/duplication_overlap.py /path/to/research`.
`python3 tooling/test_duplication_overlap.py` checks endpoint intersections,
disjoint ranges, path isolation, unresolved expressions and duplicate IDs.
The full index reproduced identically. No raw finding is removed or promoted;
remaining name/concept/constant sweeps and final semantic deduplication are open.

## Repeated-name checkpoint: six complete name families

The name sweep now records all 77 literal clauses for parse_time,
parse_datetime, to_iso8601, format, timestamp and safe_call in
`duplication-name-triage.json`. Heads and fallback clauses were read, including
small definitions excluded by the body-size threshold. Source hashes match
the frozen census; this is partial name coverage, not a completed unit.

Decision cursor ISO parsing requires zero UTC offset, unlike general timestamp
parsers. Model availability accepts DateTime and Unix seconds while model
discovery does not. The timestamp name covers parsing, serialization, clock
sampling, fallback time and HTML rendering; format also names unrelated output
and option-validation operations. Eleven safe_call definitions have different
success envelopes, exception/throw handling and fallback meanings. Preserve
those contracts instead of extracting by spelling alone.

Two reset-time ISO formatter pairs match below the five-line body threshold.
Local shared helpers may be appropriate; this does not unify provider reset
input policies. Remaining names, concepts, constants and final reconciliation
are still open. Research completion totals remain unchanged.

## Normalize-family checkpoint

All 81 literal normalize definitions/declarations across 35 modules were read,
bringing name-family coverage to seven families and 158 entries. Bodyless
default-argument declarations are counted explicitly; this is not a count of
independent functions or expanded arities. Source hashes matched the census.

ToolCallIdentity fingerprint canonicalization is not JSONSafe serialization:
scalar atom handling and structural conversion differ, and the former feeds
an identity digest. UnitsRow.URL and BuildOrder.Bounded also have different
policies: HTTP acceptance, empty queries, fragment stripping/rejection and
bounded validation need an explicit decision before sharing an adapter.

Command validators, provider telemetry adapters, conversation trust filters,
opaque identifiers, cache observability and UI fallbacks remain separate domain
contracts. Shared low-level checks may be candidates; the normalize name alone
does not justify combining responsibilities. Remaining name, concept, constant
and final reconciliation work stays open. No production code changed.

## Body-duplication unit completed

The raw body unit now consolidates the assessed exact/renamed clusters into
60 bounded P2 refactor findings with complete candidate-site locations and
hash references. All 169 reviewed groups (126 exact candidates, 41 renamed
candidates and two below-threshold startup groups) have an explicit disposition.
Candidates not promoted retain their rationale; identical callback syntax,
domain-local attributes and lossy failure adapters do not prove interchangeable
behavior. The 242 files counted were inspected at candidate spans, not all read
in full. The scanner parsed all 1,032 source files; their hashes were rechecked.

These findings overlap inherited units and each other at shared primitive
boundaries. Sixty is not an independent defect, package or savings count.
Cross-unit reconciliation, P0/P1 skepticism and final synthesis remain open.
The top-level raw-unit count is now 25/32; historical checkpoints above retain
their original counts. The other three duplication units remain incomplete.


## GitHub guard review in progress

The tests-1b ledger now records 74 complete files plus lines 1-2700 of the
5,764-line AgentGitHubGuard test file. Keep the unit incomplete until the
remaining tests and helpers are reviewed. Read contracts distinguish mocked
GitHub responses, actual broker admissions and native local replay formatting;
no live transport, billing, savings or suite-pass claim is added. Overall raw
review completion remains 25/32.


## tests-1b unit completed

All 75 manifest files were read in full (35,287 lines); frozen hashes and exact
manifest membership were rechecked. The raw unit contains eight bounded
findings: seven P2 and one P3. Earlier probes constrain assertion or fixture
behavior as individually documented; no full-suite or manual UX pass is claimed.

The final guard review retains separate contracts for write authority, broker
compatibility/recovery, credential identity, Git workspace ownership, cache
freshness and conditional replay. Marker-plus-settle migration synchronization
and different-resource overlap remain limited evidence, not production defects.
Cross-unit deduplication and unresolved hypotheses remain for synthesis.

Raw review units: **26/32**. Remaining: tests-1a, tests-4, skills-prompts,
dup-by-name, dup-by-concept and dup-by-constant. Unit presence does not establish
uniform review depth or overall research completion.


## tests-1a started

31 of 75 files read in full (2670 lines), with hashes in the in-progress
ledger. Privacy, identity, recovery and meter contracts are recorded; shared
supervisor observations link to existing findings. No new finding is promoted
from the two test-isolation hypotheses. Raw review coverage remains 26/32.


tests-1a advances to 37/75 files (4,374 lines). One P1 finding is recorded
in its partial ledger: reset-test cleanup deletes a common workspace parent.
An isolated exact-expression probe deletes a sibling sentinel; a fixture-only
control preserves it. No production data loss or full-suite execution is claimed.


tests-1a now covers 44/75 files (5,924 lines). The partial ledger has one
P1 cleanup finding and one P2 transcript assertion finding. The latter is
verified with extracted assertions and a source check that the fixture field
is dropped before serialization; production boolean encoding is not alleged
broken. Overall raw-unit coverage remains 26/32.


## tests-1a unit completed

All 75 manifest files were read in full (35,290 lines); exact membership, hashes and line counts match the frozen snapshot. Four bounded findings: one P1 shared cleanup scope, two P2 assertion gaps and one P3 worker-fixture cleanup defect. Earlier isolated probes support their stated scope, not a full-suite or production-behavior verdict. Remaining hypotheses are explicitly unverified.

Preserve distinct review/terminal teardown, confirmed pause generations, CI and dependency readiness, retained feedback, private decision recovery and unknown meter facts. Topic publication, fake-provider execution and direct handler calls do not prove real provider or rendered UI behavior. Raw units: **27/32**; remaining tests-4, skills-prompts and three duplication sweeps. Cross-unit deduplication, high-priority skepticism and final synthesis remain open.

## tests-4 initial provider review

Read 10 of 100 manifest files in full (1,210 of 40,603 lines), with exact frozen-file hashes recorded in review/in-progress/tests-4.json. Preserve generation invalidation, same-generation stale data, unknown quota facts, refusal provenance, source-session rotation and backfill/live ingress separation. No finding promoted yet; the display-tailer test claiming order currently checks membership only and remains a bounded follow-up candidate. Source review does not establish live-provider or rendered-UI behavior. Raw completion remains 27/32; this unit is partial. Next: coding_agent_test.exs and remote_control_test.exs, then the remaining manifest.

### tests-4 provider transport and REPL contracts

Coverage now 19/100 full files, 3,823/40,603 lines. Reviewed scripted app-server refusal/model/tool behavior, real OS containment tests and mocked REPL launch/submission/hook/attach paths. Preserve provider provenance versus assistant text, pause precedence, private meter ingestion, unknown source identity, and distinct hook versus transcript prompt-delivery semantics. Real pidfd/tree fixtures are stronger than mocked teardown, but neither proves launcher/TUI end-to-end operation. Recorded a second unverified fixture-cleanup candidate; no new severity finding promoted. No tests executed or production changes. Next: REPL reaper and transcript turn, then remaining provider manifest.

### tests-4 transcript evidence and order oracle

Reviewed six more full files: 25/100 files, 6,529/40,603 lines. Preserve transcript backfill/live separation, provider acknowledgement, unconfirmed pause errors, session identity and unknown reset dates. Wrapper control-byte assertions supplement narrower unit fixtures. Extracted all ten assertions from the display-forwarding order test: ordered and reversed conversations both pass; exact-order control rejects reverse. Recorded one P2 local assertion gap (tests-4-cont-01), explicitly not a production reordering claim; lower extraction layer does assert block order. Probe ran in isolated Elixir without Aiur, tmux or provider. Remaining fixture-cleanup hypothesis stays unverified. Raw units remain27/32; next Claude telemetry/API then Codex.

### tests-4 accounting and Codex boundaries

Coverage now33/100 full files,9,763/40,603 lines. Finished Claude telemetry/usage API and first five Codex test files. Preserve exact additive accounting with unknown optionals, authenticated producer replacement/replay boundaries, cached-reading failure distinctions, account-generation continuity and tool-call replay identity. Codex repeated same-mode account updates rotate; Claude observations retain continuity, so shared package extraction must not silently equate these contracts. Most telemetry submit checks are direct Plug calls; one real loopback partial-body timeout is distinguished explicitly. Large combined Codex output was truncated and both large files reread completely in bounded ranges before counting. No new probe/suite execution or production edits. One additional default-policy assertion candidate remains unverified; next Codex dynamic tools.

### tests-4 dynamic tools and protocol boundaries

Read20 more full files; coverage53/100 files,12,276/40,603 lines. Dynamic-tool tests preserve callback arguments, literal-ticket subscription authority and desired-state requests, but injected success is not remote authorization or publication evidence. Wrapper progress-cap tests assert callback counts and nonpublication of rejected third event, supplementing narrower return-only unit checks. Handshake scripted-port tests constrain late sensitive-response quarantine; direct interrupt tests preserve anonymous-completion guards. Low-level RPC closed-port raises while higher adapters return errors: shared transport extraction must preserve or deliberately migrate this boundary. No new finding promoted, probe run, suite executed or production edit. Next remaining Codex policy/usage/turn-loop tests, then executor and UI/launcher units.

### tests-4 quota, reset and turn control contracts

Read eight more full files; coverage 61/100 files, 14,787/40,603 lines. Preserve provider-specific reset parsing, numeric exhausted-window precedence, unknown deadlines, repeated-refusal backoff and operator/global/label pause precedence. Scripted app-server tests exercise transport and stale completion; scheduler reconciliation is invoked directly and does not prove live recovery. Snapshot omission test checks adapter output only, and one event-order title exceeds its presence assertion; neither is promoted to a production defect. Full-file notes record these limits for cross-unit assessment. No new finding promoted, test/probe executed or production edit. Exact frozen hashes and line counts revalidated. Codex manifest complete; next executor, usage, web and launcher files. Raw unit count remains 27/32.

### tests-4 executor ownership and durable advisory evidence

Read ten more full files; coverage 71/100 files, 16,599/40,603 lines. Preserve owner versus observer authority, lease renewal versus acknowledged consumption, eviction cursor versus work evidence, non-overwriting handoff import, durable advisory age and non-authoritative membership retention. Component restarts are not full-daemon restarts; injected alert callbacks are not routed operator delivery. Weighted progress and ETA tests constrain arithmetic and unknown-source gating, not forecasting accuracy. Monitor synchronization concern remains a bounded hypothesis; source inspection shows clock captured before snapshot processing, limiting the claimed race. No new finding promoted or test/probe executed. All recorded frozen-file hashes and line counts verified, public notes screened, production unchanged. Raw units remain 27/32; next usage and compaction, then web/launcher.

### tests-4 usage semantics and compaction validation

Read eleven full files; coverage 82/100 files, 17,992/40,603 lines. Preserve typed scope intersection, unknown accounting evidence, absolute/delta identities, exact Decimal costs, historic relationship revisions and compaction floor recovery. Real private ledger reconstruction is distinguished from stubbed filesystem sync and authored crash states. Confirmed second P2: gap/path-escape manifest fixtures lack checksum and cannot reach block validation. Isolated AST probe bypasses only decode_blocks; both original fixtures still reject, while signed controls detect bypass. Probe exit0; only unused/unavailable dependency compile warnings from uncalled persistence functions. No full suite or production edits. Hashes and line counts revalidated; raw units remain27/32. Next grouped scope integration and pricing, then web/launcher.

### tests-4 historical pricing and grouped scope contracts

Read six full files; coverage 88/100 files, 19,905/40,603 lines. Exact pricing examples supplement conservation properties. Preserve historic relationship/rate joins, additive/subset token semantics, separate provider/API estimates, unknown versus zero, and generation-qualified attribution. Individual occurrence-time pricing and aggregate conservative peak fallback are different supported contracts; shared extraction must retain that distinction and disclosure. Synthetic schedule tests make timezone offset observable. Catalog metadata assertions do not verify current external prices; no current-price or savings claim is made. Grouped cache-key title exceeds its inspected fields; duplicate-source replay is not daemon restart. No new finding promoted, tests run or production edits. Frozen hashes/line counts and public notes checked. Raw units remain27/32; twelve files remain, including larger web/launcher tests.

### tests-4 web evidence, zero-fetch controls and analytics scope

Read six full files; coverage 94/100 files, 22,478/40,603 lines. Preserve indeterminate retained decisions versus absent, transient versus stale control errors, bounded event-feed order, separate trusted actor, view-triggered zero-fetch policy and explicit live/retained/stale analytics provenance. Counting transport positive controls strengthen zero-fetch assertions but do not measure production savings. Rendered source ages and unknown caps have explicit fixtures; some generic page/text checks are narrower than their titles. Initial combined zero-fetch output was truncated; both files reread independently before counting. No test execution, new promoted finding or production change. Frozen hashes/line counts and public notes checked. Raw units remain27/32; six larger files remain, totaling18,125 lines.

### tests-4 Build Order authority and cache inspector truthfulness

Read two larger files completely in bounded ranges; coverage 96/100 files, 26,004/40,603 lines. Build Order ordered-call helpers reject missing calls, and held context loaders constrain stale completion and scope changes. DOM assertions preserve unresolved/empty/partial/unknown progress, specific failure causes and retained progress across aggregate surfaces. Cache inspector fixtures distinguish evidence coverage, credential age, budget resources and spend attribution; unchanged meter readings and lexical scans alone are not complete zero-egress proof, while companion transport controls add evidence. Explicitly starting a sampler is not application-supervision verification. No tests executed, finding promoted or production edits. All recorded hashes/line counts and new public notes checked. Raw units remain27/32; four files remain totaling14,599 lines.

### tests-4 Stream Deck focus, control and feed boundaries

Read StreamdeckLiveTest completely; coverage97/100 files,27,808/40,603 lines. Preserve focused identity, snapshot-settled controls, read-only non-invocation, normal-exit relay cleanup, durable feed ordering and independent meter refresh. Stale readings deliberately retain values while suppressing visible age; reconcile with age-rendering requirements. Old-topic rejection assertions may be insensitive to an unnecessary current-feed reload; recorded as unverified candidate05, not a finding. Command-option read-only title lacks a write spy. Source/DOM/CSS evidence is not hardware, audio or manual browser verification. No test execution or production edits. All97 recorded hashes and line counts revalidated; raw units remain27/32 and three files remain totaling12,795 lines.

### tests-4 development shim identity and rebuild ownership

Read ScriptsAiurdevTest completely; coverage98/100 files,29,796/40,603 lines. Real shell shim with disposable repo/fake build and engine preserves control reuse, deferred restart rebuild, exact emitted-command execution with spaced shim path, checkout divergence refusals, workspace reset guard, release provenance/receipts and lock ownership. Fake generation files do not prove actual compiler semantics. Signal cleanup assertions ignore delivery and exit status while the fake build can finish naturally; recorded candidate06 for isolated mutation, not a production defect. No tests executed or production changes. All98 hashes and line counts revalidated; raw units remain27/32. Remaining DashboardLive and AiurEngine tests total10,807 lines.

### tests-4 hypothesis reconciliation against adjacent coverage

Candidate03 not promoted: Codex.ConfigTest accepts any valid enum locally, but SchemaTest406-410 explicitly requires the parsed default to equal untrusted. Traced the default through embedded schema and scalar-preserving finalization. Candidate05 narrowed and earlier current-feed-reload speculation withdrawn: StreamdeckLive268-299 reloads the incoming identifier, so the remaining coverage question is whether an old-topic broadcast after subscription replacement reaches that guard. StreamdeckChannel443-451 directly injects a stale tagged message for its distinct handler. Updated both file assessments and preservation notes to avoid propagating superseded reasoning. Source inspection only, no test execution or new finding. Coverage remains98/100 files; four candidates remain.

### tests-4 engine lifecycle and command evidence

Read all4,245 lines of AiurEngineTest in bounded ranges; coverage99/100 files,34,041/40,603 lines. Preserve unknown control outcomes, exact restart sequencing, receipt/stamp refusal, live-not-ready session protection, attach without cleanup ownership, credential-group precedence and crash-evidence provenance. Real isolated sleeper tests and private artifact fixtures are distinguished from mocked kill/RPC/tmux/npm boundaries. Sibling survival with a kill spy does not prove actual sibling selection; sleep-based overlap and lexical readiness checks remain narrower than their titles. No new finding promoted or tests executed. All99 frozen hashes/line counts revalidated. Raw units remain27/32; DashboardLive's6,562 lines and four hypothesis dispositions remain before closing this unit.

### tests-4 DashboardLive partial review checkpoint

Read DashboardLive lines1-1900 continuously and recorded hash/range separately in partial_reads; it is not counted among completed files. Evidence so far preserves same-snapshot retained counts, unavailable versus zero, credential revocation across socket redirect, component-generation cache invalidation and exact ticket filtering. Direct render/structural checks remain distinct from LiveView event execution and real browser behavior. Four candidate dispositions remain; no new finding promoted or tests executed. Full-file coverage remains99/100 and34,041/40,603 lines. Resume this file at1901; do not restart or count the remaining4,662 lines as read.

### tests-4 retained action authority and lifecycle checkpoint

Extended DashboardLive source review through3800; contiguous range1-3800 saved separately, not counted as a complete file. Preserve retained-detail authority, exact version/action checks, writable-gate revalidation, initial-answer versus corrective-revision confirmation, original-answer preservation and queue/audit lifecycle distinction. Integration capstones use production queue/store components but inject tracker facts and manually report delivery/acknowledgement/resolution. Metrics convergence titles exceed unchanged latency-absence assertions; retain this limitation for final reconciliation. No new finding promoted or tests executed. Resume3801; remaining2,762 lines include helper verification. Full-file coverage remains99/100.

### tests-4 full source reading checkpoint

DashboardLive remainder3801-6562 and helpers reviewed; all100 files and40,603 lines now fully read, with every frozen hash and line count revalidated. Preserve typed identity collision refusal, message retry identity, requested/applied controls, responsive held Add Agent mutations, retained history, and family alias intent. Helper review establishes bounded dispatch waits, actor barriers and private stores with filesystem sync disabled; this is not crash durability or browser execution. Four candidate dispositions remain before raw-unit closure, so raw coverage remains27/32. No new finding promoted and no test suite run.

### tests-4 owned-process failure cleanup probe

Promoted candidate02 as P3 tests-4-cont-03: the actual two cleanup callbacks stop the outside sleeper but leave the inside sleeper runnable after a failed reap and directory removal. Extracted frozen AST helpers/callbacks, verified both owned children initially running, and used explicit owned-PID cleanup as positive control; all children stopped. tmp_root! constructs paths only and suite cleanup removes its log directory, not this child. Probe exits0 with four results. No production reaper invoked or live workspace swept. Three candidates remain (04/05/06); raw units remain27/32.

### tests-4 complete: five bounded findings

Closed tests-4 after100 full-file reads totaling40,603 lines, exact manifest membership and all hashes reverified. Candidate04 narrowed to proven mailbox-consumption versus tick-completion gap: actual helper returns during a held production snapshot callback; sys.get_state waits until release. Candidate05 not promoted: synchronous old-relay stop explains the post-focus subscription test, while already-queued stale messages need separate direct injection. Candidate06 narrowed to signal-oracle insensitivity: the actual two shim tests pass against original and INT/TERM-ignored private copies (2/2 each). Five findings total: threeP2, twoP3; none alleges a newly reproduced production failure. Initial monitor probe had an extraction-count assumption corrected before the successful run; warnings are unused unavailable dependencies. Research probes do not establish full-suite, real-build, crash-durability or TUI verification. Raw units now28/32;946 findings,182 high-priority skeptic checks still pending. Continue skills-prompts, three duplication sweeps, reconciliation and final synthesis/planning.

### Skills/prompts: ticket-agent contract checkpoint

Read all11 aiur-agent entry/reference files plus the shared per-turn prompt:12/250 files,1764/36,169 lines, with frozen hashes recorded. Three provisionalP2 instruction contradictions: local Credo forbidden versus required; stacked blocker PR base versus unconditional integration-base retarget; obsolete inherited GITHUB_TOKEN guidance versus governed credential-file contract. These are source consistency findings, not attributed production incidents. Preserve exact-head CI, typed Decision lifecycle, corroborated dependency readiness, worktree ownership and agent manual-test guard. Four narrower questions remain for source reconciliation. Instructions were treated as research data; no issue publication, model change, Aiur launch or production edit. Raw units remain28/32; resume aiur-build pack.

### Skills/prompts: Build Order planning contract

Read all nine aiur-build markdown entry/reference/example files; coverage21/250 files,2766/36,169 lines. Preserved finite scope, source precedence, explicit promotion authority, exact approval SHA, single contract ownership, reconnection ledger and capstone evidence. Added provisionalP2 phase-authority conflict: workflow mandates computed antichain phases while planning contract calls phase authored metadata. Minimal examples are validator fixtures, not verified implementation tickets; lane icons are distinct from pack/member icons. Bundled validator exists but was not run. Private historical illustration omitted from public notes. All21 recorded hashes/line counts rechecked. Raw units remain28/32; resume aiur-debug references.

### Skills/prompts: diagnostic and monitoring evidence boundaries

Read nine diagnostic, handoff, introduction, meta-check and monitoring documents; coverage30/250 files,4437/36,169 lines. Preserve correlation hierarchy, release-versus-running identity, unknown telemetry, actor/process distinction, immutable retry identity, observation authority and finite-run reporting. Relative links resolve; no broken-link finding. Meta every-finding promotion versus deferral/creation freeze retained as candidate pending governing Executor reference. Historical examples and watcher semantics are source claims, not newly measured incidents or runtime verification. All30 hashes/line counts rechecked; four existing provisionalP2 findings unchanged. Raw units remain28/32. Resume aiur-run and Executor reference.

### Skills/prompts: Executor authority and convergence

Read full aiur-run skill1245 lines and Executor reference662 lines; coverage32/250 files,6,344/36,169 lines. Promoted candidate05 as provisionalP2: ticket-required retrospective completion conflicts with deferred-without-ticket policy and creation freeze inside the governing reference. Added Executor credential wording to existing finding03 rather than duplicating it. Preserve wake notification/consumption distinction, roster renewal/acknowledgement distinction, exact versioned Decision authority, finite takeover, proof-based review and observed savings. Resume-first pause intent, cap/scheduler/binding claims and monitoring record count wording remain hypotheses. All32 hashes/line counts rechecked. No runtime launch, agent delegation, publication or production changes. Raw units remain28/32; resume ce-babysit-pr.

### Skills/prompts: PR watch and brainstorm entrypoint

Read ce-babysit-pr entrypoint and watch-loop reference plus ce-brainstorm entrypoint; coverage 35/250 files, 7,090/36,169 lines. Preserve host-qualified identity, fixed invocation budget, one active writer, uncertain-mutation reconciliation, mode-specific readiness and optional stack scope. Added provisional P3: parked-thread manual-only reopening instruction contradicts automatic identity-change reopening documented later and implemented by the frozen detector. AST-extracted function probe passed unchanged/changed/initial-baseline controls; no remote fetch, actor attribution or end-to-end watcher claim. Brainstorm entrypoint reviewed as data, not applied; linked synthesis, provenance and section contracts remain to read. Rechecked all 35 recorded hashes and line counts. Raw units remain28/32. Resume brainstorm references.

### Skills/prompts: brainstorm provenance and artifact contracts

Read all14 brainstorm markdown references; coverage 49/250 files, 9,393/36,169 lines. Preserve examined-user-decision provenance, explicit assumptions, requirements-versus-execution readiness, architecture-subject exception, complete textual requirements alongside diagrams, optional read-only organizational context and format-specific handoff. Confirmed settled-decisions copies byte-identical; named upstream parity test absent from frozen snapshot, so no test execution claimed. Interactive-only versus pipeline guidance and fixed-main source links remain follow-up questions pending caller/source reconciliation. No additional finding promoted; five provisional P2 plus one P3 remain. Rechecked all 49 recorded hashes/line counts. No workflow invocation, external research, publication, agent dispatch, runtime launch or production change. Raw units remain28/32; resume next manifest skill.

### Skills/prompts: review scope identity and evaluation fidelity

Read code-review entrypoint and seven scope/routing/dispatch/finish/eval references; coverage 57/250 files, 10,545/36,169 lines. Disposable local Git probe reproduces wrong-source success for a fork PR with a same-named origin branch; correct-repository control matches expected head. Added provisional P2 scope finding and P3 stale eval polling criterion contradicting the current single-collection contract. Preserve report-only authority, immutable review scope, independent evidence, source-detail hydration and validation-degraded blockers. Remote plan/standards/metadata and late completeness routing remain a follow-up question. Rechecked all 57 hashes/line counts; no remote API, model dispatch or production changes. Raw units remain28/32. Resume code-review personas and templates.

### Skills/prompts: reviewer evidence and calibration

Read eight reviewer persona assets plus complete subagent template; coverage 66/250 files, 11,502/36,169 lines. Preserve concrete failure traces, public consumer semantics, deployment-window compatibility, intentional human-only/atomic workflow exceptions and full evidence hydration. Added provisional P3: mandatory1000-line P1 threshold conflicts with shared suppression unless a project standard supports it. No large-file decomposition recommendation follows from size alone. Migration remote-base/head transfer remains a follow-up candidate. Initial truncated template read was replaced by complete bounded reads. All 66 hashes/line counts rechecked. No agents, databases, browsers, deployments or production edits. Raw units remain28/32; resume unread personas and report/validator templates.

### Skills/prompts: review bundle coverage and dormant validation

Read remaining11 code-review markdown files; coverage 77/250 files, 12,459/36,169 lines. All manifest code-review markdown now covered, not bundled scripts/schema. Preserve expected-load evidence, current-source precedence over past learnings, caller/guard inspection and independent per-finding batch verdicts. Older single-finding unreadable-source rejection is not promoted as current behavior: active finish-review selects batch template and retains degraded blockers. Added prior-comment retrieval completeness/identity follow-up; no additional finding promoted. All 77 hashes/line counts rechecked. No API, model, browser, compiler or runtime checks claimed. Raw units remain28/32; next .claude/skills/ce-commit-push-pr/SKILL.md.

### Skills/prompts: publication target and maintenance boundaries

Read commit/push/PR entrypoint, branch and description references, standalone commit skill and compound-refresh entrypoint; coverage 82/250 files, 13,656/36,169 lines. Added provisional P2: explicit PR target used in description composition is omitted from final edit command; local installed CLI help confirms current-branch PR selection when omitted. No PR mutation or historical incident demonstrated. Preserve mode-specific publication authority, actual head/base evidence, selective staging, no-widening maintenance scope, uncertainty-as-stale and applied-versus-recommended reporting. Supporting maintenance references must reconcile citation-related exceptions before another finding. All 82 hashes/line counts rechecked. Raw units remain28/32; next compound-refresh supporting markdown references. No production change.

### Skills/prompts: maintenance transitions and knowledge capture

Read all four compound-refresh supporting markdown files and full ce-compound entrypoint; coverage 87/250 files, 14,810/36,169 lines. Resolved candidate14 without promotion: specific citation restrictions and consolidation routing explain the apparent headless-policy conflict. Added provisional P2 for same-path replacement followed by unconditional old-path deletion; instruction-level risk, no document deletion reproduced. Preserve substantive citation content, meaningful retrieval boundaries, scope-grounded vocabulary, primary-writer ownership, source/merge-state evidence and explicit degraded validation. Compound refresh follow-up routing remains a candidate. Rechecked all 87 hashes/line counts. No bundled script execution or production edits. Raw units remain28/32; next ce-compound supporting markdown references.

### Skills/prompts: knowledge evidence and synthesis contracts

Covered all11 compound supporting markdown files; coverage 98/250 files, 15,797/36,169 lines. Eight files fully read and three validated byte-identical to previously fully read refresh counterparts. Preserve source-grounded behavior, remote merge truth, historical citation adjudication, bounded technical session synthesis and invocation-scoped specialist guidance. Added historian output-contract and durable unverified-merge wording questions; no additional finding promoted and no agent workflow reproduced. Generic performance budgets are not Aiur requirements or measured savings. All 98 hashes/line counts rechecked. No scripts, external research or production edits. Raw units remain28/32; next ce-debug entrypoint and references.

### Skills/prompts: diagnosis authority and document-review entry

Read complete five-file debug markdown bundle and document-review entrypoint; coverage 104/250 files, 16,920/36,169 lines. Preserve causal evidence, regression-test ownership, inherited pipeline action/content boundaries, fix-owned edit scope, artifact-readiness distinctions and bounded reviewer dispatch. Extended identity candidate13 to explicit non-URL issue references; no new finding promoted. Investigation heuristics and sample commands are not verified runtime behavior, measured gains or proofs of causality. All 104 hashes/line counts rechecked. No debugging workflow, service, browser, peer or production change. Raw units remain28/32; next document-review supporting references/personas.

### Skills/prompts: document-review decisions and evidence routing

Read synthesis, walkthrough, bulk preview, Open Questions deferral and output template; coverage 109/250 files, 18,047/36,169 lines. Preserve distinct evidence/severity/mutation gates, peer-only silent-apply prohibition, explicit batch preview, no-fix safeguards and exact post-synthesis coverage. Added premise-cascade polarity and low-confidence/suppression-order questions for remaining persona/template reconciliation; no new finding promoted. Recorded in-memory interruption limit and read-before-write concurrency limitation without claiming reproduced loss. All 109 hashes/line counts rechecked. No review agents or document mutations invoked. Raw units remain28/32; next remaining document-review contracts.

### Skills/prompts: reviewer contracts and premise decisions

Read remaining11 document-review markdown files; coverage 120/250 files, 18,992/36,169 lines. Promoted candidate18 to provisional P2: Skip of a premise criticism leaves plan unchanged but cascade treats it as rejecting the criticized component. User cascade confirmation and independence safeguards limit impact; no agent run reproduced. Narrowed candidate19: suppression explicitly runs during synthesis, leaving residual-channel admission to reconcile. Added peer read/egress boundary question for adapter inspection. All 120 hashes/line counts rechecked; truncated reads replaced with bounded complete reads. No external model, eval, runtime or production change. Raw units remain28/32; next ce-dogfood markdown.

### Skills/prompts: browser evidence and teaching artifacts

Read complete dogfood and explainer markdown bundles, ten files; coverage 130/250 files, 19,617/36,169 lines. Preserve actual user journeys, terminal human blockers, regression/browser replay distinction, persona attribution, scope-specific teaching and optional human check-in. Added browser base/build/resume provenance question for related-contract reconciliation; no new finding promoted. All 130 hashes/line counts rechecked. No browser launch, server reuse, external publication, model dispatch or production change. Raw units remain28/32; next handoff and ideation markdown.

### Skills/prompts: handoff and ideation evidence

Covered six more files: four full source reads and two renderer copies verified byte-identical to previously fully reviewed brainstorm references. Coverage 136/250 files, 21,170/36,169 lines. Preserve untrusted continuity boundaries, exclusive snapshot creation, directive/evidence separation, explicit idea bases and bounded axis recovery. Five agents covering six frames is consistent; no finding promoted. Added session-cache eligibility question for remaining retention-contract review. All 136 hashes and line counts verified. No agent dispatch, external research, publication or production change. Raw units remain28/32; next remaining ideation references.
