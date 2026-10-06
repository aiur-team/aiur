---
ticket_id: MP-N2-C8-T01
feature_id: MP-N2
chunk_id: MP-N2-C8
bucket: 3-mobile-watch
title: "Gateway local settings page (loopback only, one-time link): pairing QR, expiry countdown, device list, all states"
status: blocked
blocked_by: [DESIGN-N2, "DESIGN-N2 Q5 (which surfaces show the QR)", MP-N2-C5-T01, MP-N2-C7-T01, MP-N2-C4-T01]
prior_units: []
prior_boundaries: [CLI]
prior_features: [MP-R3]
prior_findings: []
size_owner: n/a (new gateway modules)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N2-C8-T01 — Gateway settings page

## Identity and outcome

- **Bucket / feature / chunk:** 3 / MP-N2 / MP-N2-C8 "Settings-page QR surface".
- **User value:** the operator can show a large, scannable QR in a browser on the machine (a
  terminal QR is hard to scan on some fonts), see when it expires, make a new one, and see the
  device list — with mobile setup available at any time, not only during `aiur init` (brief N2).
- **Deliverable:** `aiur mobile qr --open` prints (and opens with `xdg-open`/`open` when available)
  `http://127.0.0.1:<gateway.port>/settings?t=<one-time token>`. The gateway serves a small
  server-rendered page (no LiveView; static HTML + one `fetch` poll) with: QR as SVG
  (`EQRCode.svg/2`), machine label and key fingerprint, expiry countdown, "Show a new code",
  device list (read-only; revoke stays in the CLI and the app unless DESIGN-N2 asks otherwise),
  and the states table below.
- **Non-goals:** instance-dashboard settings page (C8-T02).

## Dependencies and blockers

DESIGN-N2 (layout, copy, Q5 decides whether this surface ships), MP-N2-C5-T01 (`qr --json` data),
MP-N2-C7-T01 (device list), MP-N2-C4-T01 (gateway HTTP endpoint).

## Verified starting point (base `45a290e3`)

- No such page exists. The gateway is new (MP-N2-C4). Loopback default bind: contract §6.2.
- `eqrcode` 0.2.1 `svg/2` (<https://eqrcode.hexdocs.pm/0.2.1/EQRCode.html>, accessed 2026-10-06);
  dependency added by MP-N2-C5-T01.

## Chosen design

- **Access control.** Loopback is not authorization on a multi-user host (contract §6.2 spirit):
  the page requires a one-time token minted by the CLI (32 random bytes; sha256 stored in gateway
  memory; valid 5 minutes; exchanged on first GET for an `HttpOnly; SameSite=Strict` cookie scoped to
  `/settings`, lifetime 30 minutes). Routes under `/settings` are served only on the loopback
  listener, never on the HTTPS device listener (MP-N2-C10-T02).
- **States:** mobile disabled → instructions to run `aiur mobile enable`; no device endpoint → the
  rejection reasons from `Endpoints.select/2`; QR expired → "Show a new code"; gateway pairing locked
  → countdown; success after a claim (poll sees a new device) → "Paired <label>".
- No secret in logs; the QR SVG is not cached (`Cache-Control: no-store`).

## Implementation steps

Controller + template in the gateway web module; token store; CLI `--open`. About 220 production lines.

## Non-happy paths

Token reused or expired (403 page "Run `aiur mobile qr --open` again"); browser on another machine
(cannot reach loopback — by design); `xdg-open` missing (URL printed only).

## Compatibility and rollout

Gateway-only; absent unless mobile is enabled.

## Verification

`src/test/aiur/machine/settings_page_test.exs`:

1. `"page without a valid token is 403"`. *Fails without:* the token check.
2. `"token is single use; the cookie keeps the session for 30 minutes"`.
3. `"settings routes are not served on the device listener"`.
4. One test per state rendering its marker element (`data-state="…"`), with the underlying value
   asserted (e.g. rejected endpoint reasons equal `Endpoints.select/2` output).
5. `"QR svg encodes the same uri as qr --json"` (decode by re-encoding the URI and comparing the matrix).

Browser: `website`-style Playwright check is not available for the gateway; manual check on the
host in Firefox and Chromium at 1280 px, then scan with both phones (MP-N2-C9-T02 row P2).

```bash
env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" XDG_CONFIG_HOME="$(mktemp -d)" \
  mise exec -- mix test test/aiur/machine/settings_page_test.exs
```

## Completion and handoff

- [ ] Tests pass with mutation checks.
- [ ] Docs: CLI reference `aiur mobile qr --open`; pairing guide.
