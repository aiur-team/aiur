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

### Skills/prompts: ideation recommendation and research contracts

Completed seven remaining ideation references: six direct full reads and one previously reviewed learning prompt plus its complete single-paragraph invocation diff. Coverage 143/250 files, 22,330/36,169 lines. Promoted cache-session eligibility mismatch to provisional P3; retention rules confirm no session or timestamp eligibility despite session-only reuse claim. No stale output or model execution claimed. Added sampling/recurrence and scope-arbitration questions. All 143 hashes and line counts verified; truncated universal-reference middle replaced with bounded read. No network research, Slack access, publication or production change. Raw units remain28/32.

### Skills/prompts: optimization measurement and persistence

Completed six optimization markdown files: five direct full reads and one verified single-paragraph diff against an already reviewed learning prompt. Coverage 149/250 files, 23,828/36,169 lines. Preserve immutable evaluators, repeated baselines, scoped worker authority, immediate durable result recording and combined-change remeasurement. Added persistence/recovery, runner-up integration and budget/direction questions for helper/schema reconciliation; no finding promoted and no optimization executed. Targeted helper/schema searches are not full coverage. All 149 source hashes/line counts verified. Raw units remain28/32; next ce-plan markdown.

### Skills/prompts: planning authority and handoff

Covered seven planning files: three full direct reads and four SHA256-identical copies of previously reviewed references. Coverage 156/250 files, 25,829/36,169 lines. Preserve stable product/unit IDs, settled-decision provenance, bounded scope, unavailable-research disclosure and distinct review skip/failure states. Added HTML issue-body and diagram/routing reconciliation questions; extended cross-repo target question. No new finding promoted. All 156 hashes and line counts verified, including bounded replacement for truncated menu text. No plan execution, goal creation, tracker mutation or production change. Raw units remain28/32; next planning support references.

### Skills/prompts: plan readiness and deepening

Read four complete planning support references; coverage 160/250 files, 27,105/36,169 lines. Preserve launch-blocker readiness gate, stable section/unit IDs, accepted-only interactive changes and explicit unattended assumptions. Recorded provisional P3 command-contract contradiction: concrete verification commands required by section contract but exact test recipes globally prohibited. Added remaining format/domain routing question and expanded diagram reconciliation. All 160 hashes/line counts verified. No plan, subagent, test, tracker action or production change. Raw units remain28/32; next planning agent prompts.

### Skills/prompts: planning specialist evidence

Covered all16 planning agent prompts: five full direct reads and eleven complete bounded diffs against previously reviewed copies. Coverage 176/250 files, 28,875/36,169 lines. Preserve selective agent parity, human-only boundaries, grounded flow gaps, migration population/rollback evidence, exact-version research and measured-performance discipline. Extended existing one-ended diff and parent/specialist output-contract questions; no duplicate finding added. Generic architecture principles and historical commit patterns are not defect proof. All 176 hashes/line counts verified. No agent dispatch, external research, migration execution or production change. Raw units remain28/32; next remaining skills.

### Skills/prompts: development-server evidence

Read all12 polish markdown files; coverage 188/250 files, 29,700/36,169 lines. Preserve explicit launch configuration and bounded readiness checks without equating HTTP availability with correct checkout identity. Synthetic actual-helper probe returned unrelated test-script port9123 instead of dev5174; reordering unchanged entries returned5174. Added candidate31 for helper/recipe reconciliation and cross-unit dedup, not a new finding yet. No server, browser, live config, dotenv or external request used; temporary fixtures removed. All 188 hashes/line counts verified. Raw units remain28/32; next ce-pov.

### Skills/prompts: POV evidence and peer independence

Read all11 POV markdown files; coverage 199/250 files, 30,485/36,169 lines. Preserve verified-fact floors, conversation disconfirmation, named recipient authority, receipt-supported model independence, dirty/untracked identity checks, common evidence reconciliation and scoped cleanup. Added bounded-search versus verified-absence question; extended existing peer boundary question with explicit cooperative-scope limits. No new finding promoted. All 199 hashes/line counts verified. No peer, external query, publication or production change. Raw units remain28/32; next product-pulse markdown.

### Skills/prompts: product metrics and promotion evidence

Read five complete pulse/promotion markdown files; coverage 204/250 files, 31,296/36,169 lines. Recorded provisional P2 metric-source mismatch: setup omits payments-class default overrides but report fallback queries analytics. Added settings persistence, quality-score calibration and shipped-state/provider questions. Preserve buffered windows, explicit unknowns, PII exclusion, read-only DB and draft/publication distinction. All 204 hashes/line counts verified. No live query, credential access, provider call, scheduling or production change. Raw units remain28/32; next ce-proof.

### Skills/prompts: publication and PR-feedback boundaries

Read six complete markdown files; coverage 210/250 files, 32,180/36,169 lines. Added provisional P2 findings for unchecked Proof pull replacement and unsupported pre-existing-test classification. Extracted shell-command probe: structured error overwrites with null, empty response empties target, valid response preserves trailing newlines, malformed JSON preserves original. Added retry/privacy and escalation-contract questions; extended checkout provenance candidate. All 210 hashes/line counts verified. No external service call, credential access, PR mutation, subagent or production change. Raw units remain28/32; next recording-analysis skills.

### Skills/prompts: recording evidence and behavior preservation

Read thirteen complete recording/setup/simplification/strategy markdown files; coverage 223/250 files, 33,081/36,169 lines. Preserve observed/inferred distinction, unknown source mapping, exact behavioral equivalence, trust-boundary checks and strategy/execution separation. Added recording local-retention versus remote-processing candidate after targeted analyzer read; extended diff-baseline question. No new finding promoted. All 223 hashes/line counts verified. No media processing, API request, setup/config change, reviewer dispatch or production edit. Raw units remain28/32; next ce-sweep.

