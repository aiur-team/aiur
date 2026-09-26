# Status: partial, not synthesized

The code review stopped early on 2026-09-26: first the account session limit was hit, then Claude credits ran out.

- `raw/` holds 23 of 32 review units, one JSON file per unit. Each file lists its findings with severity, locations, evidence and recommendation.
- Not reviewed yet: tests-1a, tests-1b, tests-4, nonelixir-web, skills-prompts, and the four cross-cutting duplication sweeps (by name, by body, by concept, by constant).
- Not verified: no P0/P1 finding has had its skeptic check yet. Treat every severity as the reviewer's own claim.
- Not written yet: `code-review.md`, `findings.json`, `by-boundary.md`.
