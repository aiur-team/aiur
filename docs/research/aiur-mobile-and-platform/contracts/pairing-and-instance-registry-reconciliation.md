---
contract_id: MP-CT-pairing-and-instance-registry (part)
owner_feature: MP-N2
date: 2026-10-06
---

# Pairing contract — §10 reconciliation status

Moved out of [pairing-and-instance-registry.md](pairing-and-instance-registry.md) in
Phase D so the contract stays under 500 lines. Content unchanged; it is history, not
normative text. Phase D contract-request decisions are in
[../cross-feature-reviews/contract-requests-resolution.md](../cross-feature-reviews/contract-requests-resolution.md).

## 10. Reconciliation status

Applied in Phase C (2026-10-06): RC-01 (identity.json from MP-R1 at first boot; MP-N2
reads only), RC-02 (`instance_id` everywhere), RC-03 (`~/.aiur/machine`), RC-15
(§8.1 RQ-TRANSPORT). The Phase B items below remain for history.

### Phase B items

- **RC-1** The assignment text says pairing is exposed "via `~/.aiur/config`". This
  contract uses `~/.aiur/machine` for the hazard in §8. Owner confirms (DESIGN-N2 Q1).
- **RC-2** `machine_id` is defined here; MP-R1's identity-and-capabilities contract
  should adopt or reference it, and confirm `instance_key` is unchanged.
- **RC-3** MP-N4 owns push key format and the relay registration; this contract carries
  it as an opaque `push` object and calls a `deregister(device_id)` hook on revoke.
- **RC-4** MP-N7: a standalone watch is a child device (`parent_device_id`); revoking
  the phone revokes the watch.
- **RC-5** MP-R3 owns bind guards and endpoint wording; the gateway reuses them.
- **RC-6** MP-E1 owns "build progress"; §7 reads `RootSummary.progress` directly until E1
  publishes its contract.

### RC-1 rationale (moved from contract §8 in the Phase D fix pass)

Why not a section of `~/.aiur/config`: that file is the **fallback workflow
config**, used whenever a directory has no `./.aiur/config`
(`Aiur.Workflow.resolve_config_path/1`, `src/lib/aiur/workflow.ex:84-93`). Creating
it only to hold mobile keys would make every unconfigured directory start a run
with default workflow settings. A sibling machine file follows the existing
precedent of machine-level `~/.aiur/alerts` (`init/alerts.ex:19-20`,
`init/scaffold.ex:32-33`). The user-facing name stays "global machine
configuration".