### Skills/prompts: feedback sweep contracts

Read ten complete sweep markdown files; coverage 233/250 files, 34,022/36,169 lines. Probed actual frozen state engine with synthetic sensitive content: body/quote removed, parent_summary retained. Recorded provisional P2 against requested Slack context and setup privacy promise. Added fetch/cursor, distributed lease and closure-evidence questions; sensitive sweep media explicitly disables transcription, narrowing prior candidate. All 233 hashes/line counts verified. No source API, message, real recording, shared-branch experiment or production change. Raw units remain28/32; next browser-testing skills.

### Skills/prompts: browser evidence and worker integration

Read eleven complete browser/Xcode/work markdown files; coverage 244/250 files, 35,669/36,169 lines. Replaced truncated work read with complete bounded ranges. Added provisional P2 worker-commit/integration contradiction, extended server identity question and recorded capability, tracker-retry and UI-verification follow-ups. Preserve real interaction evidence, explicit unknowns, actual-tree integration and test provenance. All 244 hashes/line counts verified. No browser, simulator, worker, tracker or production mutation. Raw units remain28/32; six markdown files remain before candidate reconciliation.

### Skills/prompts: full manifest read coverage

Finished final six markdown files, including complete tracker-defer diff against reviewed counterpart. All250 planned paths /36,169 lines now covered; exact manifest-set equality, unique paths, hashes and line counts verified. Added release-receipt and LFG-completion contract questions; narrowed recording privacy candidate for explicitly guarded sensitive sweep path. Review unit stays open: 42 candidates and19 provisional findings require reconciliation/dedup. No release, build, design import, worktree or production action. Overall raw units remain28/32; next candidate reconciliation.

### Skills/prompts: release candidate verification

Candidate45 partly promoted: release procedure omits npm manifest synchronization required by CI and verifies a different executable than escript.build produces. Extracted actual version gate tested with copied frozen resolver/manifests: matching baseline passes, mix-only bump fails, synchronized control passes. Repro stored in tooling/release_version_gate_probe.py. Publication-receipt and repository-target questions remain open. Source-specific raw finding search returned no matching locations; semantic dedup remains. All250 read coverage unchanged;21 provisional findings (16P2/5P3). No production build, tag, registry call or release.

### Skills/prompts: scope and evidence candidate reconciliation

Reconciled five candidates after targeted governing-source rereads: ideation scope override, bounded-search absence claim, feedback blocking contradiction and distribution-driven quality calibration promoted as four P3 instruction findings. Current-harness capability mismatch not promoted as historical defect; retained as capability-discovery requirement, with worker commit inconsistency already finding19. No population-quality or actual stalled-run claim. Findings25 (16P2/9P3); raw unit remains open. No tools invoked for ideation, publishing, reviews, scoring or worker execution.

### Skills/prompts: planning and artifact ownership reconciliation

Reconciled four candidates using caller/child contracts: brainstorm pipeline-mode inconsistency, historian write prohibition versus artifact requirement, and diagram framing versus validation promoted as P3. Selective-refresh candidate not promoted as unauthorized mutation: headless invocation forbidden and interactive action-confirmation stage applies. Preserved limits: no actual automated stall, lost artifact or generated-plan failure claimed. Findings28 (16P2/12P3); raw unit remains open. No child workflow or production changes.

### Skills/prompts: operational recovery and monitoring reconciliation

Reconciled candidates02/06/08: unchecked index-lock deletion, global-resume recovery versus binding existing pauses, and mandatory observe versus exactly-one recording rule. Both retrospective functions independently append monitoring outcomes; no live log was changed. Per-ticket handler returns globally_paused explicitly, but complete CLI exit behavior remains unverified and is not claimed. Findings31 (18P2/13P3); raw unit remains open. All250-file coverage unchanged. No lock removal, runtime resume or production change.

### Skills/prompts: artifact handoff and planning boundary

Candidates28/30 reconciled: HTML issue handoff lacks format adaptation; atomic-work shortcut bypasses planning-only direction. Unit headings explicitly supported, draft title normalized by final metadata contract, and internal specialist examples do not require verbatim final output. Knowledge-work carve-out disproves the universal explanation but not its pipeline restriction. Findings33 (18P2/15P3); coverage remains250/250 and raw unit stays open. No issue creation, tracker rendering claim or implementation.

### Skills/prompts: review endpoint verification

Candidate12 resolved into two P2 findings: migration dispatch passes a logical base marker and one-ended commands inspect the ambient tree; simplification can choose the feature tracking upstream and omit uncommitted edits. Disposable Git probe reproduces all three scope errors with explicit endpoint/base/working-tree controls; invalid logical marker exits128. Probe saved as tooling/review_diff_scope_probe.py. No real PR or production mutation. Findings35 (20P2/15P3); raw unit remains open. Candidate11 remains unresolved.

### Skills/prompts: review identity and finding lifecycle

Candidate11 reconciled into three findings: ambient checkout identity in remote-review metadata, absent PR-head binding before feedback mutation/push, and requirements findings introduced after numbering/validation. Explicit remote-source rule limits the plan-discovery claim; active standards need not be PR-authored, so no separate finding for those. URL fallback targeting remains candidate13. Findings38 (22P2/16P3); raw unit stays open. No real PR, reply or mutation performed by these reviewed workflows.

### Skills/prompts: tracker target and comment completeness

