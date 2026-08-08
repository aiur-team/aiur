# Rename preflight

Run the preflight before a repository-wide identifier rename:

```bash
make rename-preflight OLD=its-everdred/aiur NEW=aiur-team/aiur
```

The report is read-only. It compares the joined old value with the old owner
and repository-name components, then calls out component-only hits, hyphenated
and underscored variants, values split over adjacent lines, and common
`"#{owner}/#{name}"` interpolation. Every hit includes its file and line.

Test files are assigned to partitions using the same sorted round-robin rule as
`mix test --partitions 4`, so the report shows the CI coverage shard for each
fixture hit. Non-test files are marked as not belonging to a test partition.
Shared files under `src/test/support/` are marked as loaded by all partitions.

Review each hit before changing it. Component hits can be real repository
references, unrelated usernames or project names, synthetic fixtures, or
historical records. The preflight never rewrites files and exits successfully
after printing its findings.

For synthetic GitHub fixtures, use `Aiur.TestSupport.github_repository/0` and
derive the owner and repository fields from that helper. This leaves one
rename site for the fixture slug instead of separately renaming a joined
assertion and its component fields.
