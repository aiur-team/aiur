---
ticket_id: MP-E7-C3-T06
feature_id: MP-E7
chunk_id: MP-E7-C3
bucket: 2-platform
title: "Capability provider for listener_modes (spec state, routing flag, fallback reason)"
status: blocked
repo: aiur-team/aiur
wave: 3
blocked_by: [DESIGN-E7, MP-E7-C3-T03, MP-R1-C3-T01]
prior_units: [U4]
prior_boundaries: [MSG (16)]
prior_features: [MP-R1, MP-E3, MP-E4, MP-N3]
prior_findings: [X-01, X-21, RC-36]
size_owner: n/a (new file; one line in src/config/config.exs)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E7-C3-T06 — Capability provider for `listener_modes`

## Identity and outcome

- **Bucket / feature / chunk:** 2-platform / MP-E7 / C3. Closes Phase D
  finding X-21 for listener modes and the capability half of RC-36.
- **User value:** the dashboard, phone and the MP-E3/E4 composers can show
  whether listener modes are really in effect, and why not ("not installed in
  this build", "spec failed its checksum", "turned off"), instead of `unknown`.
  Sending a message never depends on this capability: the send router is
  required core code and falls back to today's routing.
- **Deliverable:** PROPOSED `src/lib/aiur/listener/capability_provider.ex`
  (`Aiur.Listener.CapabilityProvider`, implementing `Aiur.Capabilities.Provider`)
  and one entry in `config :aiur, :capability_providers`.
- **Non-goals:** per-agent requested/effective mode (that is the control record,
  MP-E7-C7-T03); per-harness steer support (`harness.<id>.*`, MP-R7); any
  change to routing.

## Dependencies and blockers

- DESIGN-E7 (feature gate).
- MP-E7-C3-T03: `Aiur.Listener.send/3` and the router exist.
- MP-R1-C3-T01: the provider behaviour and registry. Identity contract §2.2
  registers the reason `spec_invalid` for this provider (Phase D).
- Reads `Aiur.Listener.Spec.status/0` (MP-E7-C1-T04) through
  `Scheduler.spec_status/0` (MP-E7-C3-T02), which answers `not_installed` when
  C1-T04 has not landed, so this ticket does not wait for the Khala chain.

## Verified starting point (`45a290e3`)

- No capability registry at base (identity contract §2.4; MP-R1-C3-T01).
- No `Aiur.Listener` module at base; the flag
  `config :aiur, :listener_send_routing` (`:legacy` default) is introduced by
  MP-E7-C3-T02, and C7-T04 flips it after E7-D6.

## Chosen design

- `capability_ids/0` → `["listener_modes"]`.
- `capabilities(_context)` evaluates, in order:

  | Condition | `listener_modes` |
  | --- | --- |
  | `Scheduler.spec_status/0 == {:error, :not_installed}` | `unavailable` / `not_installed` |
  | `Scheduler.spec_status/0 == {:error, :spec_invalid}` | `unavailable` / `spec_invalid` |
  | spec `:ok`, flag `:legacy` | `unavailable` / `disabled` |
  | spec `:ok`, flag `:listener` | `available` (attribute `version` = spec major) |
  | raise, exit or any other value | `unknown` / `unknown` |

- Pure reads only (`:persistent_term` and app env); no GenServer call, so the
  500 ms provider budget is safe.
- The provider sits in `listener-modes` and references nothing outside it
  except the capability behaviour.

## Implementation steps

1. `capability_provider.ex` with the table as one `cond`.
2. Register it in `config :aiur, :capability_providers`.
3. Tests below.

## Non-happy paths

- Spec status not yet computed (first milliseconds of boot) → the
  `persistent_term` miss is treated as `not_installed` for that tick; the
  monitor recomputes every 2 s (identity §2.4).
- Flag set to an unknown value → `routing/0` treats it as `:legacy`, so the
  provider reports `disabled`, matching what the router does.

## Compatibility and rollout

Additive capability ID. Clients that do not know it ignore it (identity §3
rule 2). With today's default (`:legacy`) every instance reports
`unavailable/disabled` until C7-T04. Rollback: remove the provider line.

## Verification

| Test (`src/test/aiur/listener/capability_provider_test.exs`, PROPOSED) | Expected | Fails without |
| --- | --- | --- |
| "spec absent reports unavailable/not_installed" | exact entry | the first clause |
| "checksum failure reports unavailable/spec_invalid" | exact entry | the second clause (replace it with `not_installed` and it fails) |
| "legacy flag reports unavailable/disabled, never absent" | entry present with reason `disabled` | the flag clause |
| "spec ok and flag listener reports available" | `state == "available"` | the success clause |
| "a raising spec status reports unknown/unknown" | `unknown`/`unknown` | the rescue (replace it with `disabled` and it fails) |

Mutation check: revert the provider hunk in a worktree (`git status
--porcelain` shows only that revert) and run the file; every test fails.

```sh
env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- mix test test/aiur/listener/capability_provider_test.exs
```

## Completion and handoff

- [ ] Provider registered; `listener_modes` present in every run shape.
- Docs: the capability page owned by MP-R1-C3 lists `listener_modes` and its
  reasons; MP-E7-C7-T05's concept section says modes take effect only when the
  capability is `available`.
- Dependents: MP-E3-C5, MP-E4-C6 (composer copy), MP-N3, MP-E7-C7-T01.
