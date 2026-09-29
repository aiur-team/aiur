# Privacy review — in progress

The research branch is public. Private sources may contribute aggregate counts
and categories marked `(private)`, never configuration values, ticket text,
identifiers, paths, product details or quotations. This is an incremental audit,
not a declaration that every inherited artifact is safe.

## Checks and corrections on 2026-09-26

- Scanned every file in the published research directory for common credential
  formats, bearer values, non-loopback IPv4 addresses, private-network hostnames
  and email addresses. No credential-shaped string, non-loopback IPv4 address or
  private-network hostname matched. The two email-pattern matches were the
  public Git SSH endpoint in a shell-code finding.
- Examined private-source mentions in all five feature inventories, the 33
  saved feature challenges and the saved claim verdicts. One challenge retained
  a private configuration value even though repository names were replaced.
  Removed it from `features/challenges/done.json`, feature `subsystems-12`,
  `note`. Public configuration examples still support that challenge.
- Generalized an unnecessary demo-name quotation in
  `review/raw/web-occ.json`, finding index 29, `description`. This quotation
  came from public source, but the name is unnecessary to the finding.
- Restored claim-verdict metadata by exact matching to the local journal.
  No journal prose, private source material or credentials were imported.

- Compared the public research against 121 private issue/PR records (private).
  No exact title of at least 20 characters matched. No 18-word body window
  matched among 98,029 distinct windows. Raw records and candidate indexes stay
  in local scratch; this does not cover paraphrases, shorter quotations or
  private session-only material.
- Removed 76 CSV cells containing private run/source identifiers or exact event
  chronology; see `privacy-redactions.json`. Row counts, numeric measurements
  and all public rows are unchanged, verified against local pre-edit copies.
  Corresponding private chronology was withheld in the census/gaps prose.
- Removed private thread chronology from three fields in the recovered claim
  verdicts. `provenance.post_recovery_redactions` identifies those fields;
  the original exact journal match predates these intentional redactions.
  The recovery tool therefore must not be rerun against edited prose as if it
  were an unchanged journal export.

The correction locations above use stable JSON fields instead of line numbers
that change when formatting is normalized. No removed value is repeated here.

## Remaining audit work

- Check unlabelled quotations and examples against their public provenance,
  particularly feature usage evidence and historical reports; a name scan cannot
  establish that an anonymous passage did not come from a private source.
- Review every new artifact before publishing and repeat the full scan at final
  completion. Scratch data and raw session journals remain machine-local.
- The correction removes the value from the current branch tip, not from old
  commits. No history rewrite has been performed. The found disclosure was a
  configuration choice, not an authentication credential.

Do not interpret the automated scan as the completed human-level audit requested
in the original handoff.

## 2026-09-28 continuation audit

The public research tree was scanned again, including inherited reports, raw
findings, verdicts, feature inventories, CSVs, tooling and the newer continuation
artifacts. Two private repository names were replaced consistently with
`private-repo-a` and `private-repo-b`; these are opaque aliases, not repository
names. The replacement includes a source-fixture path in the file-size census.
Literal host-home paths were normalized to `<local-home>`, and an unpublished
duplication index path was replaced with an explicit local-evidence description.
The source-screen tool now requires a caller-provided frozen snapshot path.

The 26 recovered verdict records whose text changed carry
`provenance.privacy_audit_2026_09_28` with the changed fields. Their journal
hashes describe the original pre-redaction records; an exact match against the
current text is not claimed. The unchanged numerical CSV cells, row order and
row counts were checked against the branch base. Private acceptance-record
paths in `CONTINUATION.md` were removed, and the document now says that the
reported acceptance observations cannot be independently checked from this
branch.

The scan found no GitHub, OpenAI or AWS credential pattern or private-key block.
Credential-like matches in raw findings were variable names and synthetic test
values. Public repository and account identifiers remain where they identify
public Aiur source or public GitHub history; a named private source must stay
aliased even when its aggregate counts are retained. Loopback addresses and
documented runtime paths are technical evidence, not private host addresses.

This is a branch-tip correction. Earlier public commits still contain the old
text. The unpublished journals, private records and local acceptance details
were not imported or independently verified in this audit. Any claim relying
only on them remains limited to the cited aggregate or reported observation.