Candidate13 resolved: prior-comment REST fetch omits pagination; several qualified-target workflows show commands that fall back to ambient repository identity. Installed gh2.96.0 help confirms pagination and repository-placeholder behavior; no external requests or mutations. Plan issue creation intentionally uses the current project, so absent --repo alone was not promoted there. Findings40 (24P2/16P3); raw unit remains open.

### Skills/prompts: aliases and source-reference links

Candidate03 not promoted as runtime failure: stale ce-review/ce-prefixed suggestions coexist with explicit ce-code-review routing and real persona assets. Candidate10 promoted once for byte-identical HTML references hard-coding blob/main without revision/path verification. Findings41 (24P2/17P3). Candidate ledger now explicitly reports42 listed,19 terminal,23 unresolved (partial dispositions stay unresolved). All250 files read; raw unit remains open. No external calls or production changes.

### Skills/prompts: durable uncertainty and residual semantics

Candidates17/19 promoted: offline merge-state grounding keeps landed claims with temporal qualification but report-only uncertainty; residual contract both suppresses and admits unverified concerns and also carries verified success notes. Scope excludes previously verified historical claims and alleged R29/R30 phase-order defects. Findings43 (25P2/18P3);21 listed candidates unresolved. All250 files read; raw unit remains open. Source review only, no external call or production mutation.

### Skills/prompts: sample inference and release availability

Candidates23/35 promoted: issue-state/theme overlap does not prove recurrence or resolution, capped samples do not establish trend coverage, and promotion drafts can turn active/unreleased evidence into available-now wording. Exact-count rules and draft-only review limit but do not remove these inference gaps. Remote draft persistence is explicit and not public posting; auth prefix alone does not prove secret exposure. Findings45 (26P2/19P3);19 listed candidates unresolved. No external calls or production changes.

### Skills/prompts: release target and completion receipts

Completed partial candidate45 with repository-split and premature npm-success findings. Tag push uses origin while release creation uses canonical repo; installed gh2.96.0 help confirms absent-tag auto-creation unless verify-tag is used. Frozen workflow has build/smoke prerequisites and explicit per-package registry verification not awaited by the recipe. Findings47 (28P2/19P3);18 listed candidates unresolved. No release, tag mutation, build or registry request.

### Skills/prompts: optimization runner-up integration

Candidate26 promoted: workers leave edits uncommitted, parent commits winner only, then cherry-picks runner-up without an experiment commit. Helper creation/cleanup does not fill the gap. Codex directory selection and cooperative scope enforcement alone do not prove independent defects. Findings48 (29P2/19P3);17 listed candidates unresolved. No worker, measurement or production mutation. Related parallel-work transfer finding19 retained pending semantic grouping.

### Skills/prompts: optimization recovery and admission

Candidates25/27 resolved: integration/cleanup precedes final outcome logging without resume reconciliation; batch admission ignores remaining iteration allowance and stop checks follow the batch. Counterexample3 completed/limit4/batch4 yields7; this is algorithm arithmetic, not measured execution. Append/update wording, regenerable digest and ambiguous judge-direction wording not independently promoted. Findings50 (31P2/19P3);15 listed candidates unresolved. No optimization execution, paid judge or production change.

### Skills/prompts: pulse preference persistence

Candidate33 resolved: interview accepts error/latency preferences expressly unsupported by final config/report rules, and promises scheduling preferences without their persistence contract. Scoring-note encoding and same-minute report retention remain design questions, not independently proven incidents. Findings51 (31P2/20P3);14 listed candidates unresolved. No config, report, schedule or production changes.

### Skills/prompts: local-only shipping ownership

Candidate46 resolved: no-remote fallback uses git add -A instead of task-owned staging. CI residual and local-only DONE paths are explicit exceptions, not false green claims; evidence-only idempotent retry is explicitly supported. Findings52 (32P2/20P3);13 listed candidates unresolved. No LFG execution or production mutation.

### Skills/prompts: ambiguous tracker writes

Candidate43 resolved: retry/fallback does not distinguish rejected creation from committed write with lost response, despite a stable finding fingerprint in ticket metadata. Residual filing does not itself authorize merge, so no separate severity acceptance finding. Findings53 (33P2/20P3);12 listed candidates unresolved. No external ticket creation or failure injection.

### Skills/prompts: capability error classification

Candidate44 narrowed to a P3: any list_simulators error is reported as XcodeBuildMCP not installed. No server/simulator invoked. Tool-version and SwiftUI-link assertions remain explicit unverified questions; URL fallback is not claimed as tap proof. Figma project-standard override prevents treating generic width preferences alone as a confirmed violation. Findings54 (33P2/21P3);11 listed candidates unresolved. No production changes.

### Skills/prompts: processing boundaries and retry uncertainty

Candidate38 promoted for standalone local-only prose versus default external transcription when a key exists; sensitive sweep no-transcribe path excluded. Candidate36 not promoted: initial UUID examples do not disprove retry prose, and partial payload/key semantics plus diagnostic recipient/redaction remain unverified API questions. Findings55 (34P2/21P3);9 listed candidates unresolved. No media upload, API call, bug report or production mutation.

### Skills/prompts: launch specification consistency

Candidate31 resolved into actual port-helper order-dependence and Procfile versus Procfile.dev recipe mismatch. Saved tooling/polish_port_probe.py reproduces unrelated-test port9123 versus dev port5174 by reordering identical scripts. Server identity/race concerns stay with candidate21. Findings57 (36P2/21P3);8 listed candidates unresolved. No server, network or termination action.

### Skills/prompts: browser evidence identity

