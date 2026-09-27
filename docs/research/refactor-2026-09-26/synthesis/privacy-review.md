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
