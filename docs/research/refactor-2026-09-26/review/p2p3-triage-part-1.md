# P2/P3 semantic triage — partition 1

Scope: the first 297 sorted P2/P3 canonical finding IDs in
[`findings.json`](findings.json), from `agent-backends-cc-05` through
`loose-1-09`. The [JSON ledger](p2p3-triage-part-1.json) carries individual
source IDs, reviewed severity, verdict, proposed action and a direct public
source line for each completed item. The same frozen source commit remains
`origin/main` at the time of this check.

**Complete at the pinned static boundary:** 297 of 297 reviewed; 0 remain.

`source-supported` means the claimed static mechanism is visible in the
cited source. `unknown` means a negative call-site claim or behavior requires
more evidence; it is not an adverse verdict. `fix` is a proposed behavioral
repair, and `defer` asks for further characterization or a measured reason
before extraction or deletion. No item is marked as having demonstrated
runtime incidence. Source excerpts are short and come from the frozen public
Git tree; an instance-specific literal is redacted in one excerpt. No private
source was imported.

Next: reconcile this partition with the other two, then recheck proposed fixes
against a later main before implementation tickets, including dynamic callers
and current traffic. The verdicts do not establish runtime incidence or cost.
