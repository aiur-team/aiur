---
ticket_id: MP-N2-C3-T04
feature_id: MP-N2
chunk_id: MP-N2-C3
bucket: 3-mobile-watch
title: "Optional `aiur init` step: \"Pair a phone with this machine?\" for repo and global scopes"
status: blocked
blocked_by: [DESIGN-N2, MP-N2-C3-T02]
prior_units: [U9]
prior_boundaries: [INI]
prior_features: []
prior_findings: []
size_owner: "init.ex (INI; look up at the implementation SHA)"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N2-C3-T04 — `aiur init` mobile step

## Identity and outcome

- **Bucket / feature / chunk:** 3 / MP-N2 / MP-N2-C3.
- **User value:** brief N2 — "expose optional mobile setup … users who skip it during setup must be
  able to enable it later." `aiur init` offers it once; skipping prints the later command.
- **Deliverable:** `Aiur.Init.Mobile.prompt/3` (PROPOSED) called from `Aiur.Init` after the alerts
  step. Yes → `Aiur.Machine.CLI.enable/1` (C3-T02) then prints how to show the QR. No → prints
  "Enable later with `aiur mobile enable`". Already enabled → one line, no question.
- **Non-goals:** showing the QR inside init (DESIGN-N2 Q5 decides QR surfaces; MP-N2-C8).

## Dependencies and blockers

DESIGN-N2 (question wording, skip message, default answer — recommended default "No"). MP-N2-C3-T02.

## Verified starting point (base `45a290e3`)

- Precedent: alerts are machine-level and offered for both scopes (`src/lib/aiur/init/alerts.ex:13-37`),
  called at `src/lib/aiur/init.ex:170` with results used at `:188-199`.
- Init IO abstraction `io.confirm.(label, default)` (`alerts.ex:24`); non-interactive runs echo the default
  (`src/lib/aiur/init/questions.ex:27-28`).
- `aiur init` runs distribution-free (`build_init_cmd`, `aiur-engine.sh:437-446`), so the engine's
  gateway-routing branch (MP-N2-C3-T02) is not involved. Init therefore calls
  `Aiur.Machine.CLI.enable/1` directly; if that returns `{:error, :store_locked, "gateway"}` (a gateway
  is running and holds the store lock), init prints "run `aiur mobile enable`" and continues.

## Chosen design

- Offered for both `:repo_local` and `:global` scopes (machine-level, like alerts).
- Default `false` in non-interactive mode, so CI/scripted inits never enable mobile.
- Identity unavailable (no daemon has booted yet on a brand-new machine) → do not fail init; print
  "Mobile can be enabled after the first `aiur` run: `aiur mobile enable`". (RC-01 means the identity
  appears at first daemon boot, which is after init.)

## Implementation steps

1. `src/lib/aiur/init/mobile.ex` (PROPOSED). 2. One call in `init.ex` after alerts. 3. Tests. ~60 lines.

## Non-happy paths

Covered above: identity missing, gateway holding the lock, settings invalid (print keys, continue init).

## Compatibility and rollout

Init gains one question; existing answers and files untouched.

## Verification

`src/test/aiur/init/mobile_test.exs` with the scripted `io` used by existing init tests:

1. `"yes enables mobile"`; 2. `"no prints the later command and writes nothing"`;
3. `"non-interactive default does not enable"`. *Fails without:* the `false` default;
4. `"identity missing does not fail init"`. *Fails without:* the soft branch (mutation: propagate the error → init exits non-zero).
5. Extend `src/test/aiur/init_test.exs` golden transcript with the new question (verify the golden helper name at implementation).

```bash
env HOME="$(mktemp -d)" XDG_CONFIG_HOME="$(mktemp -d)" -u GITHUB_TOKEN -u GH_TOKEN \
  mise exec -- mix test test/aiur/init/mobile_test.exs test/aiur/init_test.exs
```

## Completion and handoff

- [ ] Tests pass; mutation for 3, 4 recorded.
- [ ] Docs: `website/docs-app/guide/quick-start.md` mentions the optional step and `aiur mobile enable`.
