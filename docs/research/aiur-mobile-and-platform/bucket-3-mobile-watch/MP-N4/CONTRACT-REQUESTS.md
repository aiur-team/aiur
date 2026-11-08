# MP-N4 path-refresh contract requests

## CR-N4-PATH-1 — Outbox runtime path and shared journal

Owner: MP-R1 component boundaries. Consumer: MP-N4-C3-T02 (and C3-T03
for per-instance device state). Evidence SHA:
`1080f8a109ca6c2aaff3259e83c5600e9abb36ef`.

`components/push-relay.json` declares neither config nor kernel.
The real `edge_rules` evaluator rejects `Aiur.Config.Paths` and `Aiur.Journal`
with `R-declared`; the runtime directory accessor is implemented by config,
while the directory's state owner is launcher. Do not import either rejected
module or add an exemption on the strength of this research refresh.

Request: approve the minimum explicit config/kernel edges needed for C3-T02,
or supply an owner-approved injected runtime path and persistence facade.
`Aiur.Events.Journal` is already allowed but its corrupt-tail semantics must be
reconciled with the outbox contract before reuse. MP-R1 must record its choice
in the component manifest and map. Until then, these integration points remain
unapproved; this documentation ticket records the gap without adding code.

No request is needed to import `Aiur.Commands` or `Aiur.Events` in place of their
private implementations. MP-N2's planned machine-store facade still needs its
own delivered API and ownership registration.
