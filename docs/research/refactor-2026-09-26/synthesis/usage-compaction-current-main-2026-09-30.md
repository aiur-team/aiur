# Usage compaction cut at `main@b4bc11f`

Two independent read-only reviews revisited `subsystems-07` against detached
`b4bc11ffcb6abf693bb3c8570aca3e12d82cb24f`. The frozen conditional
deletion footprint remains **1,297 physical lines across six files**. No
file is over 500 lines. This is a candidate footprint, not a measured net
saving or an unconditional instruction to delete the subsystem.

The coordinator is supervised in production (`src/lib/aiur.ex:396-403`) and
runs a cycle every five minutes (`usage_compaction/coordinator.ex:69-73,
340-345`). Its default byte-count callback returns zero, so the 8 MiB byte
trigger is inactive; the default position trigger can still retire ledger
data above 5,000 positions (`usage_compaction/policy.ex:39-50,79-94`).
Production has no YAML, CLI, dashboard or website route to invoke compaction
directly. In a local sample, 23 ledger segment files held 18,948 records in
total, the largest instance held 2,553 positions, and no manifest or retired
floor was found under the checked user and repository state roots. That
supports **no observed local retirement**, not impossibility for other
installations or future growth.

An empty `usage-compaction/` directory is created at coordinator boot in the
sampled instances; directory presence alone is not evidence of retirement.

When compaction runs, it writes versioned manifests and blocks, retires raw
segments, and moves through prepared, aggregate-committed, source-retired
and finalized phases (`usage_compaction/manifest.ex:30-35,133-159`,
`usage_ledger/store.ex:145-180`). Aggregate recovery loads the compacted
floor and fails closed on missing or inconsistent state
(`usage_aggregate/store.ex:103,127-145`, `usage_compaction/floor.ex:44-100`).
Deleting the six files alone leaves compile-time supervisor and reader
references. Deleting those references without a migration can undercount
usage for an installation that has retired raw segments.

The separate `telemetry-usage-01` idempotency cap is not solved by this
compactor: retirement preserves the ledger's policy/checkpoint set, which can
still exceed its serialization limit (`usage_ledger/counter_policy.ex:20-46`,
`usage_ledger/store.ex:145-180,234-245`). Do not count its repair as a
benefit of this cut.

Before promotion to an implementation ticket, census all supported state
roots for manifest, block and retired-floor artifacts; preserve a reader or
provide an explicit migration if any exist. Prove a restart from both fresh
and retired ledger fixtures, including a forced aggregate rebuild without its
checkpoint, produces the same exact usage cells and coverage,
then choose an explicit retention/log-growth policy and test the idempotency
capacity boundary separately. Include linked ledger, aggregate, supervision,
tests and Build Order usage-contract edits (`docs/build-order/04-usage-accounting.md`
and `DASH-025-usage-retention-compaction.md`) in the net LOC comparison. A
monthly log rotation alone does not satisfy their retained scoped-total and
coverage guarantees. The static finding remains a **conditional cut with
durable-state gates**.
