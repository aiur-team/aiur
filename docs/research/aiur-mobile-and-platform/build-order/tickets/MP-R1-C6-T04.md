---
ticket_id: MP-R1-C6-T04
feature_id: MP-R1
chunk_id: MP-R1-C6
bucket: 1-refactor
title: Operator launch flag for the API-without-pages run shape
status: blocked
blocked_by: [DESIGN-R1, DESIGN-R1-S4, MP-R1-C6-T03]
prior_units: [U0, U1]
prior_boundaries: ["CLI #31", "#32 launcher", "WEB #34"]
prior_features: []
prior_findings: []
size_owner: CLI
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R1-C6-T04 — Operator flag for the API-without-pages shape

## Identity and outcome

- **Bucket / feature / chunk:** Bucket 1 (scheduled with the refactor; an additive operator
  surface like RC-12), MP-R1, C6.
- **User value:** an operator can run a lean instance whose JSON API, sockets, Remote
  Control hook and webhook receiver stay reachable for a phone or Stream Deck, while the
  browser dashboard pages are off.
- **Deliverable:** one launch flag, accepted by `aiur` and `aiurdev` through the shared
  engine and by the release parser. It sets `dashboard_pages?: false` (MP-R1-C6-T03). The
  engine prints a distinct status line. The CLI reference and guides document it.
- **Non-goals:** no config key (DESIGN-R1 decides between flag and key; the plan default is
  a flag only). `--no-dashboard` keeps its meaning. No change to
  `observability.dashboard_enabled` (reserved, `configuration.md:663`).

## Dependencies and blockers

> **Size owner (RC-23).** `size_owner` comes from the U8 ledger pinned at `465aca643`, while this pack is at `45a290e3`. Re-resolve it at ticket start against the then-current U8 ledger (the MP-R1-C11-T02 sweep step). RC-19/RC-20: this ticket touches none of `issue_sync.ex`, `dispatch_policy.ex`, `github/labels.ex` or `github/issues.ex`; if a rebase brings one into scope, preserve the MP-E1-C1 hooks.

- **Blocked on DESIGN-R1 S4** (owner item): Kevin decides whether an operator flag exists
  at all and names it. The plan default is "internal only until a client needs it". This
  ticket therefore stays `blocked` until S4 names the flag **and** a client (MP-R6 Stream
  Deck lean run, MP-N1/N3 mobile) asks for it. Placeholder in this document: `--no-pages`.
  **Do not ship that name without S4.**
- **MP-R1-C6-T03** must be merged (it provides the internal shape).
- **Prior units:** the launcher `aiur-engine.sh` (4,260 lines at `45a290e3`; U8 package
  `CLI`, verified by U1 for stop/reap pidfiles) and `src/lib/aiur/cli.ex` (621 lines; U8
  `CLI`). Both are oversized, so the ticket must not grow them (see the steps). Serialize
  with any `CLI` U8 split in flight.
- **May run concurrently with:** anything that does not edit `cli.ex`, `aiur-engine.sh` or
  `website/docs-app/reference/cli.md`.

## Verified starting point

Base `45a290e3`.

- Release parser `src/lib/aiur/cli.ex`: `@switches` includes `no_dashboard: :boolean` (26).
  The usage string is at 388. `maybe_disable_dashboard/1` (564-569) sets
  `Application.put_env(:aiur, :no_dashboard, true)`.
- `src/lib/aiur.ex:67-83`: `start/2` reads `:no_dashboard` and validates Remote Control
  compatibility (`validate_dashboard_compatibility/2`, 202-225).
- Engine `packaging/npm/aiur-cli/libexec/aiur-engine.sh`: usage lines 450-453; the run path
  scans `run_argv` for `--no-dashboard` (871-874) and prints status through
  `print_dashboard_status` (1085, 1967-1981: "Dashboard disabled by --no-dashboard." or the
  probed URL).
- `website/docs-app/scripts/check-cli-reference.sh`: requires every flag found in the
  parser's `@switches` (via `sed -n '/@switches \[/,/^  \]/p'`) and in the engine's case arms
  to appear in `reference/cli.md`. A new switch without docs fails that check.
- Docs mentioning `--no-dashboard`: `reference/cli.md:52,77`, `guide/gui.md:10`,
  `guide/quick-start.md:81,90`.
- AGENTS.md "Running" documents `--no-dashboard` and the Remote Control rejection.

## Chosen design

- **Parser:** add one boolean switch (name from S4) to `@switches`, plus
  `maybe_disable_dashboard_pages/1`, which sets `Application.put_env(:aiur, :dashboard_pages, false)`.