Candidate21 resolved into three source-level findings: PR base replaced by trunk, resumed completed scenarios not reconciled against revision changes, and listener readiness without served-target identity. No browser failure or competing-process incident claimed. Findings60 (39P2/21P3);35/42 candidates resolved,7 remain. Historical row SHAs and selective retesting remain useful; freshness needs an explicit check.

### Skills/prompts: shared sweep ownership and completion

Candidate40 resolved with tooling/sweep_shared_lease_probe.py against the actual frozen engine and two temporary Git clones. A remote takeover does not invalidate ownership in a stale checkout (OK versus LEASE-LOST control); wrap-up publication precedes completion and release, leaving those local changes unpublished. No external source write occurred. Findings62 (41P2/21P3);36/42 candidates resolved,6 remain. Initial probe had an incorrect assertion that empty default last_run must be serialized; removed that unrelated assumption and reran successfully.

### Skills/prompts: sweep ingestion, retry and resolution evidence

Candidates39/41 reconciled into four source-contract findings: older-parent reply discovery, missing Slack actor setup, landing-only resolution and persisted media retry scheduling. No live missed reply, failed retry or false close-out claimed. Explicit failed-ack cursor hold prevents promoting the intended workflow as skipping deferred items; capped pagination, read-only source progress, archive collisions and close-out idempotency retain stated evidence limits. Findings66 (44P2/22P3);38/42 candidates resolved,4 remain.

### Skills/prompts: peer read scope and recipient exposure

Candidate20 narrowed to a P3 documentation finding: doc-review's no-material-exposure claim does not follow from greater host privileges or sending one document to the peer. Inspected frozen adapter flags and preserved POV's explicit cooperative-scope limitations; no peer invocation, runtime isolation certification or disclosure claimed. Findings67 (44P2/23P3);39/42 candidates resolved,3 remain.

### Skills/prompts: capacity and listener instructions

Candidate07 reconciled against frozen CLI override storage, lifecycle/slot precedence, dispatch load gate and listener registry/renderer. Explicit CLI cap wins;1.5 times16online schedulers is24; registry has26bindings versus prose24. No launch or live-capacity observation. Findings70 (45P2/25P3);40/42 candidates resolved,2 remain. Cross-claim dedup still required.

### Skills/prompts: Decision and readiness reconciliation

Final candidates01/04 resolved against frozen ToolExecutor, DecisionAttention, DecisionStore/projection and merged-blocker delivery. Three P2 instruction mismatches: legacy options discarded, merged readiness excluded by unblocked-only shorthand, and dismissed-request resolution lacks an answer action. No live failure asserted. Findings73 (48P2/25P3);42/42 candidates reconciled. The unit remains in progress pending semantic dedup, source/manifest consistency audit and raw closure.

### Skills/prompts: raw review closure

Closed the skills-prompts raw unit as reviewed_pending_synthesis after revalidating all250manifest paths/hashes and36,169lines, checking every finding citation exists/in range, and reconciling all42candidates. Retained73raw observations (48P2/25P3), grouped by related contracts in review/in-progress/skills-prompts-closure-audit.json; cross-unit semantic dedup is explicitly pending. Inventory now29/32raw units and1,019findings (14P0/168P1/616P2/221P3), with182high-severity skeptic reviews still missing. Three raw duplication sweeps remain. This is unit closure, not completion of the overall research.

### Name duplication: filesystem and control-call contracts

Read all six atomic_write and all six control_api_call definitions. Four filesystem wrappers already use Fs; spill writing adds exclusive creation/containment and a different result shape. Control-call extraction must preserve configured versus caller/fixed timeouts and PauseResume's specific crash reasons. Updated name triage to9families/170literal definitions; no extra raw finding or savings count, because common bodies overlap the body sweep. Callback/name sweep remains incomplete.

### Name duplication: age, freshness and count contracts

Read21age_label,25freshness_label and18count_label clauses across six modules per family. Preserve units, missingness, partial/truncated counts and vocabulary differences. Four stale-to-Healthy mappings corroborate part of web-occ-09; linked without adding a new defect or validating the full inherited claim. Name triage now12families/234literal definitions; callback and remaining-name review still open.

### Name duplication: startup wrappers

Read all122start_link definitions across122modules (438summed source-span lines). Registration defaults, option forwarding, facade ownership, state construction, validation, release waiting and supervisor type remain distinct; do not infer a generic startup abstraction from common OTP syntax. Name triage now13families/356literal definitions. Saved a35name priority queue from the full census to guide remaining work without treating the queue as a reduced sweep scope.

### Name duplication: cleanup and subscription ownership

Read all42terminate clauses in36modules and45subscribe clauses in38modules. Preserve graceful persistence versus crash guarantees, owned-child cleanup order, restart-safe reaper policy, recipient identity, durable bindings, generation scope, authentication and explicit failure contracts. Thin PubSub wrappers already reuse their transport; no new defect or savings claim. Name triage now15families/443literal definitions; broader sweep remains open.

### Name duplication: health and freshness semantics

Read44health clauses in27modules and28freshness clauses in19modules. Separate source accessors, scalar normalization, aggregate health, reconciliation metadata and UI projections. Preserve strict versus inclusive threshold comparisons, nil-expiry versus missing-observation semantics and rich failure/age records. Existing web-occ-20 overlaps part of this evidence; no new defect count. Name triage now17families/515literal definitions; remaining families/callbacks still open.

### Name duplication: parsing and positive integers

Read33positive_integer clauses in17modules and39parse definitions/declarations in21modules. Preserve complete-string versus prefix parsing, bounded versions, defaults, error envelopes and streaming state. Matching model-list bodies call different provider converters; reviewed those helper differences before considering shared envelope iteration. Name triage now19families/587literal entries. No new runtime bug or savings count; remaining sweep stays open.

