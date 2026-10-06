# DESIGN-N2 — Kevin: design and approve machine setup, pairing and revocation UX

- **Status:** open. **Implementation blocked until Kevin approves this task explicitly.**
- **Blocks:** MP-N2-C3 (CLI copy, `aiur init` step), MP-N2-C5 device-side flow, MP-N2-C7 device
  management surfaces, MP-N2-C8 (QR settings surface), and the MP-N1 app first-run flow.
  Store, advertisement and protocol work (MP-N2-C1, C2, C4, C6) may proceed, because it has no
  user-facing surface; its error codes are fixed by the contract.
- **Blocks — final ticket IDs (Phase D; tickets whose `blocked_by` names DESIGN-N2):** MP-N1-C5-T02, MP-N1-C5-T04, MP-N1-C7-T02, MP-N2-C1-T01, MP-N2-C1-T02, MP-N2-C1-T03, MP-N2-C1-T04, MP-N2-C2-T01, MP-N2-C2-T02, MP-N2-C2-T03, MP-N2-C2-T04, MP-N2-C3-T01, MP-N2-C3-T02, MP-N2-C3-T03, MP-N2-C3-T04, MP-N2-C3-T05, MP-N2-C4-T01, MP-N2-C4-T02, MP-N2-C4-T03, MP-N2-C4-T04, MP-N2-C5-T01, MP-N2-C5-T02, MP-N2-C5-T03, MP-N2-C5-T04, MP-N2-C5-T05, MP-N2-C5-T06, MP-N2-C6-T01, MP-N2-C6-T02, MP-N2-C6-T03, MP-N2-C7-T01, MP-N2-C7-T02, MP-N2-C7-T03, MP-N2-C7-T04, MP-N2-C8-T01, MP-N2-C8-T02, MP-N2-C9-T01, MP-N2-C9-T02, MP-N2-C10-T01, MP-N2-C10-T02, MP-N2-C10-T03, MP-N2-C10-T04, MP-N2-C10-T05, MP-N3-C4-T01, MP-N4-C3-T07, MP-R2-C7-T05.
- **Linked:** DESIGN-N1 (app shell, native or WebView), DESIGN-N3 (where the device list
  lives in the app), DESIGN-N4/N5 (push permission prompt during pairing), DESIGN-N7
  (watch pairing through the phone).
- **References:** [MP-N2 plan](../bucket-3-mobile-watch/MP-N2/plan.md),
  [contract](../contracts/pairing-and-instance-registry.md).

## What to design

1. **Enable on the machine.**
   - The `aiur mobile enable` and `aiur mobile status` terminal output.
   - The optional `aiur init` question ("Pair a phone with this machine?"). It is skippable,
     and the skip message says how to enable later.
   - What `status` says when the gateway is off, when no endpoint is phone-reachable, and
     when a crashed instance record is present.
2. **Showing the QR.**
   - Which surfaces show it (Q5): terminal, the gateway's local page, the instance dashboard
     settings page.
   - The expiry countdown and the "show a new code" action.
   - The state when no reachable endpoint is configured.
3. **App first run.**
   - The welcome screen, then guidance to the settings page, then camera permission, then
     scan, then confirmation that shows the machine name and the fingerprint of the pinned key.
   - Where the push permission is requested (with DESIGN-N4).
4. **Adding another machine** and **re-linking** a known machine after its address changed.
5. **The device list** (on the machine and in the app): label, platform, paired date, last
   seen, watches nested under their phone; rename and revoke.
6. **Unpair-all:** the entry point, the confirmation (type the machine name), and the result
   screen that reports "access removed" separately from "notifications switched off
   (pending/complete)".
7. **"This device was removed from <machine>"**, shown to a revoked device.

## Decisions Kevin must make

- Q1. Store machine settings in `~/.aiur/machine` rather than a section of `~/.aiur/config`.
  Reason: `~/.aiur/config` is the fallback workflow config (`src/lib/aiur/workflow.ex:84-93`),
  so creating it would change what `aiur` does in every unconfigured directory.
  Recommended: `~/.aiur/machine`.
