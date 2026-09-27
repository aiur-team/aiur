# Research continuation

The user resumed the full research goal on 2026-09-26. The pause recorded in
`HANDOFF.md` is historical; no fleet operation or production implementation is
authorized by this research goal. The original handoff is preserved.

## Authoritative sources

- Research branch: `research/refactor-2026-09-26`.
- Working research directory: `~/.aiur/research/refactor-2026-09-26/`.
- Complete frozen code: path in local `scratch/complete-snapshot-path.txt`,
  commit `3339b887196d5e9aefb273117a14bf33391ee41f`.
- The original partial extraction is preserved. It matched 2,692 Git blobs but
  omitted 686 tracked paths. The complete extraction matches all 3,378 blobs;
  see `synthesis/snapshot-audit.json`. Missing areas include runtime guard
  scripts, browser files, configuration, examples and workflow files, so the
  final coverage review must account for them explicitly.
- The initial codebase boundary report measured `0972f0297`, not the later
  frozen review revision. Report both revisions wherever counts differ.

## Evidence repairs completed

`synthesis/verdicts/done.json` originally lost every `lens` label during export.
All 40 results matched local journal objects exactly. The restored metadata
records the label, workflow result key and journal hash. This is recovered
provenance, not 40 new verification passes. Reproduction tool:
`tooling/recover_claim_provenance.py <done.json> <local-journal.jsonl>`.

The initial recovered inventory was 36 of 60 claims with both lenses present,
two more with only a reproduction check, and 22 untouched. The inherited
"37 checked" count was wrong. `tooling/research_inventory.py <research-root>`
recomputes current artifact coverage and rejects ambiguous lens duplicates.
Its JSON output is saved at `synthesis/research-inventory.json`; artifact
presence does not prove a verdict is right.

New checks corrected `codebase-08` and `codebase-09`, with methods and limits in
`synthesis/verdicts/claims-codebase-control.json`. The source report was amended.
Two checks were performed sequentially by the continuing researcher; they are
not represented as independent agents. `synthesis/privacy-review.md` records the
privacy audit's completed corrections and still-open scope.

## Further architecture and privacy checkpoint

Six additional combined checks cover `codebase-02` through `codebase-06` and
`codebase-10`, bringing artifact coverage to 44 of 60 claims with both lenses.
See `synthesis/architecture-verification.md` for corrected conclusions,
revision-specific graph counts, reproduction commands and parser limitations.
The graph tool parses source without compiling or booting Aiur. Both saved
summaries reproduce exactly. Attention routing (`codebase-07`) remains open. The checkpoint now includes a
14-topic membership sample and confirmed alternate pause-attention path; the
complete emit-site census and condition-level coverage remain outstanding.

Privacy corrections preserve every numerical CSV measurement and public row;
76 private identifier/chronology cells were blanked. Three verdict fields were
redacted after provenance recovery, with explicit metadata. The title/body
comparison supplements rather than completes the contextual privacy audit.

## Gap measurement checkpoint

The independent arithmetic audit reproduced all 202 historical attendance
fractions and found 67 above one, caused by whole-minute numerators divided by
exact durations. `gaps.csv` retains every previous cell and adds a bounded
`duration_weighted_attended_frac`; the corrected aggregate barely changes and
the 86/108 majority-attended count is unchanged. See
`synthesis/gap-measurement-verification.md` for methods and limits.

Claim gaps-02 now has reproduction and interpretation checks, bringing artifact
coverage to 45/60. Its 78% bucket arithmetic reproduces, but it is not a causal
share proving human bottleneck ownership. Gaps-01 and the remaining causal
claims still require their full source checks. No category was silently
reassigned or prior numeric field overwritten.

## Wake-consumption checkpoint

Claim gaps-09 is checked, bringing both-lens coverage to 46/60. The cursors and
backlog counts reproduce, but a successful later tool result returned wake 419
while the observed cursor remains 352. Above-cursor records are not necessarily
unseen. The frozen implementation already has owner acknowledgements, observer
reads, bounded retention/overflow reporting and stalled-consumer status.
Metadata-only evidence and a reproduction tool are published. Action completion
and escalation must be evaluated separately; no consumer state was changed.

## Session-boundary checkpoint

Claim gaps-08 is checked, bringing both-lens coverage to 47/60. The inherited
34 compaction records are 17 boundary/summary pairs. Requiring a boundary to
precede the gap lowers silence-associated starts from 22 to 19; only three of
six pooled session-limit matches are same-repository matches. The study remains
observational with shared-input and cross-repository confounding. The independent
boundary audit reproduces limit durations and emits aggregates only.

## Interpretation checks completed

The missing interpretation checks for agents-10 and fixes-09 are recorded in
`synthesis/verdicts/claims-interpretation-tail.json`, bringing both-lens coverage
to 49/60. Earlier reproduction checks remain intact and are not presented as
new extractions. The agent report now distinguishes interrupted-turn exposure
from discarded work, resume waves from boots, and skill reads from instruction
violations. The fixes report withdraws the universal held-versus-clause rule,
corrects the retained install growth budget and capability-probe exception, and
separates selected case evidence from comparative effectiveness.

## Retrospective-cadence checkpoint

Claim meta-09 is checked, bringing both-lens coverage to 50/60. The frozen skill
is 71,315 bytes; 73,431 is the uncommitted live checkout. A content check found khala hourly
records through September 17 12:33Z, contradicting the reported absence since
02:19Z. E09 supports a later reported omission; compaction remains self-report. The coded arm/due/record helper already exists;
choose obligation ownership and enforcement placement explicitly in planning.
No helper or operational state was executed or changed.

## Deployment verification in progress

Meta-08 remains open; both-lens claim coverage remains 50/60. An isolated pure
classification probe confirms that same-checkout `executor-wait` and `watch`
can reach `ensure_built`, while common control verbs reuse a complete release.
The public #2656 incident remains open. The deployment checkpoint distinguishes
merged source, checkout HEAD, assembled release and running process identity;
remaining work is the historical episode and build-age surface audit. No live
launcher or shared release was executed or modified.

## Website review checkpoint

The nonelixir-web continuation has read all 16 website paths in its 178-file
manifest. Exact coverage, 162 remaining paths, three provisional P2 findings,
and rejected/unconfirmed candidates are in `review/in-progress/nonelixir-web.json`.
`tooling/website_review_probe.mjs` reproduces the reduced-motion false pass,
unbounded readiness request, and clipboard failure handling with isolated
source probes. Results carry source hashes and explicit limitations. No browser,
daemon, shared release or production file was changed. Raw unit coverage remains
23/32 and claim coverage remains 50/60; do not count this partial artifact as a
finished review unit.

The following Stream Deck lifecycle pass adds 29 full reads, for 45/178 files
and 133 remaining. Two more P2 findings have composed runtime reproductions:
duplicate monitor termination schedules duplicate replacements, and same-vendor
different-product removal closes the active device without reopening. The
`streamdeck_lifecycle_probe.mjs` tool uses a real missing-executable spawn to
confirm the first trigger and injected USB/timer/monitor collaborators for the
runtime consequences. Partial-unit findings total five. Next work is the channel,
controller, audio and rendering corpus plus remaining scripts/tests. Raw unit
coverage is still 23/32; claim coverage remains 50/60.

