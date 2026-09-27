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
