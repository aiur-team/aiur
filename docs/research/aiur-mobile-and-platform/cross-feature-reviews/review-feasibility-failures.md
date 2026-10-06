---
review: Phase D cross-review — mobile/watch feasibility and failure handling
scope: MP-N1..N7, MP-E5/E6 (voice), MP-E1 (queue failure modes), MP-E2 (escalation timeouts), MP-E4 (journal)
base_main_sha: 45a290e3
date: 2026-10-06
reviewer: independent (read-only; this file is the only write)
---

# Review: feasibility and failure handling

This review checks two things. First, every external platform claim must have a source and a
date, and it must be plausible. A claim that depends on unverified behaviour must have a
physical-device row. Second, every cross-feature failure mode must have an owner ticket that
contains a test.

Ticket IDs are cited as they were on 2026-10-06. Another agent is renaming IDs and editing
`blocked_by` at the same time. Map the IDs through that rename, not through this file.

**Verdict.** The evidence is unusually strong. Every claim in `MP-N4/platform-evidence.md`
and `MP-N1/framework-evidence.md` carries a URL, an access date and, where one is given, a
page date. The UNVERIFIED claims are named and mapped to device rows. No finding blocks the
architecture. Eight major findings must be fixed before the mobile features count as
implementation-ready. Five of them are failure paths with no owner test. Three are
validation definitions that cannot pass, or that cannot pass without an unplanned fallback.

Severity scale:

- **Blocker:** the plan cannot work as written.
- **Major:** a user-visible failure path with no owner or test, a validation row that is
  wrong, or a ticket below brief §9 depth.
- **Minor:** an evidence correction, a naming fix, or a test gap that existing behaviour
  already makes unlikely.

---

## 1. Findings

### Blockers

None.

### Major