The channel/command pass adds nine complete reads (54/178; 124 paths remain).
Three more P2 findings reproduce offline Send text loss, false Implement QUEUED
state and missing server-cursor history navigation. The source probe also shows
that `say`/`control` error replies are discarded, while answer-command errors
reach their callback. The server already supplies acceptance/error receipts and
history cursors; the client does not complete those contracts. Eight findings
remain in the partial unit. Controller test coverage is partial, recorded in its
coverage notes. Continue with audio/rendering and outstanding controller tests;
do not equate transitively loaded probe dependencies with reviewed files.

## Completion contract — all still required unless explicitly checked

- [ ] Complete privacy/provenance review of inherited and new public artifacts.
- [ ] Finish both checks on all 60 claims; retain corrections and disagreement.
- [ ] Correct all six source reports where verdicts contradict their headlines.
- [ ] Complete the 32 planned review units and coverage follow-ups, including
      the runtime areas omitted from the old extraction.
- [ ] Skeptic-check every P0/P1 finding; retain P2/P3 with honest verification
      status. Deduplicate without losing any source ID.
- [ ] Produce `review/code-review.md`, `review/findings.json`, and
      `review/by-boundary.md`, then audit source-ID coverage and counts.
- [ ] Challenge every cut/merge/externalize recommendation and account for
      features omitted from the five inventories.
- [ ] Produce `features/feature-inventory.md`, `features/usage-matrix.md`,
      `features/loc-reduction.md`, and `features/features.json`; measure physical
      LOC without double counting shared modules. Distinguish predicted savings
      from measured change and moving code from removing it.
- [ ] Produce `synthesis/verified-claims.md`, `problem-map.md`,
      `contradictions.md`, `rewrite-requirements.md`, and `open-questions.md`.
      Tie idle-gap explanations to measured evidence, not structural guesses.
- [ ] Audit all eight research questions in README against concrete evidence.
- [ ] Run CE brainstorm, plan, and deepen-plan; write requirements and a
      detailed evidence-linked plan under `docs/brainstorms` and `docs/plans`.
- [ ] Commit and push incremental research; verify remote head directly.
- [ ] Final requirement-by-requirement audit before completing the goal.

## Publishing

Keep the working research directory and selected branch artifacts synchronized.
The inherited `sync.sh` hides push failures with `|| true`; do not use its final
log line as proof of publication. Commit explicit research paths and check the
actual push result and remote branch SHA. Do not copy scratch directories.
Do not change the live main checkout or the shared release directory.

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

## Label/state contract checkpoint

Read ten source files at the relevant lifecycle spans and recorded contracts in
review/in-progress/label-state-contracts.json. Reconciliation now covers eight
selected inherited findings. The agent-backends-cc-38 recommendation to derive
agent permissions by subtraction is rejected: it leaves the canceled alias
authorized and grants future vocabulary additions by default. Preserve a positive
authorization policy separate from vocabulary, precedence and provenance repair.

agent-runtime-23 source differences are corroborated, but summary producer
reachability for custom-prefix terminal tags/string work states remains open.
Canonical GitHub ingestion already strips configured prefixes; differing helper
normalizers alone do not prove an ingestion bug. CILifecycle nil-state comments
are stale relative to the current contradiction resolver. Remaining concept and
constant sweeps, final reconciliation and all other completion gates stay open.
No production changes or runtime verification were performed.

## Summary producer trace and helper probe

Traced StatusReport -> State.issue_tag -> AgentEvents -> AgentPubSub ->
AgentList.App -> Roster -> Summaries. State.issue_tag selects the first literal
agent: label, including markers; custom-prefix-only input yields nil, which
AgentEvents removes. Fixing only the UI filter cannot repair that projection.
Prefer canonical issue state separate from display labels and override markers.

The isolated tooling/label_state_probe.py compiles exact frozen pure helper
slices and Summaries without Mix or a daemon. Two runs produced identical
review/in-progress/label-state-probe.json: default done hidden, custom done
visible with absent tag, watch-before-done visible, reversed order hidden; string
paused predicates true but sorts after atom paused despite lower identifier.
These synthetic inputs demonstrate helper behavior, not production incidence
or manual TUI verification. Candidate retention and a string-producing runtime
path remain open; idle producer states are atoms and running status is forwarded.

## Constant census checkpoint

Parse-only tooling/constant_census.exs found 2,112 non-documentation attribute
assignments in all 1,032 frozen src/lib Elixir files; 835 have literal arithmetic
values under the restricted evaluator. All source hashes match the existing
function census. Two full runs were byte-identical. The synthetic fixture covers
arithmetic, symbolic calls, division by zero, regexes, nested modules and quoted
code exclusion without evaluating project code.

review/in-progress/constant-census-summary.json preserves every site in 80
cross-module numeric groups and 82 symbolic expression groups. These are
candidates, not reviewed duplication findings. Equal numbers span units; equal
__MODULE__ expressions resolve to distinct modules. Inline numbers/string keys/
regexes outside attribute assignments remain outside this census. Semantic
constant review and the final duplication unit are still unfinished.

Reproduce with Elixir 1.19.5 / OTP 28: elixir tooling/constant_census.exs
/path/to/snapshot, then python3 tooling/constant_census_summary.py census.json.
Run python3 tooling/test_constant_census.py with that Elixir on PATH. No Mix,
release rebuild, daemon interaction or production changes occurred.

## Usage constant semantics checkpoint

Four of 162 constant candidate groups assessed in constant-triage.json: the
five token dimensions, three existing six-field derivations, and paired context/
cache-duration vocabularies. This partially corroborates telemetry-usage-34;
its map-access and exception-class claims remain outside the check.

Preserve dimension order (all-zero alternative selection uses it), reported-total
raw measurements separate from priced dimensions, nullable checkpoint partitions,
and provider/component admission rules. CodingAgent carries an additional inline
Claude duration list outside the attribute census. A shared Usage.Dimensions leaf
is supported, but a global vocabulary must not automatically widen provider
permissions. Source hashes match the frozen census. No production changes,
pricing-rate audit, runtime tests or savings claim. Remaining 158 candidate groups
and the inline constant sweep stay open.

## Inline regex and identity constants checkpoint

The parse-only regex census covers 326 sigil sites and 28 cross-module
syntactic groups across the same 1,032 hashed source files. It includes inline
uses, preserves flags and skips quoted generated code. Fixture checks and a
second full run matched. Dynamic Regex.compile strings remain excluded.

Six attribute groups are now assessed (156 remain), plus two overlapping regex
groups. Currency parsing has three sites, including inline Aggregate.Key; shared
grammar does not share error envelopes or explicit UTF-8 prechecks. Decimal
string grammar has two sites, but ExactMoney accepts additional numeric forms
and minor-unit conversion. Do not replace whole decoders with one another.

All eight __MODULE__ attribute sites use distinct module identities for ETS or
persistent_term; identical source text is not one repeated storage value.
Sources and references were inspected; no production changes or runtime
behavior guarantees are claimed. Reproduce regex census with elixir
tooling/regex_census.exs /path/to/snapshot; fixtures use
python3 tooling/test_regex_census.py. Semantic review of remaining regex groups
and the broader numeric/string-key sweep remain open.

## Regex candidate assessment checkpoint

