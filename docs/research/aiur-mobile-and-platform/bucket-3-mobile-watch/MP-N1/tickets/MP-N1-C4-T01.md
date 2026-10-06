---
ticket_id: MP-N1-C4-T01
feature_id: MP-N1
chunk_id: MP-N1-C4
bucket: 3-mobile-watch
title: Native navigation skeleton and typed in-app route table (internal aiur:// scheme for notification routing only)
status: blocked
blocked_by: [DESIGN-N1, MP-N1-C1-T01]
prior_units: []
prior_boundaries: []
prior_features: [MP-N2, MP-N3, MP-N4, MP-N6]
prior_findings: [baseline N6 (no deep-link scheme exists)]
size_owner: n/a (new package)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N1-C4-T01 — Navigation skeleton and route table

## Identity and outcome

- **Bucket / feature / chunk:** 3 / MP-N1 / MP-N1-C4 (shell, navigation, WebView host).
- **User value:** one predictable frame: machines/instances list → instance dashboard, with
  native Command and settings screens reachable from notifications, and no combined inbox.
- **Deliverable:** React Navigation native-stack shell in `src/shell/` (PROPOSED) with the
  typed route table below; placeholder screens owned by other tickets render a "not built
  yet" stub in debug builds only; an internal `aiur://` URL parser used **only** to route
  decrypted notification destinations and in-app links.

| Route | Params | Built by |
|---|---|---|
| `Home` (instances list) | — | MP-N3-C4 |
| `FirstRun` / `Scan` | — | MP-N2 app flow (DESIGN-N2) |
| `Instance` (WebView) | `instanceId`, `path` (`/`, `/commands`, `/chat/...`, `/build-orders/...`) | MP-N1-C4-T02 |
| `Command` (native) | `instanceId`, `decisionId`, `anchorId?` | MP-N6 |
| `Settings`, `Machines`, `Diagnostics`, `NotificationPrefs`, `WatchSettings` | per screen | MP-N2/N1-C5/N5/N7 |

- **Non-goals:** screen contents; universal/App Links (not required, plan F7).

## Dependencies and blockers

- DESIGN-N1 (surface 1 "App frame and navigation": stack vs tabs; the table above encodes the
  recommended stack). If Kevin picks tabs, only `src/shell/Navigator.tsx` changes.
- MP-N1-C1-T01.
- Concurrent with MP-N1-C2/C3 tickets.

## Verified starting point (base 45a290e3)

- Dashboard routes a WebView may open: `/`, `/chat/:owner/:repository/:identifier`,
  `/commands`, `/commands/:decision_id`, `/build-orders`, `/build-orders/:root_number`,
  `/analytics` (`src/lib/aiur_web/router.ex:139-147`); `/streamdeck` is hidden on phone
  (surface-boundary.md row 13).
- No deep-link scheme exists (baseline N6; plan F7).
- External (accessed 2026-10-06): React Navigation native stack
  (<https://reactnavigation.org/docs/native-stack-navigator>) and linking configuration
  (<https://reactnavigation.org/docs/configuring-links>); version pinned at implementation.

## Chosen design

- **React Navigation** (not Expo Router): the route set is small and must be typed and
  centrally allow-listed; file-based routing would make any file a reachable deep link.
- **`aiur://` scheme**, internal only: `aiur://m/<machine_id>/i/<instance_key>/command/<decision_id>?anchor=<id>`
  and `aiur://m/<machine_id>/i/<instance_key>/open?path=<urlencoded dashboard path>`.
  The parser:
  - accepts only those two shapes; anything else → `Home` with no error toast;
  - validates `machine_id` (26 base32 chars) and `instance_key` (10 hex chars) and rebuilds
    `instance_id = <machine_id>/<instance_key>` (RC-02);
  - validates `path` against the allow-list of dashboard path patterns above (no `//`, no
    scheme); `/streamdeck` and unknown paths → `/`.
  - **Never carries credentials** (surface-boundary §2 rule 1).
- External callers: the OS registers the scheme (Expo `scheme: "aiur"`), so another app could
  open `aiur://…`. That only navigates; every screen re-fetches with its own device credential
  and the Command screen re-checks state (MP-N6). No action is performed from a URL.
- **`aiur-pair:` is never a URL scheme (Phase D security m10).** Pairing payloads are accepted
  **only** from the in-app QR scanner (`Scan` route, which takes no params from a URL). The app
  does not register `aiur-pair` with the OS, and `linking.ts` rejects any URL whose scheme is
  `aiur-pair` or whose path starts with `/pair`. A tapped link can therefore never start pairing
  with an attacker's machine. The `Scan` result screen shows the machine label and the machine
  key fingerprint and needs an explicit "Pair" tap (MP-N2-C5-T06 owns that screen's logic).
- Back behaviour: `Instance` and `Command` push onto the stack from wherever the user is
  (DV-P11 "Back returns to the prior screen").

## Implementation steps

1. Add `@react-navigation/native`, `@react-navigation/native-stack`,
   `react-native-screens`, `react-native-safe-area-context` (exact pins).
2. `src/shell/routes.ts` (types), `Navigator.tsx`, `linking.ts` (parser + React Navigation
   `linking` config with `prefixes: ["aiur://"]`).
3. `app.config.ts`: `scheme: "aiur"`.
4. Placeholder screens under `src/screens/_placeholders/` gated by `__DEV__`.

## Non-happy paths

- Malformed or hostile URL → `Home`, logged as `route_rejected` (no URL contents logged
  beyond the shape name).
- Unknown machine in a valid URL (not paired, or revoked) → `Home` and a one-line notice
  "This link is for a machine this phone is not paired with" (copy from DESIGN-N1).
- Cold start from a notification: the initial URL is processed after the shell mounts.

## Compatibility and rollout

- Client-only. The scheme is internal; changing it later only breaks in-flight notifications,
  which carry it inside the encrypted payload (MP-N4 destination → this table via MP-N6-C2-T02).

## Verification

- `npm --prefix packages/aiur-mobile test -- test/shell/linking.test.ts`:
  - `parses a command URL into Command params with instance_id`.
  - `rejects a path outside the allow-list` (`/streamdeck`, `//evil`, `https://x`) → `/`.
    Mutation: accept any path starting with `/` → `//evil` case fails.
  - `rejects malformed ids` (25-char machine id). Mutation: drop length check → fails.
  - `never accepts a token query parameter` (`?token=…` is dropped from params).
  - `rejects aiur-pair and pair paths` (`aiur-pair:…`, `aiur://pair?…`, `aiur://m/<id>/pair`) →
    `Home`, and `Scan` is never reached from a URL. Mutation: route `aiur://pair` to `Scan` →
    fails.
  - `app config registers only the aiur scheme` (reads `app.config.ts` output; `scheme` equals
    `"aiur"` and no `aiur-pair` intent filter or `CFBundleURLSchemes` entry exists). Mutation:
    add `aiur-pair` → fails.
- `test/shell/Navigator.test.tsx`: `Command pushed over Instance and Back returns to Instance`.
- Manual: `npx uri-scheme open "aiur://m/<id>/i/<key>/command/<d>" --ios` on the simulator
  opens the Command placeholder. Device row DV-P11 runs after MP-N6-C2-T02.

## Completion and handoff

- [ ] Route table approved under DESIGN-N1 surface 1.
- [ ] Tests pass; mutations fail.
- **Docs:** none user-facing (internal scheme).
- **Dependents:** MP-N1-C4-T02/T03/T06, MP-N1-C6-T01, MP-N6-C2-T02, MP-N2 app flow, MP-N3-C4, MP-N6.
