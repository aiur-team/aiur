# Duplication review coverage checkpoint

Frozen revision: `3339b887196d5e9aefb273117a14bf33391ee41f`. These
checks read only the frozen source and research artifacts. They do not change
production or assert measured LOC savings.

## Name families

The prior semantic ledger covers 1,029 of 1,680 cross-module literal name
families and 8,291 definition clauses. The remaining queue contains 651
two-module families and 1,977 clauses. `tooling/name_remaining_index.py`
checks the frozen hash for every parsed source file and accounts for all
remaining clauses. Its full output is retained in the private research root at
`review/in-progress/duplication-name-remaining-index.json` and can be
reproduced with the command below. It finds 119
families with at least one cross-module normalized body hash match; 52 of those
119 share at least two leading module segments. The other 532 have no exact
normalized-body match, including 220 with that same namespace proximity.
Neither result determines semantic
equivalence: heads, guards, attributes and callees can differ; different
bodies can implement the same policy. All 651 families still need a semantic
disposition before `dup-by-name` can be marked complete.

The delegated tail checkpoints now account for all 651 queue families in
`duplication-name-tail-a.json` (indices 0–325) and
`duplication-name-tail-b.json` (326–650). Tail A screens 326 families/1,013
clauses, flags 34 shared-policy candidates and explicitly leaves 116 local
screens and 95 apparent wrappers without full caller tracing. Tail B screens
325 families and flags 84 plausible shared-policy leads; its status is an
independent semantic screen, not a final extraction verdict. The draft/raw
unit boundary remains open pending source and caller reconciliation of those
leads, the unconfirmed A rows and cross-unit overlaps. The tracked A ledger is
compactly formatted to stay below 500 physical lines; its expanded identical
JSON remains in the private research root.

Among the 119 exact-body name families, 27 contain at least one body hash
already assessed in the completed body triage, while 92 have no such prior
hash. Fifty-nine of the 119 have a maximum normalized body length of one
line. This overlap is non-additive: an assessed long clause does not dispose
of every short fallback clause in its name family.

Five narrow proposals are source-backed in the name draft. Three
`issue_context/1` helpers render identical `issue_id`/`issue_identifier` text
at `agent_runner.ex:613`, `app_server/messages.ex:68-70`, and
`orchestrator/state.ex:698-700`; the inputs differ (`Issue` struct versus a
plain map), so a shared renderer needs explicit input adaptation. Two
`blocker_terminal?/1` clause pairs repeat the same `DispatchPolicy` call and
false fallback at `orchestrator/issue_sync.ex:1330-1334` and
`orchestrator/push_routing.ex:931-935`; a shared blocker policy belongs near
dependency handling. Two PR topic clause sets and two membership run-ID
validators and a repeated bounded percentage normalizer are also source
checked in the draft. These are not independently
counted LOC savings.

## Concept families

The existing label/state ledger traces 16 frozen files and an isolated pure
helper probe. It supports one bounded concept family: vocabulary, write
authority, resolved tracker state, UI work state and display tag are different
contracts. `State.issue_tag/1` selects the first literal `agent:` label,
while `AgentList.Summaries.visible_summaries/1` filters three fixed terminal
tags. The synthetic probe reaches custom-prefix and marker-order cases; it
does not measure production incidence. The broader concept sweep across
other packages is unfinished. Existing `agent-runtime-23` and
`agent-backends-cc-38` retain their IDs; this checkpoint does not create a
duplicate defect count.

A second source-checked family covers ticket-topic grammar in poll, webhook,
wake and orchestrator paths; it cross-links three existing raw IDs.
`duplication-concept-inventory.json` accounts for all 275 inherited
duplication-category findings across the 29 existing raw units, but is only a
navigation index and does not reconcile their concepts.

## Constants and inline values

The parse-only attribute census covers 2,112 assignments in all 1,032
`src/lib` Elixir files. All 162 cross-module attribute-expression candidate
groups have source-consumer assessments in `constant-triage.json`. The regex
census covers 326 sigil sites and all 28 cross-module syntax groups have
assessments in `regex-triage.json`. These are bounded detectors: inline numbers,
string keys, dynamic regex strings, generated code and values flowing through
module attributes remain outside them. The three public raw-unit files will
stay pending until a concrete inline/key/timeout sweep and cross-unit
reconciliation are recorded. Equal numbers alone do not imply common units or
policy.

Specific source-backed relationships: four ordered five-token-dimension lists
are repeated in usage price/data, validator, pricing components and the
relationship registry. `ModelCatalog.@probe_timeout_ms` and
`ModelDiscovery.@refresh_now_timeout_ms` are both 20,000 ms by stated
design, though nested timeout overhead still matters. FinancialDataAccess
and StreamdeckAuth each pass a local version of 1 into their shared proof
configuration; the proof generation contract links them, but a common global
`1` constant would also couple unrelated versioned formats.

The follow-up parse-only inline census now visits scalar leaves in every one
of the 1,032 frozen `src/lib` Elixir files. File hashes match the function
census. It records 32,745 actual literal leaves (22,929 strings and 9,816
numbers), excluding module attributes and quoted generated code. A reproducible
high-fanout screen selects 142 strings of at least eight characters and 49
nonzero/nonone numeric values occurring in at least five modules. The
`inline-literal-audit.md` source-role audit shows that identical values
frequently have different owners; a five-module threshold is a review aid,
not a semantic completeness claim. Lower-fanout inline values and dynamic
values remain outside that screen, so the constant raw unit remains open.

The name/body overlap index accounts for all 118 A/B leads and maps 27 name
families to 22 previously recorded body findings by source-span overlap. This
is navigation evidence only: broad spans can overmatch and locations can
understate a finding. It prevents those leads from being counted additively;
their contract still needs source-level reconciliation.

The name closure ledger reconciles all 651 tail source screens and gives
source-level dispositions for the 39 shared-policy leads without an automatic
raw pointer. It also records representative negative/wrapper checks. A source
screen and a raw name-text hit do not establish whole-call-graph equivalence;
the name unit remains pending exact caller/overlap closure.

The concept closure ledger assigns all 275 inherited duplication IDs to one
primary source-role family exactly once and source-checks representative
cross-boundary contracts. A follow-up semantic probe runs 14 reproducible
domain-term searches over all 1,032 library files and source-checks seven
candidate/rejection families. This is a bounded concept detector, not a
completed search for every differently named implementation; the concept raw
unit remains pending an agreed coverage boundary and synthesis.

The lower-fanout inline audit source-checks a small set of same-domain
values missed by the five-module screen. It adds provisional Build Order
draft-body and provider active-turn-code findings, cross-links the repeated
OpenAI-compatible source version to `telemetry-usage-32`, and rejects a
global SQLite busy timeout. The remaining 1,514 cross-module value groups
outside the high-fanout screen are not semantically cleared by this audit.

## Reproduction

`python tooling/name_remaining_index.py <research-root> <frozen-snapshot>`
reproduces the structural name index. `python
tooling/test_duplication_overlap.py` verifies overlap-index behavior.
`python tooling/test_constant_census.py` and `python
tooling/test_regex_census.py` exercise the bounded parser fixtures when the
recorded Elixir toolchain is available. No daemon or CLI run was needed for
this read-only research checkpoint.

`elixir tooling/inline_literal_census.exs <frozen-snapshot>` generates the
private full inline census. `python tooling/inline_literal_summary.py
<full-census.json>` reproduces the tracked screen; `python
tooling/test_inline_literal_census.py` guards against counting AST metadata
as source numbers.