All 28 cross-module sigil groups now have source-consumer assessments in
regex-triage.json, with every listed site inspected and source hashes matched.
This completes the generated regex candidate assessment, not the constant unit.
Dynamic Regex.compile strings and broader numeric/key analysis remain open.

Existing owners support reuse for EnvRef dollar-reference recognition and
Config.Paths filename sanitization. Git/Init origin parsing matches, while
RepoBase retains additional path safeguards. Shared request attribution must
preserve atom/string output boundaries. Identifier hashing, rejection, redaction,
length limits, topic identity and nil policies remain distinct. Terminal scrubbing
replaces the same controls other validators reject; diff display preserves leading
spaces that generic single-line display can discard. No production code changed.

## Storage bounds and framework constants checkpoint

Nine of 162 attribute groups assessed (153 remain). Confirmed six u64 bound
literals, including the inline aggregate checkpoint site absent from attribute
census. Existing Record.bounded_integer? reuse narrows the extraction proposal;
positive positions, nonnegative generations/counters and error envelopes differ.
This partially corroborates telemetry-usage-22, not its whole persistence proposal.
RetiredFloor.write permits nonnegative integers without its loader ceiling;
caller reachability/runtime effects remain unverified, so no incident is claimed.

All 28 false-valued attributes are local embedded-schema primary-key declarations.
All 15 Aiur.PubSub attributes reference a shared transport; separate event topics,
payloads and failure semantics should not be collapsed because names repeat.
Declaration/reference contexts and frozen hashes were checked. No production
changes, runtime tests or savings claims. Regex candidate review remains complete
within its bounded syntax census; broader constant and concept sweeps remain open.

## Provider contract constants checkpoint

22 of 162 attribute groups assessed (140 remain). Thirteen additional groups
cover registry-derived providers/backends, telemetry source ownership, build
version metadata, pinned usage relationship revisions and measurement/auth enums.
Fully qualified and aliased CodingAgent calls share one owner; they are not
independent provider lists. Event and UsageAdapter already use Contract.source.

Identical Codex definition-map syntax resolves distinct thread/turn source and
relationship identities. Full adapters confirm absolute/thread versus delta/turn
observations and different source-event fingerprints. Keep those distinctions.
Meter subscription and retained usage chatgpt vocabularies are separate, with
explicit rate-limit conversion. Historical pricing relationship revisions must
not silently follow a mutable latest source version. Source hashes matched; no
production changes, current pricing audit or runtime verification claimed.

## Lifecycle and presentation constant checkpoint

39 of 162 attribute groups assessed (123 remain). Seventeen groups cover
control request state, membership lifecycle, decision authority/open status,
workflow stages, UI reason sets, marker labels, alert suffixes and command topics.

Keep one-state fleet classification separate from overlapping UnitsPolicy
conditions. Membership vocabularies match while evidence precedence differs.
Shared route status sets support the existing Build Order extraction proposal
without merging analytics/usage member identities. AlertTopic trims repeated
resolution suffixes while AlertFeed removes one and rejects empty remainder;
matching suffix text does not make their functions interchangeable. Executor
command topic classification is shared between sanitization and optional alerting
and needs coordinated ownership. Source references/hashes checked; no production
changes or runtime incident claims. Remaining constant/concept work stays open.

## Config layout and process identity constants checkpoint

57 of 162 attribute groups assessed (105 remain). Eighteen additional groups
cover init filenames and guidance, endpoint vocabulary, label defaults, bot
suffixes, framework declarations, struct requirements and process identities.

Generated prewarm references and the written basename are one contract. Config,
alerts and legacy paths share vocabulary while preserving local/global roots.
Transport already exposes GitHub endpoint accessors; any reuse must respect cache
layering. Equal registry/key expressions expand to different module identities.
Readiness detection and a local prompt cursor must not share styling policy.
Schema and wizard bot validation, and configured versus missing-only label
defaults, are not interchangeable. All listed source hashes matched the census.
No production edits, credential reads, external URL verification, runtime tests
or savings claims. Broader constant and concept sweeps remain open.

## Symbolic constant candidate assessment checkpoint

All 82 symbolic attribute groups now have source-consumer assessments. Including
the u64 numeric group, 83 of 162 groups are assessed; 79 numeric groups remain.
This completes only the generated symbolic candidate set, not the constant unit
or the broader inline/key/timeout sweep. Source hashes matched the frozen census.

Shared contracts include marker vocabulary, supervisor actor identity, usage group
dimensions, telemetry metrics/evidence and carried point-event identities. Existing
TurnMarkers and GraphqlCost accessors already own part of the duplication. Preserve
strict marker routing versus broad synthetic filtering, nested raw telemetry versus
flattened summary decoding, and repeated authorization checks at delivery boundaries.
GitHub display order differs from first-hold dispatch order; provider effort
admission is not automatically widened by global override vocabulary. Three equal
15-minute values govern unrelated re-ask, freshness and sweep policies. No production
changes, live-system verification, quota saving or package-boundary completion claimed.

## Numeric units and small candidate groups checkpoint

99 of 162 attribute groups assessed; 63 numeric groups remain. Sixteen additional
two-site numeric groups were inspected against declarations and consumers.
The 2048 URL values differ in byte versus character units and validation; nineteen
digits do not equate positive issue identity with bounded nonnegative int64.
ResourceStore's 100000 threshold sheds bodies rather than imposing a hard key cap.

Schema/Budget defaults for GraphQL allowance and request staggering should agree.
Display/history bounds and chart geometry may share local policy while retaining
redaction, eviction bookkeeping and layout semantics. Equal delays, counts and
retention durations alone do not support extraction. Source hashes and targeted
publication checks passed. No production changes or runtime verification.

## Numeric payload and timing policy checkpoint

121 of 162 attribute groups assessed; 41 numeric groups remain. Twenty-two
additional groups cover payload/storage limits, display counts and timing defaults.
Aggregate checkpoint write/load/recovery defaults form a shared 32 MiB contract;
compaction blocks are a separate format. Membership storage already consumes Codec
limit accessors. Issue-list response limits and Executor-message admission bounds
each contain a related subset among otherwise unrelated equal values.

Keep bytes, text lengths, sample rates, ticks and durations distinct. A post-return
System.cmd output-size check does not establish bounded capture allocation. The
OpenAICompat counter-array slot count is not a concurrency cap. No live performance,
filesystem atomicity or external-service guarantees were inferred from source
comments. Hash checks passed; no production changes. Broader sweeps remain open.

## Numeric cadence and conversion checkpoint

133 of 162 attribute groups assessed; 29 numeric groups remain. Twelve groups
cover timing relationships, binary units, pagination, pricing units and defaults.
Legacy pagination admission bounds and per-million pricing units are separate
shared contracts despite equal numbers. Schema/Budget defaults should be shared
per field, not across independent Core/GraphQL/search dimensions.

Related stream inactivity safeguards observe different timestamps and perform
different actions. SnapshotStore already uses PollCadence; preserve default,
floor and derived-formula semantics. DeliveryLog's 512-byte prefix plus digest
is not a 512-byte stored-key maximum. Port line framing is not a total response
size bound. Hashes checked; no production changes or live timing claims.

## Numeric admission and streaming checkpoint

