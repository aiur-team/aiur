# MP-N3 contract requests (for the coordinator)

Raised during Phase C ticket research, 2026-10-06.

## Applied directly (contract owned by this feature group)

`contracts/pairing-and-instance-registry.md` §7 is co-owned by MP-N2/MP-N3; these changes were
applied by the contract owner in Phase C:

1. Executor aggregate value `none` renamed to `absent` (MP-R1 identity contract §1.4 vocabulary).
2. Build-order roots in the summary carry `{identity, progress, resolution}` only — **no titles**
   (privacy: the summary is mirrored to watches and cached on phones; MP-N3 AC7).
3. `commands.awaiting` follows MP-E2-C7-T01's "needs you" definition once it lands.
4. §6.3 `dashboard.reason` closed list.

## Requests to other owners

| # | To | Request | Why |
|---|---|---|---|
| 1 | MP-R1 (`identity-and-capabilities.md` §2.2) and MP-E3 | The `executor.conversation` capability entry carries the dashboard `route` of the Executor surface (e.g. `{"state":"available","route":"/executor"}`). | MP-N3-C4-T03 must not hard-code the MP-E3 route. |
| 2 | MP-E2 | Confirm that the overview "needs you" count from MP-E2-C7-T01 is exposed as a public read (function name) the summary can call without the LiveView. | MP-N3-C1-T03 must match the dashboard number exactly. |
| 3 | MP-E3 | Name the capability ID and read function for the background-agent roster (MP-E3-C4-T02). | MP-N3-C1-T05 placeholder becomes a real field. |
| 4 | MP-R1 | The capability report value includes `boot_id` (RC-04) so the gateway cache (MP-N3-C2-T02) can invalidate on restart. | Already decided by RC-04; listed to confirm the field name. |
