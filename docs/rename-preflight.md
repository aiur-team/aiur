# Rename preflight

Run the preflight before a repository-wide identifier rename:

```bash
make rename-preflight OLD=its-everdred/aiur NEW=aiur-team/aiur
```

The report is read-only. It compares the joined old value with the old owner
and repository-name components, then calls out component-only hits, hyphenated
and underscored variants, values split over adjacent lines, and common
`"#{owner}/#{name}"` interpolation. Every hit includes its file and line.

Test files are assigned to partitions using the same content-stable rule CI
uses, so the report shows the CI coverage shard for each fixture hit. Non-test
files are marked as not belonging to a test partition. Shared files under
`src/test/support/` are marked as loaded by all partitions.

The rule is `sha256(path)[0..7] % 4 + 1`, over the `src/`-relative test path
(`test/aiur/foo_test.exs`). It is defined by `Aiur.TestShard` in
`src/lib/aiur/test_shard.ex` and mirrored by `rename_preflight.shard_of`;
`scripts/check-test-shard-parity.py` fails CI if the two ever disagree, because
a preflight that names a shard CI does not use is worse than no preflight.

Sharding on the path rather than on `mix test --partitions`' sorted round-robin
is deliberate (#2568). Round-robin makes a file's shard a function of how many
files sort before it, so adding one test file moved 320 of 819 files to a
different shard — every PR that added a test inherited a fresh grouping,
tripped an order-dependent fragility somewhere unrelated, and failed on code
its author never touched. Hashing the path moves exactly the file you added.

Review each hit before changing it. Component hits can be real repository
references, unrelated usernames or project names, synthetic fixtures, or
historical records. The preflight never rewrites files and exits successfully
after printing its findings.

For synthetic GitHub fixtures, use `Aiur.TestSupport.github_repository/0` and
derive the owner and repository fields from that helper. This leaves one
rename site for the fixture slug instead of separately renaming a joined
assertion and its component fields.
