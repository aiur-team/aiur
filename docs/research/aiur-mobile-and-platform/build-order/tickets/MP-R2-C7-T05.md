---
ticket_id: MP-R2-C7-T05
feature_id: MP-R2
chunk_id: MP-R2-C7
bucket: 1 (Bucket-2-enabling, RC-09)
title: Paired-device access to the event feed — device bearer for the events token, revocation closes live channels
status: blocked
blocked_by: [DESIGN-R2 §2, DESIGN-N2, MP-N2-C1-T03, MP-N2-C6-T01, MP-N2-C7-T01, MP-R2-C7-T01, MP-R2-C7-T02]
prior_units: []
prior_boundaries: [BUS #10, WEB #34]
prior_features: [MP-N2]
prior_findings: [RC-15 (RQ-TRANSPORT)]
size_owner: n/a (events_auth.ex / events_channel.ex are new files from C7-T02)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R2-C7-T05 — Paired-device access and revocation

## Identity and outcome

- **Bucket 1, MP-R2, chunk C7. Bucket-2-enabling (RC-09).**
- **User value:** a paired phone or watch can follow the event feed with
  its device credential, and an unpaired or revoked device stops receiving
  events within the revocation budget (≤ 2 s watcher interval plus the channel
  round trip, pairing contract §4.4 latency table), not at the next token
  expiry. That budget holds only because each instance runs its own
  `Aiur.Machine.Store.Watcher` (below); a broadcast in the writer's BEAM alone would
  not reach other instances (security M1).
- **Deliverable:**
  1. `POST /api/v1/events/token` accepts a paired-device bearer (via
     MP-N2-C6's plug) and binds the issued token to that `device_id`.
  2. A live `events:feed` channel opened with a device-bound token stops
     when that device is revoked or when unpair-all runs.
  3. Tests proving the pull API (C7-T01) accepts device bearers and rejects
     revoked ones without new code in the controller.
- **Non-goals:** no new scopes (D19: pairing grants full access; the feed is
  read-only anyway); no pairing UI; no push (MP-N4).

## Dependencies and blockers

- **MP-N2-C6** — `AiurWeb.DeviceAuth` inside `dashboard_basic_auth/2`
  (`router.ex:201-211`), so every `:dashboard_auth` route (including
  `/api/v1/events*`, C7-T01) accepts `Authorization: Bearer <access_token>`.
  Contract: `contracts/pairing-and-instance-registry.md` §4.4.
- **MP-N2-C7** — revocation and unpair-all (§4.5).
- **MP-N2-C1-T03** — `Aiur.Machine.Store.Watcher`, the per-instance revocation
  signal (below; pairing contract §4.4).
- **RQ-TRANSPORT / RC-15** — remote devices reach the dashboard only over
  the HTTPS transport MP-N2 decides; until then device access is
  loopback/test only.
- DESIGN-N2 (pairing UX) and DESIGN-R2 §2.
- C7-T01, C7-T02.

## Verified starting point (45a290e3)

| Fact | Evidence |
| --- | --- |
| No device credential exists at base; dashboard auth is Basic Auth with a session proof | `src/lib/aiur_web/router.ex:201-211`; `src/lib/aiur_web/financial_data_access.ex:50-84` |
| Planned: device bearer accepted on any `:dashboard_auth` route; checked against the machine store, cached by file mtime; revoked device fails on the next request | `contracts/pairing-and-instance-registry.md` §4.4 (line 177 at research time) |
| Planned: `DELETE /v1/devices/<id>` and unpair-all; offline device learns on next request (`401 device_revoked`) | same contract §4.5 (line 205 at research time) |
| Access token TTL 15 min; store holds only sha256(token) | same contract, credentials table (line 55) |
| Channel lifetime model this extends (token expiry and credential-generation change stop the channel) | `src/lib/aiur_web/streamdeck_channel.ex:37,238-243`; C7-T02 |
| MP-N2 tickets: C6-T01 plug wiring; C7-T01 revoke; C7-T02 unpair-all | `bucket-3-mobile-watch/MP-N2/chunks.md:98-123` |

## Chosen design

- **Token binding:** `EventsAuth.issue_token/1` takes the request's
  principal: `{:basic, generation}` (today) or `{:device, device_id}` (set by
  MP-N2-C6's plug in `conn.private`/assigns). The signed payload gains
  `device_id` (nil for Basic Auth). `verify_token/1` additionally calls
  MP-N2's `verify_device/1` (C1-T03 `verify_token` family; the exact
  function is whatever MP-N2-C6 exposes for "is this device still paired")
  when `device_id` is present.
- **Token lifetime:** unchanged 300 s (C7-T02). It is shorter than the
  device access token's 15 min TTL, so a channel never outlives the
  credential that minted it.
- **Revocation → channel stop (decided, security M1):** the revoke writer
  is the gateway (a separate machine-level process) or the CLI while the
  gateway is down, so a `local_broadcast` in the writer's BEAM never reaches
  an instance BEAM. Instead each instance runs `Aiur.Machine.Store.Watcher`
  (MP-N2-C1-T03): it stats `devices.json` (mtime, size, inode) every 2 s
  and, on a change, diffs the active device ids and calls
  `Phoenix.PubSub.local_broadcast(Aiur.PubSub, "devices:revoked", {:device_revoked, device_id | :all})`
  **in that instance**. `EventsChannel` subscribes on join when `device_id`
  is set and stops on a matching id or `:all`. This mirrors the existing
  credential-generation stop (`streamdeck_channel.ex:240-243`). If
  MP-N2-C1-T03 has not shipped the watcher, this ticket is blocked; it does
  not add a writer-side broadcast as a substitute.
- **Backstop:** even without the broadcast, a revoked device's channel ends
  at the 300 s token expiry and cannot obtain a new token
  (`401 device_revoked`). Worst-case exposure after revoke: 300 s of
  identifier-only events (KQ-R2-3) — documented.
- **Pull API:** no controller change; device bearers work through the
  `:dashboard_auth` pipeline.

## Implementation steps

1. Rebase on MP-N2-C6/C7; read the device principal key they put on the conn.
2. `EventsSessionController.create/2` passes the principal to `EventsAuth`.
3. `EventsAuth`: `device_id` in payload; device check in verify.
4. `EventsChannel`: subscribe to `devices:revoked`; stop on match.
5. Tests.

## Non-happy paths

- **Machine store corrupt:** MP-N2 fails closed (device tokens rejected,
  contract failure table "Store corrupt or unreadable"); token issuance → 401; existing device channels stop
  at expiry.
- **Revoked while offline:** next token request → `401 device_revoked`;
  client wipes state (MP-N2 client harness).
- **Unpair-all:** `{:device_revoked, :all}` stops every device-bound
  channel; Basic-Auth channels (operator, Stream Deck-style tools) continue.
- **Multiple devices:** each channel bound to its own `device_id`; revoking
  one does not affect others.
- **Transport:** tailnet reachability is never authorization (contract
  §10); without HTTPS (RQ-TRANSPORT) devices are not supported off-host.

## Compatibility and rollout

No change for Basic-Auth clients. Inert until MP-N2 is enabled
(`~/.aiur/machine` mobile settings, RC-03). Rollback: revert; tokens issued
before the revert fail verification only if their payload shape is
rejected — keep `verify_token/1` tolerant of a missing `device_id`.

## Verification

`src/test/aiur_web/events_device_access_test.exs` (temp machine store via
MP-N2's test helpers; never `~/.aiur`):

1. `"a paired device bearer can pull /api/v1/events"` → 200.
2. `"a revoked device bearer gets 401 device_revoked and no records"`.
3. `"a device-bound channel stops when devices.json is rewritten without notice"`
   — start the instance's `Aiur.Machine.Store.Watcher` against the temp store, join
   with a device-bound token, then rewrite `devices.json` directly (the row
   marked revoked, exactly as the gateway or CLI writes it; no message is sent
   to the watcher or the channel) → the channel exits within 2 s + 500 ms
   (`assert_receive {:EXIT, _, _}, 2_500` with an injected 100 ms watcher
   interval scaled accordingly). **Fails without step 4** (no subscription)
   **and fails if the watcher is replaced by a writer-side broadcast**,
   because the test never broadcasts.
4. `"unpair-all stops device channels but not Basic-Auth channels"`.
5. `"revoking device A leaves device B's channel open"`.
6. `"token verification rejects a token whose device was revoked after issue"`
   — issue, revoke, connect → `:error`. **Fails without the step 3 device check.**

```text
env -C <worktree>/src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" XDG_CONFIG_HOME="$(mktemp -d)" mise exec -- mix test \
  test/aiur_web/events_device_access_test.exs test/aiur_web/events_channel_test.exs \
  test/aiur_web/controllers/events_controller_test.exs
```

Mutation check: remove the `devices:revoked` subscription, or stop the
watcher child → test 3 fails;
skip the device check in `verify_token/1` → test 6 fails. Clean worktree.

Device test (MP-N2-C9 device-validation plan): on a paired phone, follow
the feed, revoke the phone from `aiur mobile revoke <id>`, observe the
stream closing within 2 s and the app showing its revoked state.

## Completion and handoff

- [ ] MP-N2-C6/C7 merged; tests 1–6 added and mutation-checked.
- [ ] Docs: `website/docs-app/concepts/message-bus.md` external-feed section
      gains "Paired devices" (bearer accepted, 300 s token, revocation
      closes streams); MP-N2's pairing page links to it rather than
      restating it.
- Dependents: MP-N3 (remote meta-dashboard stream), MP-N6-C6, MP-N7.