142 of 162 attribute groups assessed; 20 numeric groups remain. Nine groups
cover 250, 10, 128, 120, 15000, 32, 65536, 20 and 60, retaining every listed site.
Ticket search input/server bounds form a shared policy, without proving browser
and Elixir Unicode counting equivalent. Streaming file digest mechanics can be
shared without turning chunk size into total-input admission policy.

Keep bearer-token minimum size separate from SHA-256 digest size; UI counters,
telemetry cardinality and storage cadence are distinct. Schema/Budget defaults
remain per-field contracts. Source comments preserving REPL dependency direction
are evidence to weigh before extraction, not grounds to invent a shared module.
Source hashes/publication checks passed; no production changes.

## High-frequency numeric contract checkpoint

152 of 162 attribute groups assessed; ten numeric groups remain. Groups indexed
10 through 19 now retain source-consumer assessments for every listed site.
Decision identity limits mix character and byte units; equality of 256 does not
establish validator equivalence. Usage polling fallbacks repeat the inline schema
300-second default; reset-delay defaults belong to a separate schema field.

Usage drill pages and legacy pagination have shared admission contracts. Preserve
protocol request IDs, distinct retry/exhaustion semantics, financial pending-waiter
bounds and chart overflow bars. Counts, time units and schema defaults should not
be combined solely because they share a number. Source hashes and targeted privacy
checks passed; no production edits or runtime correctness claims.

## Numeric retries and effective freshness checkpoint

156 of 162 attribute groups assessed; six numeric groups remain (indices 0–5).
Four further groups cover minute/five-minute policies, fifty-item bounds and
three-valued protocol/retry/count sites. TicketHistory uses PollCadence: its
five-minute input cap is not a cap on effective freshness. Tail API admission
and IssueLog byte budgeting share the fifty-record page contract.

Keep retry exhaustion, one-time escalation and correlation IDs separate. Existing
DecisionStore timeout ownership, Normalizer history-limit accessors and cadence
derivation narrow extraction proposals. Hashes and targeted publication checks
passed; no production changes or runtime incident claims.

## Version and small-count contract checkpoint

158 of 162 attribute groups assessed; four numeric groups remain (indices 0, 1,
2 and 4). The one/two groups retain all 73 listed sites. Most format versions
are independent, but membership Event/Codec share a wire version. Dashboard
FinancialDataAccess and StreamdeckAuth also share an access-version contract:
Proof includes version in the configuration fingerprint, and the singleton
Generation owner rotates when that fingerprint changes. Preserve this alignment
during extraction; no current version mismatch or runtime incident is claimed.

Two-result branch-PR query bounds and schema/Budget endpoint defaults are
specific shared policies. Freshness intervals, observed-gap multipliers,
failure streaks, request IDs, display rounding and storage versions remain
distinct. Existing PollCadence ownership narrows extraction proposals. Source
hashes checked; no production changes.

## Attribute candidate assessment complete

All 162 cross-module attribute candidate groups now have source-level assessments
(80 numeric, 82 symbolic); the four final groups retain all 175 listed sites.
This completes candidate triage, not the broader duplication-by-constant review:
inline strings/keys, remaining semantic sweeps and synthesis remain open.

DecisionMetrics collector/writer defaults and telemetry sampler/gap-analysis
cadence are specific shared contracts. Preserve independently supplied options.
RPC diagnostic truncation uses String.slice despite a max_log_bytes name;
byte-prefix logging and character truncation must not be conflated. Root/member/
connection bounds and cache-age/operation-timeout policies remain distinct.
Hashes and targeted publication scans passed. No production edits, live-system
claims or savings estimates were introduced.

## Body duplication raw-unit checkpoint

Published review/raw/dup-by-body.json: 60 P2 refactor opportunities, 242 unique
files inspected at candidate spans, all 169 reviewed exact/renamed/extra groups
accounted for in a disposition index. The scope is the detector's >=5 physical
and normalized-line population, not arbitrary semantic clone detection.
Each promoted family carries all its candidate sites, source-group hashes and
contract caveats; retained candidates keep their assessment.

All 1,032 source hashes rechecked. Location bounds, finding IDs and evidence
references validated. Raw review units advance to 25/32 and raw findings to
929; inherited high-severity skepticism and cross-unit deduplication remain
open. No production changes or independent savings claim.

## Deployment-surface audit checkpoint

Meta-08 remains open. Added source-hashed deployment-surface-audit.json and a
matrix in deployment-verification.md distinguishing invoked-release --version,
npm-channel upgrade notices, restart receipts and the installed-upgrade liveness
guard. Dev notice suppression is explicit; --version is a one-shot launch,
whereas status uses control RPC. None of these alone compares running dev code
with upstream main or protects every instance sharing release artifacts.

Historical handoffs located and selectively read; appended updates mean filename
timestamps cannot bound episodes. Remaining: complete status/dashboard identity
surface audit and historical duration/restart-side-effect verification. Claim
coverage stays 50/60. No live launcher, upgrade, release or daemon action.

## Deployment historical-episode checkpoint

Added deployment-episodes.json with nine public-source hashes and six bounded
episode assessments. Corrected the PR2677 timeline anchor: commit-to-completion
report is about 10h25, while first read merged/undeployed observation-to-report
is about 10h23; neither proves the exact activation timestamp. One reported
21 KB loss/restoration is repeated through six handoffs, not six incidents.

Earlier records support reported activation gaps but not all asserted duration
or authority interpretations. Twelve restarts/backups, retry-reset mechanism,
four repeated bugs and remaining build-identity surfaces are still unresolved.
Meta-08 stays open and claim count stays 50/60. No operational state changed.

## Decision restart contract checkpoint

Source and existing test inspection confirms process-local retry counters reset
on DecisionStore boot, and fenced boot reconciliation can dispatch an active
transiently failed answer again. Durable attempt history and numbering survive;
missing/resolved/moot/inapplicable answers are excluded. New-worker budget reset
is a separate deliberate path. See decision-restart-contract.json for source
hashes, exact ranges and explicit source-only verification limits.

No test or daemon executed. The September 17 deployed revision and incident
frequency remain unverified; a targeted search did not locate the twelve-
restart claim, which remains unresolved. Meta-08 is still open, 50/60 claims.

## Meta-08 bounded verdict checkpoint

Both lenses reject meta-08 as written. The corrected claim distinguishes
automatic dev builds, existing npm notices and restart receipts from the absent
comparison in inspected standard status/snapshot/presenter paths. Historical
33fa9920 source confirms retry-map reset, with guards differing from frozen HEAD.
Historical incidence is not inferred from source or copied handoffs.

Twelve restarts/backups, four repeated bugs, exact activation times and raw WIP
loss mechanism remain explicit unsupported subclaims in the verdict. They are
not measured findings or projected savings. Claim lens coverage is now 51/60;
this does not resolve those questions or complete the research. No live changes.

## Meta-10 merge and wake checkpoint

Merge-review-evidence.json independently calculates 45,909 seconds (12h45m09s)
between cached PR2677/2681 merges, consistent with frozen first-parent Git
history. Four cited PRs have approval records and no merge in the extract, but
that cache lacks review commit IDs/current heads/checks: approval history is not
proof of continuing merge readiness. Replacement PRs2685/2701 are recorded as
merged; semantic equivalence is still unverified.

