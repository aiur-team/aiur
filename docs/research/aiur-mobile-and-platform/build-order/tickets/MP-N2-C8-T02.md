---
ticket_id: MP-N2-C8-T02
feature_id: MP-N2
chunk_id: MP-N2-C8
bucket: 3-mobile-watch
title: "Instance dashboard `/settings/mobile` LiveView: QR and device list read from the gateway over distribution RPC"
status: blocked
blocked_by: [DESIGN-N2, "DESIGN-N2 Q5 (QR on instance dashboards; Basic-Auth holders can pair)", MP-N2-C8-T01, MP-N2-C5-T01, MP-N2-C4-T01]
prior_units: [U6]
prior_boundaries: [WEB]
prior_features: []
prior_findings: [security m5 (QR visibility)]
size_owner: "WEB — router.ex and a new LiveView module (do not grow dashboard_live.ex, 2,903 lines, per U8)"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N2-C8-T02 — Instance dashboard mobile settings

## Identity and outcome

- **Bucket / feature / chunk:** 3 / MP-N2 / MP-N2-C8.
- **User value:** an operator already looking at a dashboard finds "Mobile" in it and pairs a phone
  from there, without a terminal.
- **Deliverable:** `live("/settings/mobile", MobileSettingsLive, :index)` inside
  `live_session :dashboard` (`router.ex:139-148`). The LiveView calls the gateway node
  `aiur-$USER-machine@127.0.0.1` (MP-N2-C4-T01) with `:erpc.call(node, Aiur.Machine.Api, fun, args,
  2_000)` for `qr/0`, `devices/0`, `status/0`, renders the same states as MP-N2-C8-T01, and links
  from the dashboard navigation per DESIGN-N2.
- **Non-goals:** revoke from the dashboard (unless DESIGN-N2 asks).

## Dependencies and blockers

DESIGN-N2 Q5 must approve this surface; it states that anyone with the Basic-Auth password can pair a
device (equal-authority path, contract §4 / MP-N2 plan §5). Device-session viewers (MP-N2-C6-T02)
**do not** see the QR (`403` state "Pair new devices from the machine"), so a paired phone cannot
mint pairings for others without the operator. Depends on C8-T01 (shared state rendering helpers),
C5-T01, C4-T01.

## Verified starting point (base `45a290e3`)

- LiveView routes and on_mount: `router.ex:133-149`; `FinancialDataAccess.on_mount/4`
  (`financial_data_access.ex:98-111`).
- Instances and the gateway share the per-user Erlang cookie `~/.config/aiur/cookie` and loopback
  distribution (`packaging/npm/aiur-cli/libexec/aiur-engine.sh:280-294`), so `:erpc` from an
  instance node to the gateway node is available without a new credential.
- `dashboard_live.ex` is 2,903 lines (U8 ledger, refactor plan line 228): new module required.

## Chosen design

- Context kind check: the LiveView reads the session context; device-kind contexts (C6-T02) get the
  locked state.
- **QR visibility rules (Phase D, security m5; recorded in DESIGN-N2 Q5).** Because of D19 a device
  paired here can write on *every* writable instance of the machine, so the QR (the pairing secret)
  is shown only when **all** hold; otherwise the page shows the "Pair new devices from the machine"
  state with `aiur mobile qr` and never calls `qr/0` (so no secret is issued):
  1. the session is Basic-Auth kind (not device kind);
  2. `observability.dashboard_writable` is true (a read-only dashboard must not grant write
     authority elsewhere);
  3. the page origin is loopback or HTTPS: `socket.host_uri` scheme `https`, or a peer of
     `{127,0,0,1}` / `::1` (`get_connect_info(socket, :peer_data)`). A non-loopback plain-HTTP
     origin would send the secret in clear.
- `:erpc` errors map to: `:noconnection` → "Gateway offline" state with the CLI command;
  `{:exception, …}` / timeout → `unknown` state (never a specific guessed cause).
- QR auto-refreshes when expired only on user action ("Show a new code"), never on a timer, so an
  idle tab does not churn secrets (max 3 outstanding).

## Implementation steps

`src/lib/aiur_web/live/mobile_settings_live.ex` (PROPOSED), route line, nav link,
`Aiur.Machine.Api` in the gateway (thin wrapper over C5/C7 functions). About 200 production lines.

## Non-happy paths

Mobile disabled; gateway offline; no device endpoint; QR expired; lockout; device-session viewer;
LiveView reconnect after an instance restart (re-fetch on mount).

## Compatibility and rollout

New route only; hidden from navigation when mobile is disabled (shows the "enable" state if visited).

## Verification

`src/test/aiur_web/live/mobile_settings_live_test.exs` (gateway API stubbed via an injected module):

1. `"basic-auth session renders the QR"`. 2. `"device-kind session renders the locked state and no QR"`.
   *Fails without:* the context-kind check (mutation: remove it → QR element present, test fails).
3. `"gateway offline renders the offline state with the CLI command"`.
4. `"unexpected erpc error renders unknown, not offline"`. *Fails without:* the cause-neutral fallback.
5. `"no timer-driven QR refresh"` (advance a fake clock; the stub records one `qr/0` call).
6. `"read-only dashboard hides the QR and issues no secret"` (m5; `dashboard_writable: false`) →
   locked state, stub records zero `qr/0` calls. *Fails without:* the writable check.
7. `"non-loopback plain-HTTP origin hides the QR and issues no secret"` (m5; `host_uri`
   `http://192.168.1.5:4000`, peer `{192,168,1,20}`) → locked state, zero `qr/0` calls. *Fails
   without:* the origin check.
8. `"loopback HTTP and HTTPS origins show the QR"` — the rules must not over-match.

```bash
env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" XDG_CONFIG_HOME="$(mktemp -d)" \
  mise exec -- mix test test/aiur_web/live/mobile_settings_live_test.exs
```

Browser: add the route to the existing dashboard browser harness fixture
(`src/test/browser/fixture_server.exs`) with a stubbed gateway, and check 390 px and 1280 px widths.

## Completion and handoff

- [ ] Tests pass with mutation checks.
- [ ] Docs: `website/docs-app/guide/gui.md` gains a "Mobile settings" section (new dashboard surface,
      AGENTS.md); pairing guide links to it.
