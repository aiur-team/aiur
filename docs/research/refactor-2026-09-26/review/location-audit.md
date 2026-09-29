# P0/P1 citation audit

The [mechanical citation check](location-audit.json) covers all 182 inherited
P0/P1 findings against the complete `3339b887` extraction. All cited files
and line spans exist for 177 findings. Five had at least one line span beyond
the cited file: `build-order-02`, `tests-5-02`, `web-rest-06`, `web-rest-08`
and `web-rest-09`. Source inspection located the relevant spans in the same
frozen snapshot. Eight exact overlays are recorded in
[citation-corrections.json](citation-corrections.json), leaving raw findings
intact. The [corrected audit](location-audit-corrected.json) finds readable
spans for all 182 findings.

This check proves only that the corrected cited spans are readable. It does not
establish that the quoted code supports the claim, that the behavior occurs,
or that P0/P1 severity is warranted. The two skeptical checks remain open for
all 182 findings until separately recorded.