Frozen default Executor bindings already include ticket.*.branch.push, with
ls-remote producer, ticket-ref mapping and listener inbox path. Blanket absence
of push wakes is false; historical delivery/consumption remains unproved.
Two PR2645 body copies repeat an integration account, so file/paragraph counts
cannot stand in for a reintegration event census. Meta-10 remains open;
51/60 claims, 25/32 review units. No operational mutations.

## Meta-10 Git integration census checkpoint

Added tooling/integration_records.py and synthesis/integration-records.json.
Twenty-one structured receipts across seven PRs resolve to distinct two-parent
merges with second parents on frozen main. Their first-parent ancestry contains
38 distinct accepted-main integrations in the explicit September 16–18 search
window (actual commit timestamps September 16 19:52:57Z–September 17 02:43:39Z).
This is a bounded sample, not the original 12-PR/27-hour census or actor proof.

One receipt's reported prior differs from its merge first parent (PR2644,
c1fdadb versus 29646bb); ancestry is valid and the mismatch remains explicit.
Reported unchanged booleans agree with Git; the CLI page is the one changed
reported footprint in the 33fa wave. Footprint completeness remains unproved.
Historical test reports are not reruns or fresh mutation evidence. Repeated
execution of the census produced identical JSON. No runtime operations.

Next: finish actor/conflict/green-check evidence and earlier backlog samples,
compare replacement-fix semantics, then close both meta-10 lenses with bounded
claims. Coverage remains 51/60 and 25/32; all broader goal work remains active.

## Meta-10 bounded verdict checkpoint

Completed both lenses with a rejection of the compound claim as written:
repeated integrations and reported review backlogs are supported, but universal
serial review, missing push wakes and a measured wasted-effort fraction are not.
Eight concurrent reviewers are recorded. Earlier/later probe fixes overlap;
the later GitHub-support fix also adds dispatch/per-turn and queue-restoration
checks beyond the earlier refresh repair. See review-backlog-and-replacements.json.

Corrected Rank 3, the mechanisms table and timeline. Historical counts remain
reported snapshots; the ten-PR starting anchor, complete integration/actor/
conflict population and five-green-PR invalidation remain explicit unresolved
questions. The skill's seventeen-PR episode itself identifies existing push
signals ignored by the Executor. No new wake mechanism is justified by absence.

Claim lens coverage is 52/60; review units remain 25/32. Next claim work:
codebase-07, gaps-01/03/04/05/06/07 and meta-07. Remaining review, duplication,
feature challenges, skeptic pass, final synthesis and CE planning still pending.
No runtime changes or production test claims.

## Gap source and uptime contract checkpoint

Added gap-progress-coverage.json/tooling/gap_progress_coverage.py: the omitted
architecture-docs GitHub cache has 3,537 qualifying records but zero strictly
inside retained >=30-minute gaps; repeated output is identical. No ratio change
from this omission alone. All three flagged run directories resolve to khala
and already exist in the retained model.

Added gap-uptime-contract.json: historical IdGenerator reservation recovery
contradicts treating event_id // 1000000 as a guaranteed boot identity. The
analyzer's claimed two-hour observed-up bound is also absent from execution.
Source-rule arithmetic demonstrates a restart preserving the quotient; no
runtime reproduction or corrected denominator claimed. Progress counts matched
Bash calls without success checks. Gaps-01 remains open for final verdict and
report correction; coverage still 52/60. This is a major synthesis caveat.

## Gaps-01 bounded verdict checkpoint

Both lenses reject the compound headline uptime claim. Also found a denominator
mismatch: original run-span sum 963.0758 h includes 1.1361 h overlap, whereas
gap construction uses per-repo unions totaling 961.9397 h. The compatible model
ratio is 75.6527%; neither ratio proves continuous uptime or wasted time.
The original audit fields remain provenance; new fields name the union ratio.

Corrected report definitions and headline; completed claims-gaps-headline.json.
Coverage is 53/60. Remaining claims: codebase-07, gaps-03/04/05/06/07, meta-07.
Lifecycle reconstruction and complete source coverage remain explicit open
questions, not silently declared accomplished. Broader goal remains active.

## Prewarm versus starvation checkpoint

Added prewarm-starvation-history.json with source/diff hashes and cached merge
timestamps. August 21 PR2242 disabled prewarm alongside identity/sandbox changes;
the #2237 code repair PR2274 merged August 23 20:06:53Z. PR2434 debounced alerts,
and PR2449 addressed load-ramp/decision-blocked false alarms. These are distinct
mechanisms; no deployed-version or non-recurrence proof is inferred.

The cited ID group contains 71 blocked records and 70 resolutions, forming
70 ordered pairs plus one open block (median 10.11 min, range 5.15 s–40.22 min).
It is not a verified single boot. The claimed healthy interval has three
retained gaps totaling 1.9503 h, all before the code-repair merge; it begins at
the disable-prewarm mitigation. Report wording corrected accordingly.

Gaps-03/05 remain open: primary diagnosis, causal population and later exposure
still need evaluation. Claim coverage stays 53/60. No operational changes.

## Gaps-03/05 bounded verdict checkpoint

Both compound claims rejected with supported point diagnosis and merged repair
preserved. Successful historical tool results name prewarm checking, zero live
agents and 31 ready tickets; the analyzer hard-codes load-governor from the topic.
Pre-log aiur d 257.2 h / 282.9167 h=90.91%; all-prelog d 273.0667 h / 316.0333 h=86.40%.
These are distinct populations and cannot measure one defect's causal cost.

Later Aiur wake records after repair merge exist (197 prewarm blocked/194 resolved,
36 fleet-starved/27 resolved), but merged source, effective config and loaded
revision remain separate. No non-recurrence claim. Primary transcript evidence
is hashed/paraphrased without raw publication. Verdicts and report corrected.

Coverage 55/60; remaining codebase-07, gaps-04/06/07, meta-07. Review 25/32,
remaining feature challenges/skeptic checks/synthesis/CE planning unchanged.

## Gaps-04 bounded verdict checkpoint