- Q2. Start the gateway automatically when any instance launches with mobile enabled?
  Options: yes, best effort / no, the operator starts it. Recommended: **yes, best effort**,
  because a phone that cannot reach a gateway is the most common support failure.
- Q3. Should devices expire after a period without use? Options: no / yes, after N days.
  Recommended: **no**, because tokens already expire every 15 minutes and expiry would
  silently unpair a phone kept for rare use.
- Q4. Accept that a lost only-device cannot be unpaired remotely without access to the
  machine? Token expiry gives no protection here (the device key can mint new tokens) and
  push keys keep decrypting (Phase D feasibility m9). The recovery is
  **`aiur mobile revoke <device>` run on the machine, locally or over SSH**; the pairing
  guide must say so. Options: (a) accept and document; (b) add a remote "revoke from
  another channel" path (none exists today). Recommended: **(a)**, together with DESIGN-N6
  D-2 "unlock before submit", which limits what a lost unlocked-session phone can write.
  [ ] (a)  [ ] (b)
- Q5. Where the QR appears (see item 2). Options: terminal only / terminal and the gateway's
  local page / terminal and the instance dashboard settings page. Recommended: **terminal
  and the instance settings page**, because the operator is usually at one of them.
  Anyone with the dashboard Basic-Auth password can then pair a device; that is acceptable
  only with these hiding rules (Phase D; MP-N2 coordinator item 3 and security review m5),
  each enforced by MP-N2-C8-T02:
  - the QR is **hidden from device-session viewers**, so a paired phone cannot mint
    pairings for other devices;
  - the QR is **hidden when `observability.dashboard_writable` is false**;
  - the QR is **hidden on a non-loopback plain-HTTP origin**, where the secret would cross
    the network in cleartext.
  [ ] confirm all three  [ ] overrule: ______
- Q6. How long stopped or crashed instances stay listed. **This gate owns the question;**
  DESIGN-N3 Q4 links here. Options: until the next refresh / 7 days / until removed by hand.
  Recommended: **7 days** (the contract default), because it covers a weekend away while
  keeping the list short.
- Q7. Device naming: the default label (OS device name, or the model name such as
  "iPhone"), and whether it can be edited from the machine side. Recommended: **the OS
  device name, editable on both sides**, because two phones of one model must be told
  apart in the device list.

- Q8. **Same-user agents can pair themselves** (Phase D, security review B1; RC-42).
  Agents run as the same OS user as aiur. Claude workers default to
  `permission_mode: bypassPermissions`; Codex `workspace-write` limits writes, not reads.
  Any of them can read `machine_key`, write a row into `devices.json` and mint a token
  that carries D19 operator authority on every instance of the machine, and so answer
  `human_required` Commands as you. Pairing protects against network attackers and lost
  phones, not against local agents. Options:
  - (0) **Accept the risk** and document it.
  - (a) **Agents run as a separate OS user.** The only full fix; it is a documented setup
    step, and it changes how workspaces, credentials and `aiur` paths are shared.
  - (b) **Keyring-held keys.** The gateway keeps `machine_key` in the OS keyring (Secret
    Service or Keychain) and is the only signer; instances verify each `devices.json` row
    by a MAC from a keyring-held key. This raises the cost but does not stop a determined
    same-user process.
  - (c) **Agent deny rules.** The daemon adds the store paths to each harness's deny
    configuration (Codex sandbox read-deny, Claude `permissions.deny`). Cheap, but Bash
    bypasses Claude deny rules, so it stops accidents, not intent.

  Every option also gets the integrity alert of RC-42 (a needs-attention alert for any
  `devices.json` row with no matching `paired` journal entry) and a threat section in the
  pairing contract.
  **Recommendation: ship (c) and the integrity alert by default, show the residual risk
  in `aiur mobile enable` output, and document (a) as the hardening step; do not block
  `mobile.enabled` on (a).** Reason: (a) is the only real fix but is a large setup change
  for every user, while (c) plus the alert is cheap and makes a silent self-pairing
  visible. This is a recommendation for Kevin, not a decision.
  [ ] (0)  [ ] (a) required  [ ] (b)  [ ] (c) + alert, (a) documented

