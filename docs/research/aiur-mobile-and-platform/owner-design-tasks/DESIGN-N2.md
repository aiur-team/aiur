# DESIGN-N2 — Kevin: design and approve machine setup, pairing and revocation UX

- **Status:** open. **Implementation blocked until Kevin approves this task explicitly.**
- **Blocks:** MP-N2-C3 (CLI copy, `aiur init` step), MP-N2-C5 device-side flow, MP-N2-C7 device
  management surfaces, MP-N2-C8 (QR settings surface), and the MP-N1 app first-run flow.
  Store, advertisement and protocol work (MP-N2-C1, C2, C4, C6) may proceed, because it has no
  user-facing surface; its error codes are fixed by the contract.
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
  Recommended: yes.
- Q3. Should devices expire after a period without use? Recommended: no.
- Q4. Accept that a lost only-device cannot be unpaired remotely without access to the
  machine (SSH or the CLI)?
- Q5. Where the QR appears (see item 2). Anyone with the dashboard Basic-Auth password can
  pair a device from an instance settings page; is that acceptable?
- Q6. How long stopped instances stay listed (default 7 days). Shared with DESIGN-N3.
- Q7. Device naming: the default label (OS device name, or "iPhone"), and whether it can be
  edited from the machine side.

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
- Q1–Q7 are answered in writing in this file.
- The flows never imply that being on the same network grants access, and never imply that
  revocation erases data already on the device.
- Kevin records "approved" with a date. Until then every linked implementation ticket stays
  blocked.