**M1. A daemon crash during a Converse session leaves the provider conversation at
ElevenLabs. It is never deleted.**
*Where:* `bucket-2-platform/MP-E6/tickets/MP-E6-C2-T04.md` §"Dependencies" ("enqueue happens
only **after** the transcript's `session_ended` record is fsynced"); `MP-E6-C6-T02.md`
("a conversation without `session_ended` after a crash is listed with `end_reason:
"unknown"`"); `MP-E6/plan.md` §8 row "Daemon restart".
*Problem:* a crash, OOM or `aiurdev restart` mid-session never writes `session_ended`, so
`ProviderCleanup.enqueue/2` never runs. The provider copy then stays under the default
retention of 2 years (provider-research §2). That breaks the plan's own promise that
"aiur keeps the only full transcript". Restarts are routine in this repo, so this path will
happen.
*Fix:*
1. In MP-E6-C4-T01, write the provider conversation id into the transcript at
   `conversation_initiation_metadata`.
2. In MP-E6-C6-T02's boot rebuild, append `session_ended{reason: "daemon_restart"}` to each
   unterminated transcript and call `ProviderCleanup.enqueue/2` for every provider id it
   finds. Keep the index entry `unknown` if you want "never inferred", but the cleanup
   still runs.
3. Add `daemon_restart` to the voice-session §6 end reasons.
4. Test in C2-T04: "a transcript with a provider id and no session_ended is enqueued at
   boot". Mutation check: skip the boot scan and the test fails.

**M2. Phone Converse (MP-N6-C4-T03) is below brief §9 depth and has no failure handling.**
*Where:* `bucket-3-mobile-watch/MP-N6/tickets/MP-N6-C4-T03.md`. Its implementation steps say
"After unblocking". It has one non-happy path (provider unavailable) and one test.
*Problem:* this is the phone surface for daemon restart mid-voice-session, provider down
mid-session, `cost_cap`/`provider_quota`, device revoked mid-session (`auth_changed`),
Wi-Fi→cellular transition, and a draft going `stale` because the Command was resolved
elsewhere. The watch equivalent (MP-N7-C4-T05) handles most of these. The phone does not.
*Fix:* bring it to the depth of MP-N7-C4-T05:

- a state table with every voice-session §6 end reason and §8 error code;
- a draft `stale` path that cites the E2 conflict data;
- a fixture test per end reason that fails when the branch is replaced with a generic
  "error" (AGENTS.md collapsed-cause rule).

Scan MP-N6-C5-T02/T03 (about 57 lines each) for the same gap.

**M3. A blocker push that the provider accepts but never displays has no recovery path.**
*Where:* `MP-N5/plan.md` §5 ("Re-asks (`DecisionAttention`) never emit. Reminders: none in
v1 (OQ-N5-2)"), OQ-N5-2 proposal "none in v1"; `MP-N4/plan.md` §7.3.
*Problem:* APNs and FCM are best effort (E-A2 "without any guarantee", E-A4 one stored per
bundle, E-F2 100-message drop), and nothing returns a display receipt. The NSE makes no
network calls (KD-N4-6). So a lost `human_required` notification is noticed only when the
operator happens to open the app. That is the main user outcome of N4/N5. The plan shows
this risk to the owner as a noise question, not as a delivery-reliability question.
*Fix:*

- Reword OQ-N5-2 in DESIGN-N5 to state the risk.
- Recommend one bounded reminder for `blocking` Commands still `with_human` after N minutes
  (default 30). Same `collapse_token`, so it replaces the first notification rather than
  stacking. Give it a ledger key distinct from the re-ask tick, so AC-N5-2 still holds.
- Add an app badge equal to the open blocking count; iOS/Android badge set from the
  decrypted payload.
- Owner ticket: MP-N5-C2 (policy), with a test "unanswered blocking Command produces
  exactly one reminder and none after resolution".

If the owner refuses reminders, record that decision in AC-N4-1.

**M4. DV-P1 has a pass criterion that contradicts V-A4, so AC9 cannot pass on Android.**
*Where:* `MP-N1/device-validation.md` DV-P1 ("Killed and force-quit states are included"
→ decrypted summary in all states). `MP-N1/tickets/MP-N1-C10-T01.md:59` ("Decrypted short
summary shown in every state on every slot"). `MP-N4/device-validation-plan.md` V-A4
("force-stopped … expect no delivery", E-F7). `MP-N1/plan.md` §8 row "App killed or
force-quit" states as fact what N4 marks UNVERIFIED (RQ-N4-3).
*Fix:*

- Split DV-P1 into four states:
  - system-terminated: pass required;
  - iOS app-switcher force-quit: record (RQ-N4-3);
  - Android swiped from recents: pass required on Pixel, record on Samsung;
  - Android Settings → Force stop: expect no delivery plus the warning from MP-N4-C5-T03.
- Correct the N1 plan §8 row.
- Make one matrix canonical. DV-P1..P4/P8 duplicate V-I1..I4, V-A1..A6 and V-M1 with
  different wording. N4's matrix should own the push rows, and N1 should link to it, as
  N1 already does for the watch rows (N7-C6).

**M5. DV-W1 is a required pass that depends on an UNVERIFIED claim, and no fallback design
exists.**
*Where:* `MP-N7/plan.md` §7 (v1 relies on iPhone forwarding; "supported only by vendor
evidence (S39)"); `MP-N7/tickets/MP-N7-C6-T01.md` DV-W1 "Required: Yes";
`MP-N4/platform-evidence.md` E-B6. N7-RQ4 (direct watch push) is "deferred".
*Problem:* if the watch shows the uniform fallback ("aiur · New notification"), required
row DV-W1 fails, and MP-N7 can never be "complete". The only designed alternative needs a
second pairing scope that MP-N2 does not define. The fail branch is not planned work.
*Fix:* define the DV-W1-fail behaviour in MP-N7 now, so a failed row changes the plan by a
known amount:

- (a) Accept the fallback on the watch. Make the default action open the watch app, which
  fetches the card through the phone (`get_command`). Change DV-W1's pass criterion to
  "decrypted text, or fallback with the card one tap away".
- (b) Promote N7-RQ4 to a conditional chunk.

Record the choice in DESIGN-N7.

**M6. On Android, losing local keys is treated the same as a forged payload, so every
notification is dropped silently.**
*Where:* `MP-N4/plan.md` §7.2 row "Unknown `kid` / bad signature / expired / seen `nid`" →
Android "not posted". `MP-N4/tickets/MP-N4-C5-T01.md` non-happy path: "Keystore key
invalidated (e.g. lock-screen removal on some OEMs): keyset unreadable → treat as unknown
kid → prompt re-pair".
*Problem:* a local cause (keystore invalidated, keyset unreadable) is merged into a remote
cause (unknown kid, which could be an attack). The result is that all notifications stop
with no visible sign, and the "prompt re-pair" appears only if the user opens the app.
AGENTS.md "a collapsed cause names the collapse at the source".
*Fix:*

- In C5-T02, return `Fallback(KEYS_UNAVAILABLE)` for local key loss.
- Post the uniform fallback text, plus "Open aiur to re-pair" on the in-app open.
- Keep silent drop only for verification failures on a readable keyset.
- Report `push_keys_lost` to the machine on the next online call, so the dashboard shows
  "phone notifications broken".
- Test: "invalidated master key posts the fallback, not nothing". Mutation: map it to
  unknown-kid and the test fails.

Check the iOS NSE (MP-N4-C4-T02) for the same merge. A keychain read error other than
`errSecInteractionNotAllowed` should also show the fallback.

**M7. Mobile voice clients do not tell cost cap, quota, provider outage and daemon restart
apart.**
*Where:* the `contracts/voice-session.md` §6 end reasons `cost_cap`/`provider_error` and the
§8 codes `cost_cap_reached`, `provider_quota`, `provider_unavailable`, `transport_lost`. No
MP-N1/N3/N6/N7 ticket names `cost_cap` or `provider_quota`. `MP-N7-C4-T04` passes
`reason_code` through generically.
*Problem:* when the voice-minute limit is reached, the watch or phone shows a generic error.
The user retries, and fails again with no explanation. The dashboard (MP-E6-C7) shows the
reason; the mobile clients do not.
*Fix:*

- Add a shared fixture `voice-end-reasons.json` in `packages/aiur-mobile/fixtures/contract/`
  with one row per end reason and error code, giving copy and retry eligibility (cost cap
  and quota: no retry; transport lost: retry).
- Drive the TS (phone), Swift and Kotlin (watch) state tests from it, with owners
  MP-N6-C4-T02/T03 and MP-N7-C4-T05.
- Fix the naming mismatch at the same time: end reason `cost_cap` against error code
  `cost_cap_reached`.

**M8. The cost cap is off by default, and crashed sessions do not count toward it.**
*Where:* `MP-E6/tickets/MP-E6-C3-T01.md:58` (`daily_minutes_cap`, recommendation "owner
sets; `null` = no cap"); `MP-E6-C6-T02.md` (`minutes_today/0` sums `duration_s` from
`closed` index lines; crashed sessions have `end_reason: unknown`, and no duration rule is
given).
*Problem:* in the default configuration, "cost cap reached" never happens. When a cap is
set, every daemon restart during a session takes that session's minutes off the count. A
watch user doing turn-based Converse through flaky connectivity is the most likely
population to hit this.
*Fix:*

- In E6-OQ6 (DESIGN-E6), propose a non-null default, for example 60 min/day, so the
  feature is safe by default.
- In C6-T02, count an unterminated session's duration as last-record time minus
  `started_at`.
- Test "crashed session counts toward minutes_today".

The device dictation path (MP-E5-C8, D-relay from the watch) also has only per-session
byte caps and concurrency caps. State in DESIGN-E5 whether STT minutes need a daily cap.

### Minor

**m1. E-F9 / RQ-N4-4 can be answered from documentation.** Firebase documents receiving FCM
in Direct Boot mode. It needs `firebase-messaging-directboot`,
`android:directBootAware="true"`, and Play services 19.0.54 or later, and "the service
shouldn't access credential protected storage while running in direct boot mode"
(https://firebase.google.com/docs/cloud-messaging/customize-messages/android-direct-boot,
updated 2026-10-06, accessed 2026-10-06). The plan keeps keys in credential-encrypted
storage (MP-N4-C5-T01), so the right decision is: **do not** mark the service
direct-boot-aware. Messages are then handled after first unlock. Edit
MP-N4-C5-T02:62 ("if FCM delivers, keys are `Locked` → post fallback"): a non-aware
service never runs before unlock, and an aware one would crash on CE storage. Keep V-A3 as
a record row.

**m2. RQ-E6-1 (signed URL lifetime) is documented.** "Signed URLs are valid for 15 minutes.
The conversation session can last longer, but the conversation must be initiated within the
15 minute window"
(https://elevenlabs.io/docs/eleven-agents/customization/authentication, accessed
2026-10-06). Update `MP-E6/provider-research.md` §2 and narrow the MP-E6-C1-T01 spike step 2
to the `xi-api-key` header question. The adapter already fetches a URL per (re)connect,
which is correct.

**m3. Evidence for the WKWebView WebSocket trust claim is old and hedged.** `MP-N1/plan.md`
§5 cites https://developer.apple.com/forums/thread/104376 as evidence against T-B. Re-read
2026-10-06, the post is a 2018 DTS reply ("I don't think it will help for WebSocket. Last I
checked…"). Label it **[non-authoritative, 2018]**, and make MP-N1-C9-T01 prototype row P-x
(LiveView `/live` over `wss://` with a pinned self-signed certificate in both WebViews) the
deciding evidence. The conclusion is probably still right; the source does not prove it.

**m4. The ATS IP-literal claim cites the wrong page.** S16 says "Since iOS 17, ATS no longer
allows connections to IP addresses by default" and cites the `NSAppTransportSecurity` page.
That page's text (documentation JSON, accessed 2026-10-06) does not say this. The
statement comes from DTS forum threads (for example
https://developer.apple.com/forums/thread/747421). Cite the actual source, marked
non-authoritative, and keep N2-C10-T05 as the device row that settles it. Under T-A
(MagicDNS host name) the point does not matter. Under T-B with a raw tailnet IP it decides
the outcome.

**m5. `user_transcript{final: true}` drives the converse state machine, but the documented
event has no final flag** (MP-E6/plan.md §14; RQ-E6-6 is open). The adapter
(MP-E6-C2-T03) must synthesize `final`, for example from the following `agent_response`, or
the contract must change. Make that an explicit ticket line with a fixture test, so the
state table does not rely on an unverified field.

**m6. The watch queues answers; the phone refuses to.** `MP-N7/plan.md` §4/§8 send a failed
watch answer through `transferUserInfo`, which is delivered later and checked against
`expected_version` and age. `MP-N6/plan.md` §6 says answers "are **not** queued for
automatic later send in v1 (OQ-N6-1)". Either name the watch path as the deliberate
exception in OQ-N6-1, or drop the `transferUserInfo` fallback. DV-W4b already tests the
late-delivery guard. Keep it whichever way OQ-N6-1 goes.

**m7. Time Sensitive needs a capability that no ticket lists.** DESIGN-N4 D-3 may choose
`interruption-level: time-sensitive`, set on-device by the NSE (contract §5, no level in
clear). The app needs the Time Sensitive Notifications capability
(`com.apple.developer.usernotifications.time-sensitive`), and the NSE-set level needs a
device check. Add both to MP-N1-C6-T01 and to V-I5. Also confirm in V-I5 that a level set
in the NSE (not in the payload) is honoured.

**m8. The queue has no test for "event missed, timer recovers".** MP-E1 AC10 says a missing
`pr.merged` "is recovered on the next poll-triggered reconcile". The fallback timer
(`build_queue.reconcile_interval_seconds`) is designed in MP-E1-C3-T03, but its
verification table tests only event-triggered reconciles. Add: "no event; prerequisite
closed in the fake tracker; injected clock passes the interval; dependent promoted
exactly once". Mutation: remove the timer and the test fails. The freshness bound in
MP-E1-C4-T04 (`fetch_issue_raw_conditional(freshness_ms: …)`) correctly stops a stale
`ResourceStore` from masking a missed webhook.

**m9. A lost phone with no other paired device stays authorized.** `MP-N2/plan.md` §5
accepts this limit. "Tokens still expire, but the device key can mint new ones", so
expiry gives no protection, and push keys keep decrypting. D19 grants every instance.
State plainly in DESIGN-N2 that `aiur mobile revoke` on the machine (over SSH) is the
recovery. Recommend DESIGN-N6's optional "unlock before submit" as the default for writes.

**m10. E-F7 is still a search-engine summary.** The receive page, re-read 2026-10-06 (updated
2026-10-06), does not mention force-stopped apps. MP-N4-C5-T01 owns the re-read. Point it
at the troubleshooting page and the Android "stopped state" documentation, and keep V-A4 as
the deciding row.

---

## 2. Failure-mode coverage matrix

"Owner test" means a named ticket with a verification row. ✓ = verified in the ticket. ✗ =
a gap, with its finding.

| Failure mode | Behaviour defined in | Owner ticket and test | Status |
| --- | --- | --- | --- |
| Capability absence (push, build orders, voice, commands) | N1 §8; N4 §7.1; N5 §6; N7 §6; client-capability-model | N1 AC4 fixture tests; N4 AC-N4-8 (C3); N7-C4-T01 `casesMatchFixture` ("replacing `unavailable` with `ready` fails"); E1-C3-T03 unsupported tracker | ✓ |
| Stale data | N1 §8; N3 §5 row table; E1 "Stale data"; N7 §6 ages | N3-C4-T06 / DV-P5; E1 AC9; N7 AC7 / DV-W3 | ✓ |
| Restart recovery: queue | E1 "Restart recovery" | E1-C3-T07 AC11 (kill between promote and save → one call) | ✓ |
| Restart recovery: Commands | E2 §5 "Daemon restart mid-hold" | E2 AC2, AC4 ("holds across a daemon restart") | ✓ |
| Restart recovery: push outbox | N5 §5.4 | N5 AC-N5-5 (one send across restart); device-side `nid` dedup | ✓ |
| Restart recovery: journal | E4 plan row "Daemon restart mid-turn" → `daemon_restart_unknown` | E4-C1 tickets | ✓ |
| Daemon restart during a voice session | E6 §8 "sessions end (`transport_lost`)" | E6-C4-T01 (`:temporary`, transcript durable); provider cleanup ✗ (**M1**); mobile client UX ✗ (**M2**, **M7**); cap accounting ✗ (**M8**) | ✗ |
| Duplicate events | E1 "events are hints"; N5 ledger; contract `nid` | E1-C4-T06 "duplicated pr.merged → one attention"; N5 AC-N5-2/5/6; AC-N4-4 seen-`nid` | ✓ |
| Multiple paired devices | N2 §5; N4 §7.5 per-device seal | N2-C9-T02; V-M1; V-S2 | ✓ |
| Conflicting responses | E2 D11 first-answer and supersede; N1 A6 409 | E2 AC7/AC8; DV-P8; V-M1..M3; DV-W4b; E6 draft `stale` | ✓ (phone converse ✗ **M2**) |
| Offline or unreachable host | N1 §8; N3 §5; N6 §6 (no queued answer); N7 §8 | DV-P5, V-R3, V-R4, DV-W3; DV-P10 (network transition) | ✓ (watch/phone queuing mismatch, m6) |
| Locked device | N4 §7.2 | V-I3/DV-P3 (iOS); Android: V-A3 record (m1); local key loss ✗ (**M6**) | partial |
| Revoked device | N1 §8; N2 §5; voice-session §3.5 | DV-P9; V-S2/V-S3; MP-E5-C8-T02 (ends sessions); N7-C4-T04 `failed{revoked}`; N4-C3-T05 (relay down during revoke → pending) | ✓ |
| Relay down | N4 §7.1 `degraded(relay_unreachable)`; N5 §5.6 | N4-C3-T03 backoff and 429 tests; AC-N4-7 / V-R2 | ✓ |
| Push provider down or token invalid | N4-C2-T02 (APNs 400/410/429) | N4-C2-T01 "gone handle answers 410"; N4-C3-T03 "410 marks device gone" | ✓ |
| Provider accepts, device never displays | — | none | ✗ **M3** |
| Voice provider down | E6 §8 reconnect once, then `error` | E6-C2-T02 error mapping; mobile ✗ (**M7**) | partial |
| Cost cap reached | E6 §8 "max duration + per-day minute cap" | E6-C4-T01 (`cost_cap` at turn boundary); off by default and undercounted ✗ (**M8**); mobile UX ✗ (**M7**) | partial |
| Queue reconciliation after missed webhooks | E1 "Duplicate or missing events", fallback timer 60 s, freshness bound | E1-C4-T04 conditional fetch; timer-only test ✗ (m8) | partial |
| Escalation timeouts | E2 invariant N1; owner defaults 5 min ack / 15 min answer | E2 AC4 (exactly once, across restart), AC6 (empty roster → human) | ✓ |
| Watch cannot reach phone | N7 §8 | DV-W3, DV-W2b (no hang > 15 s) | ✓ |
| Watch shows only the fallback | — | DV-W1 required, no fallback design | ✗ **M5** |

---

## 3. Verified

Each item was checked against the pack and, where marked †, re-checked against the live
source on 2026-10-06.

1. **APNs NSE decryption.** E-A3/S2/S4: the NSE runs only with `mutable-content: 1` plus a
   visible alert, has about 30 s, and falls back to the original content. Apple's own
   example decrypts. The contract's uniform fallback alert (≤ 200 bytes) meets the "visible
   alert" condition (MP-N4-C2-T02 test "omit `mutable-content`" fails).
2. **Payload budget.** Contract §3: 2,400 B JSON + 65 B frame + 48 B HPKE = 2,513 B →
   ≤ 3,351 base64url characters + wrapper, below the 4,096 B APNs/FCM caps (E-A1, E-F1).
   The arithmetic checks out.
3. **Keychain sharing.** An access group shared by the app and NSE, with
   `AfterFirstUnlockThisDeviceOnly` (E-B3, E-B4), is in MP-N1-C2-T01 and MP-N4-C4-T01.
   Restart-before-unlock → fallback (V-I3).
4. **HPKE availability.** CryptoKit HPKE on iOS 17 / watchOS 10 (E-C1) matches KD-N4-8 and
   OQ-N1-2's iOS 17 floor. Tink RFC 9180 template (E-C2). The binding uses `info` with empty
   AAD, because Tink's public API exposes only `contextInfo`. That design follows from the
   cited source lines (E-C5). OTP 28 `:crypto` reproduces the RFC 9180 A.2.1 vectors (E-C4).
5. **Android keys.** Keystore master key without `setUnlockedDeviceRequired` (MP-N4-C5-T01)
   is correct for decrypting in `onMessageReceived` while the screen is locked.
6. **FCM.** Data messages, the 4 KB cap, 4 collapse keys / 100 pending, the Doze
   high-priority wake, deprioritization without a visible notification (E-F1..F5).
   Retractions use normal priority, so they do not count against the high-priority budget.
   The receive page's "short execution window" wording was re-read †.
7. **Wear OS bridging.** Default bridging, bridge tags, dismissal ids; bridged actions run
   on the phone. The decision to post a Wear-local notification and exclude tag
   `aiur-command` (MP-N7-C3-T04) follows from the cited page.
8. **watchOS networking.** WebSockets are blocked for ordinary apps (TN3135, revised
   2026-07-16). The phone-as-network-path design and DV-W9 ("passes only on simulator"
   guard) are sound.
9. **WebView microphone.** iOS `getUserMedia` from 14.3 plus
   `requestMediaCapturePermissionFor`. Android `onPermissionRequest` with an origin check
   and `RECORD_AUDIO`, with a mutation test (MP-N1-C4-T05). A secure-context dependency on
   RQ-TRANSPORT (DV-P7, N2-C10-T05).
10. **Cleartext.** Android cleartext is off by default for API 28+ (S31). HTTPS is a hard
    prerequisite, owned by RC-15/MP-N2-C10.
11. **Expo plus extra targets.** `expo-apple-targets` is correctly marked
    **[non-authoritative, community]**. It is gated by N1-RQ3 and the throwaway prototype
    MP-N1-C9-T01 (survival of `expo prebuild --clean`, entitlements, NSE memory).
12. **App Review.** 2.1(a) and 4.2 are quoted accurately. The demo-mode conclusion for
    public review and the internal-TestFlight / Play-internal escape (S18, S28) are
    correct, and the plan states that no feature set guarantees approval.
13. **ElevenLabs Agents.** Signed URL obtained server-side (†, and 15-minute validity, m2).
    Client tools over the daemon socket. `record_voice` default on, with a preflight that
    refuses to start (E6 AC4). Default retention 2 years, plus `DELETE` and a persistent
    retry queue (C2-T04). Custom LLM and server tools rejected because they need a public
    URL. The paid spike gate (E6-OQ9) blocks the unverified items.
14. **Relay visibility.** Contract §1 tables match the provider and relay facts (E-A6 team
    key, E-R1, E-R4). Khala and `hooks.aiur.dev` were rejected with repository evidence.
15. **Escalation.** E2 AC4 states "exactly once after `executor_answer_ms` … across a daemon
    restart". Deadlines are recomputed from `routed_at`.
16. **Queue failure modes.** Conditional promotion write, outcome-from-observation after a
    crash (AC11), fail-closed on a lost store with `aiur queue recover`, a GitHub budget
    hold that pauses writes.
17. **Journal.** Restart marks `daemon_restart_unknown`; `gap` records on write failure;
    reconnect with `after: pos` gives no gap.
18. **Honesty.** No document promises an always-awake app, guaranteed delivery or
    background fetch. Latency is to be reported as measured distributions with counts.

---

## 4. Physical-device validations required before mobile counts as complete

All rows run on physical devices. Simulator or emulator results are not evidence. Record
the device model, OS build, app/relay/daemon SHA, network path and timestamps. A required
row that fails blocks its feature until the plan changes and the row is re-run. The run
tickets are MP-N4-C7-T02, MP-N1-C10-T01/T02, MP-N2-C9-T02, MP-N2-C10-T05, MP-N3-C4-T06,
MP-N7-C6-T01 and MP-N7-C6-T02.

### Pairing and transport (MP-N2)

- **N2-C10-T05:** ATS/cleartext acceptance for the chosen transport (T-A or T-B).
  - LiveView `/live` and `/voice` WebSockets over that transport in both WebViews.
  - The WebView mic in a secure context.
  - The IP-literal behaviour under T-B (m4).
- **N2-C9-T02:** pair, relink a scanned QR twice, change instance URL, revoke one device,
  unpair-all; a second device is unaffected.

### Push delivery (MP-N4; N1 DV-P1..P4 merged here per M4)

- **V-I1 / V-A1:** a locked-after-first-unlock device shows the decrypted title and
  subtitle. Record p95 latency.
- **V-I2 / V-A2:** a system-terminated app shows the decrypted notification.
- **V-I3 / V-A3:** restart without unlock.
  - iOS: fallback, then the real Command after unlock and tap.
  - Android: record the result (m1).
- **V-I4:** iOS force-quit. Record; RQ-N4-3.
- **V-A4:** Android Settings → Force stop gives no delivery, and the warning shows on next
  launch.
- **V-A5 / V-A6:** Doze high against normal priority; 20 high-priority sends a day with no
  deprioritization.
- **V-I5:** Low Power Mode plus Focus. Time Sensitive set by the NSE is honoured (m7).
- **V-I6, V-L1:** NSE `removeDeliveredNotifications` retraction (RQ-N4-5); a payload at the
  2,400 B cap.
- **NEW V-K1 (M6):** invalidate the Android Keystore master key (remove the lock screen on
  an affected OEM). The fallback is posted and the machine shows "notifications broken".
- **DV-P2:** corrupted ciphertext and a decrypt delayed past 30 s give the placeholder,
  with no crash and no ciphertext shown.
- **N1-C9-T01 P2:** NSE time and peak memory for HPKE decrypt (N1-RQ4), median of 20.

### Delivery policy and staleness (MP-N4/N5)

- **V-R1:** 3 h in airplane mode, then reconnect: at most one per stream plus one digest,
  and no resolved Commands.
- **V-R2:** relay down for 2 h.
- **V-R3 / V-R4:** machine offline / tailnet off when the user taps: sealed summary plus
  "Can't reach", then Retry.
- **V-PR1..PR3:** milestone jump, regression, completion.
- **NEW V-R5 (M3, if reminders are adopted):** a dropped first push (device offline past
  the APNs single-store window). Exactly one reminder arrives, and none after resolution.

### Security and privacy (MP-N4)

- **V-S1..S3, V-P1:** forged, replayed and expired payloads are not shown as real content;
  unpair one device / unpair all leaves no provider request and no handles; relay and
  provider captures contain no identifiers or summary text.

### Multi-device and conflicts

- **V-M1..M3:** phone B shows "Answered on another device"; after a dashboard answer the
  phone cannot resubmit; a human supersedes an undelivered Executor answer.
- **DV-P8:** two answers within 1 s: one wins, the loser sees the winner.
- **DV-P10:** Wi-Fi → cellular during submit gives one recorded answer.

### App shell and meta-dashboard (MP-N1/N3)

- **DV-P5 (N3-C4-T06):** `unreachable`, `unavailable` and `stale` are distinct, each with
  its age.
- **DV-P6:** WebView at 320–430 px.
- **DV-P7:** WebView dictation on HTTPS; `unavailable` with a reason on HTTP.
- **DV-P9:** session expiry gives one silent re-bootstrap; revocation wipes the keychain
  and cookies.
- **DV-P11..P13:** a notification for instance 2 opens over instance 1; permissions
  denied; 8 h background battery (advisory).

### Notification-to-context (MP-N6)

- **V-N1..N4:** the tap lands on the exact Command with the mic **not** active; no
  duplicate screen; a resolved Command shows its resolved state; a cold start lands on the
  Command with no flash of a generic inbox.
- **NEW V-N5 (M2/M7):** during phone Converse:
  - restart the daemon: `transport_lost` copy, and the transcript stays intact;
  - reach the daily cap: `cost_cap` copy, with no retry offered;
  - revoke the device: `auth_changed`.

### Apple Watch (MP-N7-C6-T01)

- **DV-W1:** a forwarded notification shows the decrypted text. Its pass criterion is
  revised per M5.
- **DV-W1b:** two taps to the card, with no mic indicator.
- **DV-W2 / DV-W2b:** wake through `sendMessage`, including with the iPhone app force-quit.
- **DV-W3:** "Needs iPhone nearby".
- **DV-W4:** exactly one answer with `client.surface: "watch"`.
- **DV-W4b:** a late queued answer meets a changed Command and reports `stale` (keep this
  row even under m6).
- **DV-W5:** dictate and review before Send.
- **DV-W6:** turn-based Converse latency against the DESIGN-N7 figure.
- **DV-W9..W13:** the WebSocket stays `.waiting` on the device; dynamic options on a
  forwarded long-look; removal of a forwarded notification when the Command resolves
  elsewhere; no audio or credentials left in the watch container; complication refresh
  (advisory).
- **V-W1..V-W2** (N4) are run in this ticket.

### Wear OS (MP-N7-C6-T02)

- **DV-W2..W6** (Wear columns); **DV-W12, DV-W13**.
- **DV-W7 / W7b / W7c:** exactly one notification with the Wear app installed; dismissal
  sync; default bridging when the Wear app is absent.
- **DV-W8:** "Needs phone"; tailnet over a phone proxy is advisory.
- **V-W3 / V-W4** (N4): dismissal id and RemoteInput support are recorded.

### Voice provider (MP-E6-C1-T01, paid spike, before C2)

RQ-E6-1 (now header auth only, m2); RQ-E6-2 client-tool timeout; RQ-E6-3 whether retention
`0` / `DELETE` actually deletes; RQ-E6-4 context size and first-audio latency; RQ-E6-5 echo
cancellation on a phone speaker; RQ-E6-6 partial versus final transcripts (m5).

### Report rule

Every UNVERIFIED item must be resolved in a dated update to `platform-evidence.md` /
`framework-evidence.md`: E-B6 / S39, E-F7, E-F9 / RQ-N4-4, E-W1, RQ-N4-3 / 5, S35 / N7-RQ5, N7-RQ1 / RQ3 and
N1-RQ1..RQ6.

Each latency is a measured distribution with units and a count. Each missing device slot
is recorded as "not validated on <slot>", never skipped.
