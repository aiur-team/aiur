# Status: partial, not synthesized

The code review stopped early on 2026-09-26: first the account session limit was hit, then Claude credits ran out.

- `raw/` holds 23 of 32 review units, one JSON file per unit. Each file lists its findings with severity, locations, evidence and recommendation.
- Units still incomplete: tests-1a, tests-1b, tests-4, nonelixir-web, skills-prompts, and the four cross-cutting duplication sweeps (by name, by body, by concept, by constant).
- Not verified: no P0/P1 finding has had its skeptic check yet. Treat every severity as the reviewer's own claim.
- Not written yet: `code-review.md`, `findings.json`, `by-boundary.md`.

## Website continuation checkpoint

`in-progress/nonelixir-web.json` records full reads of the 16 website files in
the 178-file unit. The other 162 paths remain unreviewed in this continuation.
Three P2 findings have isolated source probes: a false-passing reduced-motion
check, a readiness deadline that cannot cancel its in-flight request, and copy
feedback that does not wait for clipboard success. These are additional
provisional findings, outside the 853 inherited findings in `raw/`.

Reproduce with Node 24:

```sh
node tooling/website_review_probe.mjs /path/to/frozen-snapshot
```

The probe transpiles source into a disposable temporary directory, checks the
baseline and a broken freeze-offset mutation, and uses controlled browser API
doubles for the other two cases. It does not launch a browser or Aiur. It is
research evidence, not manual UX verification. Output is retained in
`in-progress/website-review-probe.json`; each input carries a SHA-256 hash.
No production implementation changed. This partial unit is deliberately not
counted among the 23 raw unit artifacts.

## Stream Deck lifecycle continuation

The same partial unit now records 45 complete file reads: the 16 website paths
plus 29 Stream Deck source, test and configuration paths. There are 133 paths
remaining. Two additional P2 findings concern duplicate monitor restart chains
and removal events from a different product of the same vendor. Five provisional
findings now sit outside the inherited `raw/` totals.

```sh
node tooling/streamdeck_lifecycle_probe.mjs /path/to/frozen-snapshot
```

On Linux with Node 24, the probe confirms that a genuinely absent executable
produces both error and close notifications, then drives the frozen runtime with
injected timers and device/monitor doubles. One failure schedules two replacements;
cleanup loses ownership of one child or timer. A same-vendor, different-product
removal also closes a healthy backend and leaves no reopen timer. Results are in
`in-progress/streamdeck-lifecycle-probe.json`. These are conditional source-level
reproductions, not hardware testing or estimates of incident frequency.

The pure device reducer already separates idle reads, disconnects, suspend and
bounded recovery. Preserve that seam in planning. The demonstrated gaps concern
monitor termination ownership and device identity at the event adapter boundary.