### Name duplication: snapshot ownership and observations

Read all 63 snapshot definitions/declarations in 52 modules. Preserve process identity/timeouts, authority and generation scopes, provider validation, redaction, freshness/provenance/truncation, and distinct unavailable-data envelopes. Multi-source reads do not establish a transaction merely by returning one map. Empty-shaped failure fallbacks need consumer review before defect classification. Name triage now 20 families/650 literal entries; no new runtime defect or savings claim, and the broader sweep remains open.

### Name duplication: persistent loading and recovery policy

Read all 51 load definitions/declarations in 38 modules, six artifact-reading helpers, and JsonStore/GlobalPauseStore. Identified bounded JSON reading as a narrower sharing candidate while preserving zero-byte policy, size/type checks, domain decoders, errors and recovery state machines. Global-pause error handling and cache empty fallbacks are distinct policies, not interchangeable defaults. Name triage now 21 families/701 literal entries; no new defect or savings count. Remaining sweeps and downstream verification remain open.

### Name duplication: retrieval, identity and field presence

Read all 30 fetch, 27 get and 26 lookup definitions/declarations. Preserve financial access identity, cache clocks/provenance, repository and generation scope, ambiguous versus absent identity, retained-store health and pricing intervals. MapAccess truthiness fallback differs from Decision/projection presence-preserving helpers for false and nil; no consolidation is safe without choosing that contract explicitly. Name triage now 24 families/784 literal entries. No new runtime defect or savings claim; remaining sweep and caller verification remain open.

### Name duplication: event routing and generation scope

Read all 24 topic, 18 broadcast and 17 generation definitions/declarations. Preserve repository/identity/connection routing, local versus distributed publication, invalidation versus full-snapshot payloads and domain-specific failure reporting. Generations include independent counters, source vectors and random tokens; accessor similarity does not establish a shared clock. Name triage now 27 families/843 literal entries. Subscriber/owner-transition verification and remaining sweeps stay open; no new defect or savings count.

### Name duplication: refresh completion and observation effects

Read all 28 refresh and 33 observe definitions/declarations. Separate cast acceptance from synchronous completion, projection aging from fresh IO, protected reads from presentation updates, and best-effort meters from persisted membership/readiness changes. Preserve credential identity, account continuity, task ownership and persistence ordering. Name triage now 29 families/904 literal entries; remaining sweep and transitive verification stay open, with no new defect or savings count.

### Name duplication: write mechanics and durability policy

Read all 24 write definitions/declarations in 19 modules and complete Fs. Existing atomic replacement is a sharing point, but callers differ in file versus recovery syncing, permissions, bounds, error mapping, cleanup, memo invalidation and append ownership. ModelDiscovery invalidates its memo even when rename returns an error; preserve or explicitly revise that behavior in any consolidation. Name triage now 30 families/928 literal entries. No crash-durability certification, new defect count or savings claim; remaining sweep stays open.

### Name duplication: requests and source attribution

Read all 24 request and 28 source definitions/declarations. Preserve control-intent idempotency, origin and credential identity, transport/concurrency policy, provider headers and domain error envelopes. Source helpers describe distinct health, disclosure, pricing and accounting contracts; common names do not justify one representation. Name triage now 32 families/980 literal entries, not 32 completed raw review units. Remaining sweep and transitive verification stay open; no new defect or savings count.

### Name duplication: record construction versus persistence

Read all 31 record definitions/declarations in 19 modules. Distinguish map construction, bounded in-memory updates, enqueue acceptance and persisted state. Preserve deduplication, identity, retention and failure policies. SaturationSentinel does not match its append result; writer acceptance and this static candidate require caller/failure review before defect classification. Name triage now 33 families/1011 literal entries; remaining sweep and transitive verification stay open.

### Name duplication: resolution policy and side effects

Read all 40 resolve definitions/declarations in 23 modules. Preserve pure lookup versus stateful resolution, identity and containment checks, explicit/default port policy, retained-data availability, historic pricing revisions and unavailable-versus-session analytics scope. Name triage now 34 families/1051 literal entries; remaining sweep and transitive verification stay open. No new defect or savings count.

### Name duplication: reconciliation and retention predicates

Read all 40 reconcile definitions/declarations in 22 modules and the availability/scope helpers for three presenters. Matching presenter bodies retain distinct validity and identity policies, overlapping inherited web-occ-17. Preserve handshake completion, boot-scoped claim retries, configuration uncertainty, compaction recovery and bounded transitions. Name triage now 35 families/1091 literal entries; the priority queue is not exhausted and is not a scope limit. Remaining sweep and transitive verification stay open.

### Name duplication: configuration changesets

Read all 28 changeset definitions across 28 modules. Existing Ecto reuse carries distinct zero/positive bounds, empty-value handling, obsolete-key rejection, raw-type checks, normalization order and cross-field validators. Preserve domain schemas and their composition boundary; cast-only bodies do not establish missing validation without field/helper/downstream review. Name triage now 36 families/1119 literal entries. Remaining sweeps and validation completeness stay open; no new defect or savings count.

### Name duplication: constructors and initialization policy

Read all 46 new definitions/declarations in 35 modules. Separate empty structs, validated records, runtime wiring and checkpoint restoration; preserve unknown/unavailable startup state, authority epochs, recovery bounds, diagnostic distinctions and observation age. Name triage now 37 families/1165 literal entries. Struct defaults and transitive validation are not certified by this pass; remaining sweeps stay open, with no new defect or savings count.

### Name duplication: presentation scope and current status