Largest retained gap 151.3621 h; three August 25 gaps sum 173.2840 h, enclosing
span 173.7544 h includes 0.4704 h outside them. Raw attendance 0.004 rounded 0.00,
so no zero-activity/operator-absence inference. Independent cached label replay
finds 12 human-review issues, 5 rework, 1 paused, 3 ci-wait, 1 todo (#2394); the
todo already had open PR #2396. Labels do not establish scheduler eligibility.

The d label follows inferred eligibility plus an unresolved infrastructure
window ahead of human-waiting state. Missing refusal evidence is not admission,
and future declines are back-projected across label episodes. Both confident
infrastructure allocation and automatic reassignment to b are rejected.
See largest-gap-attribution.json and claims-gaps-largest.json.

Coverage 56/60; remaining codebase-07, gaps-06/07, meta-07. No production changes.


### Dependency claim continuation: September 25 evidence

Canonical synthesis/dependency-gap-evidence.json now records exact wake counts over the report minute window: 40 operator-decision, 39 usage-limit, one paused-agent request. Retained alerts.tsv has 193 candidate declines for this run (181 dependency, nine unauthorized, three decision blocked), but none inside 12:08–21:59. Original analyzer backprojects declines across label-state episodes; 59/60 is not a contemporaneous count. Current live alerts file differs from retained extraction. Existing IssueSync circular-wait alert is narrower than a whole-backlog summary. Still finish historical graph/closure replay, exact interval bounds and eight-review-root attribution before final gaps-06 verdict. No production changes.


### gaps-06 verified with corrections

Added both-lens verdict and corrected gap rows 4/10 and refactor implication. Exact September 25 graph replay finds 60 todo, eight review; all todo have open/unresolved dependencies. External frontier: seven review issues, paused 41, in-progress 201, parked 236, unresolved external 2786. Extracted timeline lacks external blocker edges and scope; do not claim complete root census. 59/60 was episode-level decline classification, not contemporaneous gating census. Exact interval 9.8374267 h and 40/39 attentions retained. Remaining claims codebase-07, gaps-07, meta-07.


### gaps-07 host interruption evidence in progress

Canonical synthesis/host-downtime-evidence.json captures journal/wtmp and unit inspections with private raw outputs under scratch/host-downtime (0600). Last old journal 15:41:37Z precedes public daemon final telemetry 15:42:04.538694/15:42:07.331273Z, so do not call it exact crash time. Current units include enabled Stream Deck with restart-on-failure, no named daemon unit; historical supervision remains unknown. Frozen launcher has a BEAM-death crash-recording/reaping watchdog but no restart action. Finish run identity/notification/absence scope and claim verdict; do not publish raw host journal or host identifiers.

Restart timing uses explicit daemon_restart.attributes.daemon_started_at, not minimum event timestamp: the new run includes replayed September19 lifecycle timestamps. Verified daemon start September24 18:48:04.293177Z, 77.2216 minutes after first host journal and 51.0999 hours after last Khala telemetry.


### gaps-07 verified with corrections

Added both-lens verdict and corrected downtime report. Six identified Khala runs plus three brief telemetry-only streams after boot through original cutoff; no identifiable Aiur restart, not exhaustive nonexistence. 51.0999 h last telemetry to explicit restart; 77.2216 min first host journal to restart. Journal endpoint is not exact crash time. Existing launcher watchdog records/reaps without restarting. Historical configuration, external delivery and operator awareness remain unresolved. Remaining claims codebase-07 and meta-07.


### codebase-07 routing probe continuation

Updated canonical attention-routing-audit.json with actual frozen Elixir matcher/projection execution: 14 membership samples reproduced; pause-attention matches, appended .resolved does not. needs_attention true/false survives projection but does not route; severity omitted from wake record. Listener default options can be overridden. Skill 24-vs-26 text drift confirmed; eight-alternative jq is downstream relay filtering, not another daemon binding policy. Workspace watch explicitly documents central-alert exclusion/backstop. No full emit-site or alternate-path census yet; next finish bounded claim verdict/report correction rather than treating grep counts as condition reachability. Scratch probe requires only three pure modules, not application startup.


### codebase-07 verified with bounded corrections

Added both-lens verdict and corrected report summary, routing section and carve-order recommendation. Actual 14-topic matcher/projection probe confirms pause-resolution mismatch. Reject condition invisibility inferred from unbound topic; generic pause alert can route. Do not route only needs_attention=true: false resolution and successful control events matter. Full emit-site/alternate-path census and operational incidence explicitly unresolved. Remaining claim meta-07; reviews/features/synthesis/planning still incomplete.


### meta-07 CI-wait evidence in progress

Canonical dispatch-state-evidence.json records #165 bundle: resume returns explicit no_agent_work_state; status has 77 issue rows, 35 explicit dependency declines, no #165 row, and 16-second stale warning. status-full is command error, not full status. Timeline enters ci-wait 00:52:51Z; capture-directory timestamp implies 64m17s, not independent command timing. Inspected historical 7dd56fc CiLifecycle: poll targets and token-correlated fallback exist; fallback updates tracker to in-progress before reactivation. Thus no recovery route/no decline surface blanket claims fail, but actual historical recovery failure and later episode/fix counts still need investigation.

#165 continuation: cached public label events prove ci-wait 00:52:51→01:57:19Z (64m28s), ended by operator human-review transition. Bundle telemetry-165.ndjson contains ZERO exact ticket165 rows (25 ticket166 resource rows among40). Full run telemetry exact-filter yields103 ticket165 records in00:45–02:00 (99resource,4lifecycle), lastresource00:53:12; ownershiprelease00:53:16, reviewpause01:58/01:59 after operator intervention. Evidence corrected in dispatch-state-evidence.json; do not use bundle filename as attribution. Later reports located in scratch/slice-S7.md, original rolling handoff no longer contains them.


### meta-07 verification checkpoint; all60 claims have verdicts

Added bounded final claim verdict and corrected report/timeline. Later operator-ended CI-wait intervals: #367 2h1m50s, #350 3h33m8s, #232 5h2m25s; green-current-head/timer/deployed-runtime causality remains unproved. Historical CI lifecycle equals frozen source and has recovery paths. Citation/fix totals remain reported, not independent recurrence counts. 60/60 verdict coverage is NOT research completion:25/32 review units, high-priority skeptic pass, duplication, feature challenges, report-wide reconciliation, synthesis and CE planning remain.


### Test-review continuation started

review/in-progress/tests-1b.json records four full reads (bindings48, listener318, projection154, command-attention81 lines) with hashes. One provisional P2: attention open/resolve callback tests and listener PR/capacity tests do not compose resolution into inbox, so actual default wildcard mismatch escapes this group. Need broad suite cross-reference before promoting. Preserve existing replay/barrier/persistence/trust tests. No suite run or production changes. Remaining units unchanged25/32. ce-code-review inspected for applicability; this is the inherited whole-snapshot research audit, not a new diff review pipeline.


### tests-1b twelve-file checkpoint

Twelve full reads now recorded with hashes: added ExecutorCommandCLI and membership event/projection, DecisionAuthority/Delegation/dispatch saturation/tasks/PubSub. Broader resolution cross-check found AlertFeed/DecisionStore and direct Exchange tests, not proof of keyed resolution delivery through default ExecutorListener. Preserve strong payload, authority, identity, replay and dispatch-ordering contracts. Zero-timeout concurrency ceiling assertion is only a hypothesis pending deterministic mutation; do not promote as proven. No runtime test execution.


### tests-1b twenty-file checkpoint

20 full reads with hashes. Added concrete P2 oracle defect: JsonStore concurrent-read test filters away error tuples. Actual extracted assertion probe passes all10 errors and mixed errors, fails malformed success as control. tooling/json_store_oracle_probe.exs runs with frozen snapshot argument; no production mutation or suite run. Preserve symlink boundary and boot-log isolation checks. Pending env-inventory dynamic/bang-read hypothesis is unverified. Raw-unit count remains 25/32.


### tests-1b thirty-four-file checkpoint

34 full reads now recorded with hashes. Resource, supervision, memory, progress retention, journal, boot isolation, token usage, webhooks and YAML contracts retained. Added verified local policy-test gap: unchanged GitHubBodyFilePolicyTest passes an unstaged inline-body violation and fails it after staging (2/0, 2/0, 2/1 tests/failures). Portable disposable-repository probe added; this is not a clean-checkout CI blind spot. Initial probe launch failed because the temporary directory had no mise Erlang selection; explicit Erlang bin PATH resolved it without modifying host configuration. No production changes or application boot. Raw-unit count remains 25/32.

Added four more full reads: qualified identity/observation, decision-metrics restart and HTTP bind collisions. tests-1b now38/75 files, 4202 lines; no new promoted finding. Retain subscription-before-replay barrier and characterization/regression distinction.


### tests-1b forty-five-file checkpoint

45 full test-file reads,6188 lines. Added shutdown/provider/workflow/revision/coordination/disposition/durable-state contracts. Isolated unchanged ProviderMeterRefreshTest:16tests,0failures; spawn tracing proves one unlinked helper remains sleeping after success. Recorded P3 and portable probe, which cleans that helper. No full application boot; missing optional modules produce expected compilation warnings and default-config fallback. Initial attribution by initial_call missed erlang.apply; spawn-fun module tracing corrected the probe. RepoBase/BuildGate combined output was truncated and is NOT counted as a full read. Coordination infinite-timeout test deadline coverage remains a hypothesis. No production changes.


### tests-1b timeout mutation checkpoint

46 full test reads,6459 lines. Confirmed infinity-timeout oracle hole: original targeted test passes baseline and a resolver mutation replacing infinity with20ms; guarded80ms hold passes baseline and fails mutant on premature successor. Portable AST-extraction/in-memory mutation probe added. Initial probe used recursive prewalk insertion and hung two disposable VMs; terminated those exact processes and changed to postwalk, then all four expected outcomes completed. No production edits. ProcessReaper full review preserves injected-kill and PID guard contracts; draining late-registration test only exercises an unreadable dead PID, not a real kill. Broader mutation coverage remains incomplete.


### tests-1b fifty-five-file checkpoint

55 full test reads, 8929 lines. Added Units/Analytics CLI, Upgrade, AgentEvents, PauseContainment, WorkspaceMaterialize, GitHubAuthPreflight, Codeowners and DecisionMetrics. Preserved explicit unknown/empty/stale/partial envelopes and rendered ages, exact time windows, channel-safe notices with counted transport calls, local-Git freshness/PR-head fixtures, quota-unknown authority and canonical metrics provenance. No new promoted finding. Pause failed-reap completion coverage is a hypothesis because paused is already true before fallback completes. New files were read, not executed; no production changes.


### tests-1b sixty-two-file checkpoint

62 full reads,12006 lines. Added process logging, tmux, pane manager unit/live geometry, queue, firehose and duration watchdog. Confirmed negative-assertion arity hole in refused resume: actual two-element assertion passes with a three-element generation-aware message; corrected control fails. Portable assertion probe added. This does not prove a production cap bypass. Preserve claim/provider-ack separation and distinguish mocked commands, geometry integration and real chat UX. No new test suite or live tmux execution; no production changes.


### tests-1b sixty-eight-file checkpoint

68 full reads,16372 lines. Recorded prior GitHubCostCLI, CLI, AgentRunner, AgentLog and Application reads plus DecisionApi. Preserve budget observation provenance, backend-specific recovery, transcript fallback, supervision order and canonical API privacy/pagination/authority contracts. No new promoted finding; no new suite execution. Remaining seven files: agent_control_cli, agent_github_guard, build_gate, coding_agent, init, live_conversation, repo_base. Raw-unit completion remains 25/32; no production changes.


### tests-1b seventy-one-file checkpoint

71 full reads,20055 lines. Added CodingAgent, LiveConversation and RepoBase. Confirmed phase-order oracle gap: exact four selective receive assertions pass reverse arrival order; an order-sensitive control fails. Portable assertion probe added; no actual out-of-order production emission alleged. Preserve provider capabilities, bounded private conversation projection, migration recovery and dead-versus-live prewarm watchdog contracts. Initial probe-writing command had a Python quoting syntax error and made no artifact; corrected writer and isolated probe succeeded. Four test files remain: agent_control_cli, agent_github_guard, build_gate, init. No production changes or full-suite execution.


### tests-1b seventy-three-file checkpoint

73 full reads,25471 lines. Added Init and BuildGate. Confirmed background-descendant fixture identity defect: $$ records the parent PID, so the cancellation test checks the parent twice and fallback cleanup targets it too. Actual fixture writer extracted via AST; added BASHPID observation proves a distinct live child. Released child and removed temporary probe files. Initial attempt exhausted temporary-filesystem quota before spawning; explicit research scratch root succeeded. Portable probe added, no production containment failure alleged. Preserve setup consent/scope and build admission/retention/ownership boundaries. Two files remain: agent_control_cli and agent_github_guard. No production changes or full-suite execution.


### tests-1b seventy-four-file checkpoint

74 full reads,29523 lines. Added AgentControlCLI plus TestSupport lines1-390 as an excerpt. Preserve wake claim/ack failure semantics, bounded todo cleanup, daemon-owned admission causes and sample ages, generation-correlated resume confirmation, unknown outcomes and retry identities, and watch resolution/change behavior. Existing watch resolution test consumes a supplied ledger and does not close the default listener routing gap. TestSupport is serial and supplies per-case durable roots; do not infer an async race from this module mutating globals. One combined read was output-truncated; reread lines950-1070 recovered the omitted boundary before counting full coverage. Only agent_github_guard remains. No new promoted finding, suite execution or production change.


### tests-1b GitHub guard partial checkpoint

Read AgentGitHubGuard through line 2700 of 5764 (lines 501-2700 newly inspected in this continuation); 74 full files and 29523 full-file lines remain the completed count. Remaining lines 2701-5764 include helper implementations that must be inspected before promoting timing/fixture concerns. Preserve write-authority and provenance boundaries, credential-local accounting, per-page admission, replay isolation and non-billable-but-paced probes. Native gh replay tests are distinct from canned formatted-output fixtures; neither is a new live GitHub billing census. Migration test's marker-plus-settle interleaving remains an explicit hypothesis pending helper inspection. No additional finding, suite execution or production change. The preceding coordination/status turn made no research progress; this continuation advances the review and records its exact boundary.


### tests-1b review unit completed

All 75 manifest files are now fully read: 35,287 lines. Checked every file hash and exact manifest membership, then published review/raw/tests-1b.json with eight bounded findings (seven P2, one P3) and explicit probe/suite limitations. Final GitHub guard pass preserves reconciliation causes, credential identity, real-Git workspace protections, cache isolation/freshness and conditional replay contracts. The migration helper confirms a marker-before-probe plus timed-settle limitation; no mutation sensitivity or production defect is claimed. Different-resource concurrency overlap remains a hypothesis because result/count assertions do not directly establish simultaneous execution. Supporting TestSupport remains excerpt-only. No new production edit, full suite, live GitHub measurement or TUI run. Raw review coverage advances to 26/32; inherited review depth, final skepticism/deduplication and the six missing units remain open.


### tests-1a initial review checkpoint

31 full reads, 2670 lines, with frozen hashes recorded; 44 manifest files remain. Preserve membership/log privacy, shell quoting, unavailable/exhausted resource semantics, decision provenance/artifact policies, meter identity/freshness and test-selection contracts. PubSub-child termination and controller restart are linked to inherited shared-supervisor research without treating explicit terminate_child as proof of a rest_for_one crash cascade. Async saturation log configuration and early-failure watcher cleanup remain hypotheses. No new promoted finding or suite execution. Overall raw review completion remains 26/32; no production changes.


### tests-1a reset cleanup scope checkpoint

37 full reads, 4,374 lines. Added decision answer/log and shard/support/environment/reset tests. Confirmed P1 cleanup scope: the reset test removes the shared aiur-workspaces parent, deleting an unrelated sibling in an isolated sentinel probe; fixture-only control preserves it. Probe extracts the frozen cleanup expression and refuses shared TMPDIR roots. Initial probe attempts failed before evaluation (sigil delimiter syntax, then formatting non-expression AST nodes); corrected matching evaluates only File.rm_rf! calls and the successful run removed its private fixtures. No shared temp tree, actual reset, production mutation or full suite was exercised. Config/helper cross-references distinguish per-VM state isolation from unchanged TMPDIR. The unit remains partial, 38 files remaining; raw-unit completion stays 26/32.


### tests-1a transcript oracle checkpoint

44 full reads, 5,924 lines. Added credential gate, transcript/history, RTK, meter projection, log configuration and activity tests. Confirmed P2 boolean-oracle gap: exact assertions accept string-false and missing-payload records; boolean-sensitive control rejects both. Supporting IssueLog source shows bounded edit projection drops the fixture's truncated:false before serialization, while the serializer itself correctly handles booleans. Portable assertion probe added; no writer-suite run or production mutation. Preserve gate-versus-bind, signal-versus-partition-restart, retained-snapshot-versus-session-end and projection-versus-store-restart evidence limits. Unit remains partial with 31 files remaining; overall 26/32.


### tests-1a skill and freshness checkpoint

51 full reads, 8,594 lines; 24 manifest files remain. Recorded three previously completed skill-test reads and added PromptBuilder, AiurAgentSkill, BuildOrdersCLIFirstRead and CadenceFreshness. Preserve executable documented-label admission, watcher partial-line/restart semantics, caller-independent graph demand and two-sided cadence freshness contracts. Distinguish wording checks from agent behavior, local install-script execution from SSH, index links from mounted links, private projection calls from shell CLI, and presenter classification from rendered UX. No new promoted finding or test execution; the two existing findings remain bounded by their earlier isolated probes. Overall raw-unit completion stays 26/32. The preceding status turn added no research progress; this checkpoint advances authoritative review coverage. No production changes.


### tests-1a decision lifecycle checkpoint

56 full reads, 10,482 lines; 19 manifest files remain. Added delivery/API integration, revision, history and withdrawal tests. Confirmed P3 fixture cleanup defect: the extracted unlinked worker survives its actual normal-exit cleanup expression and answers a post-cleanup barrier; a kill control yields DOWN. The isolated probe cleans up its worker and makes no production or suite-wide performance claim. Preserve action-versus-attempt identity, surviving-queue adoption, durable handoff/withdrawal fencing, trusted provenance, idempotence and audit ordering. In-process Plug, injected dispatch and no-op filesystem sync are explicit evidence limits. No full suite or production edit. Overall raw-unit completion remains 26/32.


### tests-1a retained decisions checkpoint

60 full reads, 13,665 lines; 15 manifest files remain. Added attention, retained query, projection and revision-store tests. Preserve bounded scan continuation, partial-versus-unavailable and indeterminate lookup states, captured-versus-unknown provenance, unknown-event forward compatibility, original-action history and parent-owned follow-up recovery. Record limits of state-injected indexes, modeled rollback readers, controlled schedulers and no-op sync. Two ordering assertions remain hypotheses pending focused validation and deduplication; no new severity-bearing finding or test execution. Overall raw review coverage remains 26/32; no production changes.


### tests-1a alert and admission checkpoint

67 full reads, 16,140 lines; eight manifest files remain. Added alert feed, provider checkpoint, digest coalescing, interrupts, admission, merge retention and usage envelope. Preserve bounded alert retention and backfill, single-writer checkpoint semantics, generation-confirmed control, distinct resource-admission states and exact measurement identity. Record limits of immediate lock noncompletion checks, claimed-versus-consumed queue fixtures, fake-provider traces, assumed tmux failure and parser fixtures versus GitHub semantics. No new promoted finding or test execution. Overall raw review completion remains 26/32; no production changes.


### tests-1a timeout and tool checkpoint

70 full reads, 18,241 lines; five manifest files remain. Added operator-send timeout, provider-meter probe and dynamic-tool tests. Extended the existing P3 worker cleanup finding to the timeout fixture; the parameterized extracted-helper probe succeeds for both files, each with a post-cleanup echo and kill/DOWN control. Preserve late-item adoption, unknown outcomes, explicit message identity, independent meter failure causes, baseline reseeding and tool error contracts. Record timing/global-name, injected-transport, numeric-type and reserved-scope fixture limits. No new distinct finding, full suite or production change; overall raw review completion remains 26/32.


### tests-1a CI ordering checkpoint

72 full reads, 21,362 lines; three manifest files remain. Recorded Alerts and CI lifecycle, distinguishing numbered arrival-order recording from selective receive, helper-invoked terminal routing from live wiring, and parked-ready from draft-stall resolution policy. Extracted decision assertions confirm a missing handled audit event passes the unguarded index comparison; integer-presence control rejects it while preserving valid order. Reversed attention arrival also passes the original receives and fails a generic first-message control; grouped with the existing selective-receive finding. Initial probe lacked ExUnit application configuration and failed before assertion evaluation; corrected probe loads configuration without booting Aiur, and both controls have positive cases. Four partial-unit findings, two remaining hypotheses; raw completion remains 26/32. Previous status-only turn made no progress; this checkpoint advances evidence and coverage. No production changes or full-suite/manual verification.


### tests-1a client and core checkpoint

74 full reads, 27,637 lines; only the 7,653-line deactivate file remains. Added GitHub Client and Core, preserving conditional requests, trust and review-resolution races, truthful state transitions, differentiated retries, lifecycle fences, fake-provider replacement and queue replay, pause semantics and completion-after-hook ordering. Record limits of single-item deduplication fixtures, callback-only assertions, fixture request counts versus production savings, nested values never rendered and any-frame versus every-frame checks. Re-read the two outstanding isolation/cleanup hypotheses without promoting them beyond their evidence. No new finding, probe, full suite or manual verification; raw completion remains 26/32 and production is unchanged. Prior turn made progress with the pushed ordering evidence.


### tests-1a complete

Finished all 75 files, 35,290 lines, and verified exact frozen manifest membership, hashes and line counts. Consolidated four previously probed findings into raw/tests-1a.json; retained two unverified hypotheses separately. Deactivate review preserves confirmed-control and retained-readiness semantics, distinguishes nonterminal/terminal teardown and identifies direct-handler/fake-provider evidence limits. Reconciler excerpts reject a speculative empty-running-map explanation for nil-state coverage; receive_barrier is selective and does not prove order. No new probe, suite execution or production change. Inventory now27/32 raw units,941 findings (14P0,168P1,565P2,194P3),182 high-priority verdicts missing; claims60/60 both lenses and feature challenges33/91 remain unchanged. Next: remaining five units, skepticism, feature challenges and final synthesis/planning. Prior turn made progress through the pushed client/core review.

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