- **Boot:** in `start/2`, pass
  `dashboard_pages?: Application.get_env(:aiur, :dashboard_pages, true)` to `child_specs/1`.
- **Combination rules:**

  | Flags | Result |
  |---|---|
  | none | today |
  | `--no-dashboard` | today: no listener |
  | new flag | listener, API and sockets on; pages off |
  | both | `--no-dashboard` wins (no listener); the engine prints one warning that the new flag has no effect |

- **Remote Control:** allowed with the new flag, because the hook route stays. No change to
  `validate_dashboard_compatibility/2`.
- **Engine:** scan for the flag next to `--no-dashboard` (871-874). `print_dashboard_status`
  prints "API listening at <url>; dashboard pages disabled by <flag>." The exact copy is
  DESIGN-R1 S4.
- **Capability report:** `run_shape.dashboard_pages: false` (from T03) is how clients
  detect it. The flag adds nothing to the contract.

## Implementation steps

1. Tests first (Verification).
2. `cli.ex`: add the switch and setter. To respect the U8 `CLI` no-growth rule, extract
   `maybe_disable_dashboard/1` and the new setter into a small `Aiur.CLI.RunShapeFlags`
   module (PROPOSED), so `cli.ex` does not grow past 621 lines.
3. `aiur.ex`: pass the option. One line, offset inside the line budget established by T03.
4. Engine: flag scan, usage lines and the status line. `aiur-engine.sh` must not grow net.
   Fold the new scan into the existing `for run_arg` loop and reuse `print_dashboard_status`
   with a third argument.
5. Docs in the same PR: `reference/cli.md` (flag row near line 52 and the `--bg` note at 77),
   `guide/gui.md` table (10), `guide/quick-start.md` table (81, 90), AGENTS.md "Running"
   block (one line).
6. Run `website/docs-app/scripts/check-cli-reference.sh`.

## Non-happy paths

- **Both flags:** deterministic; `--no-dashboard` wins, with a warning. There is no silent
  conflict.
- **Pages off but credentials missing on a non-loopback host:** `HttpServer` credential
  guard behaviour is unchanged (`http_server.ex:167-200`). The API is refused exactly as
  today.
- **Operator opens the URL in a browser:** gets the catch-all 404 JSON (T03). The status line
  says that pages are off, so this is not a silent failure.
- **Old daemon, new launcher:** the release parser rejects the unknown switch. The engine
  and release ship together in one npm package, so this occurs only for a stale dev build.
  `aiurdev` rebuilds when sources are newer.

## Compatibility and rollout

- Additive flag; no config or migration change. Default behaviour is unchanged. Rollback is
  a revert.
- Docs ship in the same PR (AGENTS.md "Docs ship with the change": CLI flag →
  `reference/cli.md`).

## Verification

```bash
env -C <worktree>/src mise exec -- mix test test/aiur/cli_test.exs test/aiur/application_test.exs
bash <worktree>/website/docs-app/scripts/check-cli-reference.sh
```

(Confirm the release-parser test file name at the implementation head with
`git ls-files src/test | grep -E '/cli_test\.exs$'`.)

| Test | Expected | Must fail without |
|---|---|---|
| parser test "the pages flag sets :dashboard_pages false" | env set after parse | parser hunk |
| parser test "--no-dashboard with the pages flag keeps no listener" | `:no_dashboard` true; boot yields no `Aiur.HttpServer` | combination rule |
| `application_test.exs` "start passes dashboard_pages? from the application env" | child spec opts carry `false` | `aiur.ex` hunk |
| engine shell test (pattern of `src/test/aiur_engine_stop_pidfile_test.exs`) "status line names pages disabled" | stderr contains the S4 copy | engine hunk |
| `check-cli-reference.sh` | passes; it fails when the `cli.md` row is removed | docs row |

**Mutation check** per row, in a clean worktree. Record the commands.

**Manual (AGENTS.md).** Wrapper-tmux `scripts/aiurdev --test <flag>`: confirm the startup
status line, that `curl -u … <url>/api/v1/state` answers, that `<url>/` returns 404 JSON,
and that a TUI chat-pane message still renders. Capture the panes.

## Completion and handoff

- [ ] DESIGN-R1 S4 approved, with the flag name and copy recorded.
- [ ] Flag works in foreground and `--bg`; the combination rule is enforced.
- [ ] `cli.ex` and `aiur-engine.sh` do not grow (U8 `CLI`).
- [ ] Docs updated; `check-cli-reference.sh` green.
- **Dependents:** MP-R6 lean Stream Deck runs, MP-N1/N3 (instances started API-only).