Read all 35 present definitions/declarations in 16 modules. Preserve retained data versus current health, ticket identity matching, capability-gated cards, accounting distinctions and unavailable/error shapes. Two trimmed-string helpers are a narrow sharing candidate; matching presentation names do not imply one view contract. Name triage now 38 families/1200 literal entries. Rendered output, transitive privacy and remaining sweeps remain unverified by this pass.

### Name duplication: builders and deferred effects

Read all 46 build definitions/declarations in 29 modules. Separate pure assembly, validated records, live reads, observation recording and closures that later publish or mutate. Preserve callback identity, source health, accounting evidence, query limits and PR workspace naming. Name triage now 39 families/1246 literal entries. Remaining sweep and transitive verification stay open; no new defect or savings count.

### Name duplication: execution ownership and completion

Read all 44 run definitions/declarations in 40 modules. Preserve provider-specific lifecycle cleanup, indeterminate coordination timeouts, host-retry ownership, sandbox/budget requirements and workspace staging. CLI print/exit repetition is a narrower candidate than shared execution; deletion-attempt counts need failure review before success claims. Name triage now 40 families/1290 literal entries. Remaining callbacks, rendering and broader sweeps remain open; no new defect or savings count.

### Name duplication: asynchronous callback policies

Read all 49 handle_cast clauses in 21 modules. OTP callback shape is shared protocol, while bodies retain writable/generation fences, refresh authorization, provenance, persistence/admission ordering and audio readiness/flush state. Name triage now 41 families/1339 literal entries. Cast acceptance does not establish durable success; remaining callbacks, rendering and broader sweeps stay open.

### Name duplication: rendering media and trust boundaries

Read all 54 render definitions/clauses in 21 modules, including complete LiveView render bodies. Preserve terminal output ownership, agent-input trust filtering, Decision correlation instructions, machine tokens, HTML/JSON encoding boundaries and distinct unavailable/physical-only UI states. Existing shell/components already share framing. Name triage now 42 families/1393 literal entries. This source review is not manual UI verification; remaining callbacks, helpers and broader sweeps stay open.

### Name duplication: startup contracts and disabled callbacks

Read all 123 init definitions in 123 modules. Preserve synchronous readiness, recovery failure policy, public-table restore ordering, unknown baselines, process ownership and supervisor restart semantics; not every init is a GenServer callback. Name triage now 43 families/1516 literal entries. An isolated frozen-source probe reproduces invalid ignore returns in both monitors and passes after an in-memory return-only correction, corroborating existing loose-4-01 without adding a defect. Twelve inherited findings now have partial duplication reconciliation; high-severity skeptical completion is unchanged. Remaining callback/name, concept and constant sweeps stay open; full application boot and transitive startup correctness are not claimed.

### Name duplication: call admission, authority and replies

Read all 424 handle_call clauses in 74 modules. Preserve deferred replies versus queue admission, writable/run/generation guards, durable ID reservation, caller-owned slot claims and authority-aware caches. Identical history-sampling callbacks and a containment timer-reset transition are narrow sharing candidates; existing Orchestrator/Tmux delegates already separate substantial logic. Flush callbacks have different durability meanings. Name triage now 44 families/1940 literal entries. No new defect or saving is counted; deferred completion, helper correctness, remaining names and broader duplication sweeps stay open.

### Name duplication: asynchronous messages and stale work

Read all 501 literal handle_info clauses in 96 modules, including LiveViews/channels. Preserve task/attempt/generation/token fences, owner-death policy, ordered stalled delivery, independent timer loops, render deduplication and authority revocation. Name triage now 45 families/2441 literal entries; all initially prioritized families have been inspected, but that queue is not the full name sweep. Remaining name triage, generated callbacks, concept/constant sweeps and transitive verification remain open. No additional raw defect, skeptical completion or savings claim is added.

### Name duplication: residual census and domain contracts

The complete literal census contains 13,748 distinct names, including 1,680 used in multiple modules. Read project (24 clauses/15 modules), status (32/15), identity (32/14) and persist (15/14), bringing reviewed families to 49/2544 literal entries. Preserve projection provenance, status failure envelopes, identity authority and persistence acceptance policies; identical joinability helpers are a narrow sharing candidate. A reproducible residual-name index records 1,631 unreviewed cross-module families without claiming they are defects or treating single-module names as code-reviewed. Raw duplication units, transitive checks and final synthesis remain open.

### Name duplication: codecs and value domains

Read encode (14 clauses/14 modules), decode (23/13), read (21/14), value (24/14) and datetime (30/13). Preserve public/durable schema distinctions, unsupported-version versus corruption handling, read failure envelopes, presence versus truthiness and accepted timestamp domains. Narrow sharing candidates include presence-based map access and DateTime-only helpers; existing timestamp/get work overlaps. Name triage now 54 families/2656 literal entries, leaving 1626 cross-module names in the regenerated residual index. No additional raw defect or savings claim is counted; helpers, incidence and remaining sweeps stay open.

### Name duplication: collections, publication and scheduling

Read all list, publish, put, reset, schedule, append, coverage and key definitions: 153 literal entries across eight families. Separate transient delivery from durable publication, persistence from best-effort diagnostics, keyed state transitions from map updates, and coalesced policy scheduling from bare timers. Three sample-timer helpers are a narrow sharing candidate; tracker-key wrappers already use a canonical implementation. Name triage now 62 families/2809 entries, with 1618 residual cross-module names. Raw findings and skeptic counts are unchanged; no new defect or savings claim is made.

### Name duplication: identity, paths and execution contracts