## §transport — HTTPS for paired devices (RQ-TRANSPORT, RC-15; added in Phase D)

The dashboard serves plain HTTP (`http_server.ex:64,147`). iOS ATS and Android cleartext
rules block it, and the WebView microphone needs a secure context. Options and evidence:
[pairing contract §8.1](../contracts/pairing-and-instance-registry.md); tickets
MP-N2-C10-T01..T05.

- **T-A — publicly trusted certificate files** (for example the `tailscale cert` recipe).
  Works with every client and the WebView mic. Cost: the machine name is published to
  Certificate Transparency logs.
- **T-B — aiur self-signed certificate with an SPKI pin in the pairing QR.** No public
  name. Cost: WKWebView cannot override WebSocket trust, so LiveView needs a long-poll
  fallback and the WebView mic is unavailable on iOS.
- **HTTP-degraded mode** (`transport.allow_cleartext_overlay`). **This gate owns the
  question; DESIGN-N1 D-N1-6 links here.** If kept, it is **Tailscale-specific on the
  phone**, because the only build-time-knowable ATS exception is the `ts.net` suffix
  (MagicDNS names, never IP literals; MP-N1 B1/B2). HTTPS (T-A) works on any network, so
  Tailscale stays optional for the product. Options:
  - (i) **Remove it.** Phones pair only over HTTPS.
  - (ii) **Keep it off by default, as an opt-in diagnostics setting.** When an operator
    turns it on, device bearers are accepted on plain HTTP only from loopback or the
    Tailscale ranges (`100.64.0.0/10`, `fd7a:115c:a1e0::/48`) or explicit
    `transport.cleartext_overlay_cidrs` (security review M3), the app shows a persistent
    warning, and the WebView mic is off.
  - (iii) Keep it on by default.

  **Recommendation: (ii), off by default, opt-in diagnostics only.** Reason: one sniffed
  device token carries D19 authority on every instance (security review M3), so cleartext
  must never be the default, but an opt-in mode helps diagnose a tailnet before HTTPS is
  set up. This is a recommendation for Kevin, not a decision.

Engineering recommendation for the certificate: **T-A**, because it is the only option
with the WebView mic and LiveView WebSockets on iOS; T-B's cost is a long-poll fallback and
no mic. MP-N2-C10-T03 (T-A) or -T04 (T-B) is closed by the answer; T01, T02 and T05 apply
to both.

- [ ] T-A  [ ] T-B
- [ ] (i) Remove the HTTP-degraded mode  [ ] (ii) Keep it, off by default, opt-in diagnostics  [ ] (iii) on by default

## States to cover

| State | Where |
| --- | --- |
| Loading (claiming, token refresh) | app |
| Empty (no machines paired) | app |
| Offline (no endpoint reachable; gateway offline) | app, CLI |
| Permission denied (camera; local network on iOS) | app |
| Error (expired, used or invalid QR; wrong machine key; device limit; lockout) | app, CLI |
| Stale (endpoints changed; re-link needed) | app |
| Resolved (re-linked) | app |
| Success (paired; revoked; unpair-all done with push pending) | app, CLI, settings page |
| Disabled (mobile not enabled on the machine) | app, CLI, settings page |

## Acceptance conditions

- Every state in the table has approved copy and layout (or terminal text).
- Every decision in this file is answered in writing: Q1–Q8 and both §transport choices
  (certificate and HTTP-degraded mode).
- The flows never imply that being on the same network grants access, and never imply that
  revocation erases data already on the device.
- Kevin records "approved" with a date. Until then every linked implementation ticket stays
  blocked.