Read all execute, same_repository?, state_dir, unavailable, call, clear, entry and evaluate definitions: 125 literal entries across eight families. Repeated lowercased repository tuple comparisons are a narrow sharing candidate; preserve adapter shapes and invalid-input behavior. Path precedence, unavailable evidence, RPC failure policy, continuity revocation and effectful monitoring prevent blanket extraction by name. Name triage now 70 families/2934 entries; regenerated residual queue contains 1610 cross-module names. Raw findings and skeptic counts are unchanged; no new verified defect or saving is claimed.

### Name duplication: extraction, delivery and limits

Read extract, failure, schedule_tick, truncate, send_operator_message, specs, start and validate: 128 literal entries across eight families. Distinguish accounting counter semantics, transport acceptance, owner/generation lifecycles, validation boundaries and byte/codepoint/grapheme truncation. PeriodicWorker already exposes the guarded tick helper; provider failure envelopes and tool-spec envelopes are narrow sharing candidates. Name triage now 78 families/3062 entries, leaving 1602 cross-module names. Raw findings and skeptic counts are unchanged; no new defect or measured saving is claimed.

### Name duplication: clocks, payloads and startup ordering

Read payload, child_spec, entries, handle_continue, maybe_put, now and now_ms: 147 literal entries across seven families. Preserve checksum version rules, error causes, restart identity/policy, replay/subscription ordering and wall versus monotonic clock domains. Optional map/keyword insertion contains narrow sharing candidates with different nil/empty/predicate semantics. Name triage now 85 families/3209 entries, leaving 1595 cross-module names. Raw findings and skeptic counts are unchanged; no new verified defect or saving is claimed.

### Name duplication: acquisition, preparation and presence

Read open, path, prepare, present? and select: 62 literal entries across five families. Separate resource acquisition from filtered reads, preserve filesystem sync and compaction phase policies, and distinguish nonblank-string checks from broader presence predicates. Six modules implement equivalent trimmed-binary presence checks, a narrow sharing candidate; existing DecisionLog reuse already owns creation mechanics. Name triage now 90 families/3271 entries, leaving 1590 cross-module names. Raw findings and skeptic counts are unchanged; transitive containment and runtime correctness are not certified.

### Name duplication: versions, availability and checksums

Read source_version, all, available?, boot, catalog and checksum: 59 literal entries across six families. Four durable-record checksum implementations are identical, while tuple canonicalization, JSON normalization and tmux layout checksums require separate contracts. Preserve enumeration completeness, partial-health policy, recovery return shapes and catalog provenance. Name triage now 96 families/3330 entries, leaving 1584 cross-module names. Raw findings and skeptic counts are unchanged; no new verified defect or measured saving is claimed.

### Name duplication: classification, current state and enum domains

Read classify, current, emit and enum: 69 literal entries across four families. Preserve classifier unknown/fatal distinctions, configuration-path authority, synchronization effects, callback failure policy and allowlist result domains. Enum conversion contains narrow sharing candidates; UsageEnvelope and ExactMoney normalization helpers were also inspected. Name triage now 100 families/3399 entries, leaving 1580 cross-module names. Raw findings and skeptic counts are unchanged; no new verified defect or measured saving is claimed.

### Name duplication: fields, durable records and state normalization

Read field, from_record, history and normalize_state: 60 literal entries across four families. Field-access duplicates must preserve explicit nil/false and key precedence. Durable readers retain separate authentication/restoration rules; history carries distinct completeness and pagination contracts. Tracker normalization differs from lifecycle/health enums and agent mutation authorization. Name triage now 104 families/3459 entries, leaving 1576 cross-module names. Raw findings and skeptic counts are unchanged; no new verified defect or measured saving is claimed.

### Name duplication: notification, provenance and release ownership

Read notify, provenance, provider and release: 52 literal entries across four families. History and ticket-context provenance projection is an equivalent sharing candidate, including inspected opaque-ID helpers. Preserve notification failure isolation, source-health dimensions and generation/owner fences when releasing resources. Name triage now 108 families/3511 entries, leaving 1572 cross-module names. Raw findings and skeptic counts are unchanged; successful wrapper returns do not certify downstream delivery or durable release.

### Name duplication: control characters, subscriptions and counts

Read unsafe_control_chars?, unsubscribe, value_of, command and counts: 53 literal entries across five families. Separate strict and multiline character policies, durable subscription removal from local cleanup, and unavailable counts from zero. Accounting dual-key access and tolerant history unsubscribe contain narrow sharing candidates; command defaults differ on whitespace-only input. Name triage now 113 families/3564 entries, leaving 1567 cross-module names. Raw findings and skeptic counts are unchanged; runtime impact and savings are not claimed.

### Name duplication: dispatch, alerts and candidate authority

Read dispatch, emit_alert and fetch_candidate_issues: 53 literal entries across three families. Queue start-failure policies differ between coordination retry and decision-dispatch terminal notification. Preserve decision correlation, webhook admission and mutable candidate-label authority. Recent-merge and webhook delivery alert wrappers share narrow callback mechanics with distinct diagnostic labels. Name triage now 116 families/3617 entries, leaving 1564 cross-module names. Raw findings and skeptic counts are unchanged; no new verified defect or measured saving is claimed.

### Name duplication: flush, lifecycle and observation semantics

Read flush, identity_key, latest, lifecycle, map_value, observed_at, path_for and percent: 107 literal entries across eight families. Distinguish persistence from message/UI flush, credential from tracker identity, timestamp tie policies, lifecycle precedence and observation authority. Four strict percentage validators are equivalent sharing candidates; clamping, ratio calculation and formatting remain separate. Name triage now 124 families/3724 entries, leaving 1556 cross-module names. Raw findings and skeptic counts are unchanged; no new verified defect or measured saving is claimed.

### Name duplication: selection, identity and sweep policies

Read positive, relationship_definition, rows, same_identity?, selected, sort_key, state and sweep: 83 literal entries across eight families. Preserve empty-selection identity semantics, accounting cache relationships, ordering priorities, unavailable/empty states and retention versus recovery effects. Positive option validation and non-nil identity comparison contain narrow sharing candidates; usage relationships already share a constructor. Name triage now 132 families/3807 entries, leaving 1548 cross-module names. Raw findings and skeptic counts are unchanged; no new verified defect or measured saving is claimed.

### Name duplication: attribution, mutation and cleanup contracts

Read tracker_identity, update, actor, add_label, apply, clamp, close and compact: 80 literal entries across eight families. Preserve attribution validation, actor privacy, unsupported tracker capabilities, generation fences and compaction failure health. Clamp arithmetic contains sharing candidates with explicit reversed-bound differences; close includes both resource teardown and request invalidation. Name triage now 140 families/3887 entries, leaving 1540 cross-module names. Raw findings and skeptic counts are unchanged; no new verified defect or measured saving is claimed.

### Name duplication: completion, delivery and readiness stages

Read complete, deliver, enabled?, ensure, fetch_issue_states_by_ids, fetch_issues_by_states, ingest and initialize: 66 literal entries across eight families. Preserve stale-result fences, webhook delivery evidence, replay readiness, configuration default policy and provider filtering scope. Existing wrappers already expose several ownership boundaries; equivalent names do not imply equivalent completion guarantees. Name triage now 148 families/3953 entries, leaving 1532 cross-module names. Raw findings and skeptic counts are unchanged; no new verified defect or measured saving is claimed.

### Name duplication: invalidation, validation and progress evidence

Read invalidate, normalize_event, normalize_key, only_keys, parse_integer, pause_agent, progress and relationship_revision: 102 literal entries across eight families. Preserve epoch revocation, webhook routing, key completeness/alias policy, integer parsing domains and progress coverage/freshness. Strict decision key/parsing helpers and endpoint pause override selection offer narrow sharing candidates. Name triage now 156 families/4055 entries, leaving 1524 cross-module names. Raw findings and skeptic counts are unchanged; downstream validation and runtime effects remain unverified where noted.

### Name duplication: recovery and scan policy

Read replay, restore, scan and scope: 42 literal entries across four families. Existing DecisionLog sharing leaves domain corruption, torn-tail repair, checkpoint readiness and replay selection policy explicit. Monitor scanning also preserves retry eligibility after failed writes. Name triage now 160 families/4097 entries, leaving 1520 cross-module names. Raw findings and skeptic counts are unchanged; no runtime defect or saving is claimed.

### Name duplication: storage, sanitization and configuration contracts

Read store, ticket, title, tools, validate! and version: 61 literal entries across six families. Preserve ticket URL policy differences, configuration readiness thresholds and independent revision contracts. Transitive ResourceStore checks contradict ResourceFetch's same-clock comment and distinguish fetch success from a confirmed stored body; runtime impact is not established. Name triage now 166 families/4158 entries, leaving 1514 cross-module names. Raw findings and skeptic counts are unchanged; no measured saving is claimed.

### Name duplication: activation and provider authority

Read activate, auth_mode, authorize, connect, count and create_comment: 51 literal entries across six families. Preserve generation checks, provider auth vocabularies, socket authorization and comment provenance/write-through effects. ProgressRenderer and RootSummary share an equivalent nonnegative-count validator with nil fallback; zero-defaulting helpers have a different contract. Name triage now 172 families/4209 entries, leaving 1508 cross-module names. Raw findings and skeptic counts are unchanged; no runtime completion or saving is claimed.

### Name duplication: route decisions and queue admission

Read decide, decode_record, default_path, describe, empty and enqueue: 47 literal entries across six families. Full AnalyticsScope/UsageScope reads identify shared route-readiness mechanics while preserving different membership keys and rejection accounting. Keep decoder integrity policy, restart durability, unknown-state semantics and admission ambiguity explicit. Name triage now 178 families/4256 entries, leaving 1502 cross-module names. Raw findings and skeptic counts are unchanged; no runtime defect or saving is claimed.

### Name duplication: enrichment and tracker fetch boundaries

Read enrich and five tracker fetch families: 40 literal entries across six families. Preserve field-specific merge policy, issue-versus-PR ownership classification, singular first-match versus plural all-page lookup, and snapshot/resource-cache boundaries. Empty Linear/Memory defaults are capability policy, not observed external emptiness. Name triage now 184 families/4296 entries, leaving 1496 cross-module names. Raw findings and skeptic counts are unchanged; wrapper counts establish no network saving.

### Name duplication: graph traversal and presentation helpers

Read finish, fold, humanize, issue, message and model: 69 literal entries across six families. Equivalent DFS finishing-order traversal and three identical UI humanizers are narrow sharing candidates. Preserve completion generation fences, event ordering, ownership issuance and unknown/admission messaging. Name triage now 190 families/4365 entries, leaving 1490 cross-module names. Raw findings and skeptic counts are unchanged; no runtime correctness or savings are claimed.

### Name duplication: initialization and evidence defaults

Read model_label, mount, new_binding, non_negative, parse_timestamp and paused?: 60 literal entries across six families. Identify equivalent integer validators and nil-returning timestamp parsers while preserving offset acceptance, fallback policy, process-owned binding context and connected-only initialization. Pause predicates cover different containment, display and control populations. Name triage now 196 families/4425 entries, leaving 1484 cross-module names. Raw findings and skeptic counts are unchanged; no runtime defect or saving is claimed.
