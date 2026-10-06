# Phase D cross-review: privacy and security

Reviewer: independent Phase D cross-reviewer (privacy and security lens), 2026-10-06.
Base: `45a290e3`. Scope: brief §3 and §7, `context-and-decisions.md`,
`phase-b-reconciliation.md`, every file in `contracts/`, and the plans and tickets of
MP-N2, MP-N4, MP-N6, MP-E2, MP-E3, MP-E4, MP-E5, MP-E6, MP-E7, MP-R3 and MP-R2-C7.
Ticket ID spelling (T1 or T01) is ignored.

**Counts:** 2 blockers, 6 majors, 10 minors.

Each finding names the file and section or ticket, says what is wrong, and gives the
fix: which contract or ticket changes, and how.

---

## Blockers

### B1. A same-user agent can become the "human". Nothing in the pack names this threat.

**Where:** `contracts/pairing-and-instance-registry.md` §2 ("separation rules") and §5
(machine store); MP-N2-C1-T01..T03 (store library, `machine_key`, `devices.json`);
MP-N4-C3-T03 ("same OS user, 0600"); `contracts/command-request-and-resolution.md` §4
("Authority is unchanged").

**Problem.** The machine store (`~/.config/aiur/machine/`) holds the Ed25519
`machine_key` seed, `devices.json` (token hashes, every `send_secret` and
`device_push_secret`) and `pairing.json`. Modes 0700/0600 protect against other OS users
only. Agents run as the same OS user:

- Claude workers default to `permission_mode: bypassPermissions`
  (`src/lib/aiur/claude/config.ex:9` at `45a290e3`). They have full read and write
  access to `$HOME`.
- Codex `workspace-write` limits writes, not reads. A Codex worker can read `machine_key`.

So one worker on one repository can do these things:

1. Write a row into `devices.json` with its own P-256 public key. The contract §5 allows
   a direct write while the gateway is down, and the lock is advisory. The worker then
   mints a token through `/v1/token`. D19 gives that token **full operator authority on
   every instance on the machine**, including instances of other repositories.
2. With that token, answer `human_required` Commands as `:operator`
   (`POST /api/v1/device/commands/:id/answer`, MP-N6-C1-T03). This defeats D9 and D12.
3. With `machine_key` and a `send_secret`, send pushes to the operator's phone that are
   correctly signed and sealed (phishing from inside the trusted app).

The pack says "Pairing secrets, device keys and access tokens are never written to …
any log" and "a device never receives the Erlang cookie". All of that is true, but none
of it protects against this threat. MP-E3 plan §7 is the only document that states the
same-UID trust boundary ("it is not attestation").

**Fix.**

- Add a **§2.1 "Threat model: same-user processes"** to the pairing contract. It must
  state plainly that any process running as `$USER` (agents included) can read the store
  and get D19 authority. The pairing design protects against network attackers and lost
  phones, not against local agents.
- Add owner item **DESIGN-N2 Q8**: accept this risk, or require one mitigation before
  `mobile.enabled` can be true. Possible mitigations:
  - (a) Agents run as a separate OS user (strongest; it is a documented setup option).
  - (b) The gateway holds `machine_key` in the OS keyring (Secret Service or Keychain)
    and is the only process that signs. Instances verify `devices.json` rows by a
    per-row MAC that the gateway computes with a key the keyring holds. This raises the
    cost but does not stop a determined same-UID process.
  - (c) The daemon adds the store paths to the agent deny configuration where a harness
    supports it (Codex sandbox read-deny, Claude `permissions.deny`), and the docs say
    that Bash bypasses Claude deny rules.
- MP-N2-C1-T02: the gateway journals every row it writes. The gateway and
  `aiur mobile status` raise a needs-attention alert for any `devices.json` row that has
  no matching `paired` journal entry (a cheap way to detect tampering).
- MP-N2-C9 docs: the pairing guide says the same thing in user words.

### B2. `operator_relayed` can replace a direct operator answer (the #3006 bug, written into the contract)

**Where:** `contracts/command-request-and-resolution.md` §6 rules 1, 3 and 4;
MP-E2-C3-T01 (`human_actor?/1` = `:operator` or `:operator_relayed`); MP-E2-C3-T02
(`supersede/3` "human actors only"); MP-E2-C6-T01 (self-answer guard); MP-N6-C1-T03
(`replaceable`).

**Problem.** `operator_relayed` (#3005/#3006) is an answer that the **Executor** writes
through `aiur operator-relay-answer`, with a quote from the operator. The contract
classes it as a human actor for supersede. Effects:

- Rule 3 lets a relayed answer supersede *any* undelivered answer, including a direct
  `:operator` answer from the dashboard, Stream Deck or a phone. Live PR #3006 had to
  fix this exact bug ("relay revise/supersede refuses to replace an active direct
  operator answer"). MP-E2-C3-T01 places a new guard in `supersede_current/4` that
  checks only `:executor`. If it is written as specified, it can bypass or reorder
  #3006's guard.
- `ConflictSummary.replaceable` is "caller is a human actor". It therefore tells a
  relaying Executor that it may replace a direct operator answer.
- Rule 7 (`revise`, "no undelivered guard") does not say that a relay may not revise a
  direct answer.
- MP-E2-C6-T01's guard ("Executor may not answer a Command it raised itself") is only in
  the executor clause. With `executor.relay_operator_answers: true`, the Executor can
  answer its own `human_required` Command as `operator_relayed`.

**Fix.**

- Contract §6: add **rule 4a**: "A relayed answer never supersedes or revises a direct
  operator answer (`{:conflict, {:direct_operator_answer, action_id}}`). A direct
  operator may supersede a relayed answer. Relayed against relayed follows rule 5."
  Add **rule 4b**: "An Executor-originated Command refuses `operator_relayed` answers."
  The answer to an Executor's own question must come from a surface the human
  authenticates on.
- Split `human_actor?/1` into `direct_human?/1` (`:operator` only) and
  `human_attributed?/1` (adds `:operator_relayed`). `replaceable` and every supersede
  guard use the precedence rank `direct_operator > operator_relayed > executor`, not a
  boolean.
- MP-E2-C3-T01 and MP-E2-C6-T01 add these tests. Each one must fail when its guard is
  removed:
  - "relay supersede of a direct operator answer is refused";
  - "relay revise of a direct operator answer is refused";
  - "operator supersedes a relayed answer";
  - "relay answer to an executor-originated Command is refused".

  Rebase on #3006 and keep its guard. The C3-T01 guard sits beside #3006's guard and
  does not replace it.
- Resolve `chunks.md` MP-E2-C3 "Open research" (whether the Executor may supersede a
  relayed answer) with the rank above: no.

---

## Majors

### M1. A revoke does not reach live channels in instance BEAMs. The tests cannot fail.

**Where:** pairing contract §4.4 ("the writer broadcasts `{:devices_revoked, …}` on
PubSub topic `devices:revoked`"); MP-N2-C7-T01/T02 (CR-R2-5); MP-R2-C7-T05 (chosen
design: `Phoenix.PubSub.local_broadcast`; test 3 broadcasts in-process).

**Problem.** The revoke writer is the gateway (a separate machine-level process) or the
CLI while the gateway is down. `local_broadcast` reaches only subscribers in the
writer's own BEAM. Instances are other BEAMs, so `events:feed` channels never get the
message. R2-C7-T05 test 3 sends the broadcast inside the test BEAM. That fixture skips
the step that fails in production (AGENTS.md: "fixtures built to avoid the failure
mode"). Real revocation latency for the event feed is therefore the 300 s token backstop.
It is not "within seconds" as the ticket's user value says. `/voice/device` is safe
because MP-E5-C8-T02 polls the store every 15 s.

**Fix.**

- Pairing contract §4.4: replace the broadcast sentence. Each instance runs a
  `Machine.Store.Watcher` (new, MP-N2-C1-T03). It stats `devices.json` (mtime, size,
  inode) every 2 s and `local_broadcast`s the removed ids **in that instance**.
- State the latency budget per surface in a new contract table:
  - HTTP: next request;
  - sockets and LiveView: ≤ 2 s plus the channel round trip;
  - push: next send;
  - already-delivered notifications: not recalled.
- MP-R2-C7-T05 test 3 changes to: write `devices.json` without the watcher process
  being told (as the gateway or CLI would), then assert that the channel exits within
  the budget.

### M2. A revoked phone's open dashboard WebView can still write

**Where:** MP-N2-C6-T02 ("Revocation push-down … Minimum guarantee: next authorize call
fails"); pairing contract §4.4 (lists only `events:feed` and `/voice/device`).

**Problem.** A device session in the WebView runs a LiveView. Writes (the composer
send, Command answers, decisions in `/commands`) are `handle_event` calls. These check
`dashboard_writable` (`handle_writable_event`) but do not check the session identity
again. `identity/2` runs only where financial data re-authorizes. A revoked device keeps
an open LiveView that can send messages to agents and answer Commands until the socket
drops or the instance restarts. For a lost phone that is open, the time has no limit.

**Fix.**

- MP-N2-C6-T02: give device sessions a `live_socket_id` (`"device_session:" <> device_id`).
- On a watcher revocation (M1), call `Endpoint.broadcast(live_socket_id, "disconnect", %{})`.
- Add a `on_mount`/`attach_hook(:handle_event)` check that refuses writes from a device
  kind context whose row is inactive.
- Tests, each of which must fail when its guard is removed:
  - "revoked device LiveView is disconnected within budget";
  - "handle_event write from a revoked device session is refused".
- Add `LiveView` to the latency table in the pairing contract.

### M3. Machine-wide device tokens are accepted over cleartext HTTP

**Where:** MP-N2-C6-T01 (`dashboard_basic_auth` accepts `aiurd_` bearers on every
`:dashboard_auth` route of every listener); pairing contract §6.2 and §8.1 rule 2
(`allow_cleartext_overlay`).

**Problem.** One access token is valid on **every instance on the machine** (D19) for
15 minutes. The plain HTTP listener (`server.host`) may be bound to a LAN address with
Basic Auth. Device bearers are accepted there too. `allow_cleartext_overlay: true`
trusts the operator's statement that the network is an encrypted overlay, and nothing
checks it. A token sniffed on one instance's cleartext port gives write authority on
every instance.

**Fix.**

- MP-N2-C6-T01: accept device bearers only on these listeners:
  - (a) the HTTPS listener (MP-N2-C10-T01);
  - (b) loopback;
  - (c) the HTTP listener when `allow_cleartext_overlay: true` **and** the bound address
    is in `100.64.0.0/10` or `fd7a:115c:a1e0::/48` (Tailscale ranges), or the operator
    sets an explicit `transport.cleartext_overlay_cidrs`.

  Otherwise answer `401 device_auth_insecure_transport`.
- Test: "device bearer on a non-loopback plain-HTTP listener is refused". It must fail
  when the listener check is removed.
- MP-N2-C10-T01: the bind matrix in MP-R3-C1-T01 gains this case.

### M4. Command actor identity is asserted by the caller. The contract implies it is enforced.

**Where:** command contract §4 ("Authority is unchanged … The Executor may still answer
only delegable, reversible Commands"), §6 (`actor`), §9 (surfaces table).

**Problem.** `DecisionStore.answer/5` trusts `opts[:actor]`. HTTP surfaces derive the
actor from credentials. The Executor has other paths:

- the Erlang cookie: today's Executor runbook resolves blocking decisions with
  `DecisionStore.answer` over RPC;
- `~/.aiur/.env` Basic-Auth credentials;
- `relay_operator_answers`.

Through any of these it can record `:operator` on a `human_required` Command. The
contract text reads as if `human_required` is a security boundary against the Executor.
It is a policy on the Executor's normal tools. The notification flow (N4/N5) then
retracts the human's push on the terminal slug, and the human never sees that an agent
answered.

**Fix.**

- Command contract §6: add `actor_source`. The **entry point** sets it, never the
  caller:
  - `:dashboard_session`, `:basic_auth`, `:device`, `:streamdeck`;
  - `:supervisor_api`, `:executor_cli`, `:relay_cli`;
  - `:rpc` for any in-BEAM call without a surface.

  The dashboard timeline, the Command view (MP-N6-C1-T01) and `ConflictSummary` show it.
- Add the sentence: "`human_required` is enforced against the Executor's CLI and API
  surfaces, not against a same-user process with the cookie (see pairing §2.1)."
- MP-E2-C3-T02 gains the test "an answer with no surface context is recorded
  `actor_source: :rpc`".

### M5. Transcripts are served to phones without masking

**Where:** `contracts/conversations-transcripts-anchors.md` §12; MP-E4 plan §7 ("No
secret scrubbing is promised"); MP-N6/MP-N3 (the device fetches and caches context).

**Problem.** The journal stores raw agent output: tokens printed by `env`, `.env` cats,
URLs with credentials. The History API serves it to the dashboard and, through device
bearers, to phones and WebViews, where it can be cached. Voice already redacts the
same text before the provider (`SecretRedactor`, MP-E6-C4-T03). Transcript reads do not.
The brief asks for appropriate handling of secrets. "The view must say transcripts may
contain secrets" is not handling.

**Fix.**

- Conversations contract §7: `list_entries` takes a `principal`. For `{:device, _}`
  principals, every `body` and `output` passes `SecretRedactor.redact/1` and
  `redact_urls/1`, and the entry carries `redacted: true` when something changed. The
  journal stays unredacted (logs are never rewritten, D15).
- The dashboard (Basic Auth) default is an owner choice. DESIGN-E4 decision 6: mask by
  default, with "reveal" for loopback sessions.
- MP-N6 and MP-N1: phones never persist entry bodies to disk. They keep them in memory
  only, and wipe them on revoke.
- Test in MP-E4-C2 (History API): "device principal receives redacted body; journal
  bytes unchanged".

### M6. Agents can forge "operator" lines in transcripts

**Where:** MP-E4-C1-T01 entry mapping (`:user` → `operator_message`, role `operator`);
conversations contract §5 ("`operator_message` is written when the input reaches the
agent … at aiur's delivery point"); MP-E3-C2-T01 (Executor `:user`/`queued_command` →
`executor_operator`).

**Problem.** The Remote-Control display path and the Executor tailer read provider JSONL
files under `~/.claude`. These files are agent-writable (see B1). Claude `user` records
also carry tool results and the aiur prompt. Under C1-T01, any `:user` record becomes an
operator message. A worker can append a record that renders on the phone as an operator
instruction ("Operator: approved, merge it") next to a Command the human is deciding.
This also contradicts the contract §5 rule.

**Fix.**

- MP-E4-C1-T01: role `operator` comes **only** from `MessageHandler.observe_operator_delivery/4`
  (daemon evidence, `refs.delivery_id` set). A provider `:user` record that does not
  match a daemon delivery maps to `kind: system`, `role: "provider_input"`, and the view
  labels it as such.
- Executor (MP-E3-C2-T01): `executor_operator` stays, because it is the operator's own
  session. The binding is accepted only for a `transcript_path` that passes the M8
  check.
- Test: "a provider user record with no matching delivery is not an operator_message".

---

## Minors

**m1. The relay forwards free fallback text.**
MP-N4-C2-T01/T02 put the envelope `fallback` into `aps.alert` verbatim. A daemon bug, or
a holder of a `send_secret`, can show any clear text, which Apple can read. Fix: the
relay pins the fallback per `app_topic` (env `AIUR_RELAY_FALLBACK_*`). It refuses an
envelope whose fallback differs, or ignores the field. Add a test. In notification
contract §1, change "not trusted for … authenticity" to: "a relay or anyone with the
APNs key can show the uniform fallback or any clear alert when the NSE does not run.
Signed content is the only authentic content."

**m2. The metadata table leaves out some items.**
Notification contract §1 does not list these:

- `k` (`kid`) in the clear provider payload, which Apple and Google see. It is stable
  per device and machine.
- The FCM `collapse_key` `a`/`b` (MP-N4-C2-T03). It tells Google "Command or not". The
  table calls it "opaque".
- `push_class` and the priority. Together they tell the relay and Apple when a blocking
  Command occurs.
- The **device IP** that the relay sees at `POST`/`DELETE /v1/handles`.

Add these rows. MP-N1-C8-T02 (store privacy answers) copies them.

**m3. Free text in the export feed and in notification titles.**
`human-needed` exports `attrs.short_label`. That is agent-authored text (40 chars of
`context.short_summary`). It contradicts events contract §1 rule 3 and §4.2 ("no titles,
messages") and MP-R2-C7-T04 ("no free text"). Fix: export `short_label` only in the
sealed push, not in the feed attrs (clients read it from the Decision API). The phone
renders `summary.title` with a "from agent" style, because it is agent text inside a
trusted app.

**m4. Voice confirmation must stay on the client.**
`voice-session.md` §5.3 leaves E6-OQ1 open ("whether speech alone may confirm"). Add an
invariant: a draft moves to `confirmed` only by a `confirm_draft` event from the
authenticated client socket, never from a provider `tool_call` or a provider
transcript. MP-E6-C5-T02 adds the test "no provider tool can confirm a draft". Also,
until E6-OQ10 is answered, voice-assistant consults render as plain operator messages
(conversations §5). Render a neutral "via voice" tag from day one, so that model text
is never shown as the human's words.

**m5. The instance-dashboard QR.**
MP-N2-C8-T02 shows the pairing secret to any Basic-Auth session. That includes a
read-only dashboard and a cleartext HTTP origin. Because of D19, the paired device can
then write on *other* writable instances. Fix:

- hide the QR when `dashboard_writable` is false;
- hide it on non-loopback plain-HTTP origins;
- add both cases to its test list;
- record them in DESIGN-N2 Q5.

**m6. `Machine.Store.sign/1` signs any message.**
It is generic (pairing §5, CR-N4-2), and the QR signature has no domain prefix (§4.0).
Fix: `sign(purpose, bytes)` with purposes `:qr | :registry | :push`. Each purpose has a
fixed ASCII tag (`aiur-qr-v1\0`, …). Push keeps its existing tag. Update the MP-N2-C4-T03
and MP-N2-C5-T05 vectors.

**m7. Bearer values in URLs.**
The `/device-session/<code>` path segment is in the Phoenix request log (MP-N2-C6-T02
tests only the voice ticket for log exposure). The device voice ticket can be used again
for 60 s (voice-session §3.5). Fix:

- filter the path in the request logger, with the test "device-session code never
  logged";
- make the voice ticket single-use (record its sha256 in ETS on connect, as for the
  session code).

**m8. Device attribution is not consistent.**
- Command contract §6: `device:<id>`.
- MP-E2-C3-T02: `phone:<device_id>`.
- Existing `:dashboard_auth` JSON writes (`/api/v1/:issue/messages`) accept device
  bearers but record no device id.

Fix: one spelling, `device:<id>`. Controllers that write read `assigns.auth_actor`
(MP-N2-C6-T01 sets it). MP-E7-C3-T03 gains a test: "message sent with a device bearer
records device_id".

**m9. Lock screen.**
Decrypted summaries ("Pick a schema migration strategy before #2731…") appear on the
lock screen and on the watch. Document this in DESIGN-N4. Make it a choice: iOS
`hiddenPreviewsBodyPlaceholder`, Android `VISIBILITY_PRIVATE` with a public version that
uses the fallback text. The default proposal is "hide body when locked".

**m10. Unsafe paths that the pack does not specify.**
- `aiur-pair:` must be accepted only from the in-app scanner. Do not register it as an
  OS URL scheme. A tapped link must not start pairing with an attacker's machine.
  Pairing shows the machine label and the key fingerprint and needs an explicit
  "Pair". Add this to MP-N1-C4-T01 and MP-N2-C5-T06 tests.
- **M8 (merged here as a minor):** MP-E3-C1-T02/C2-T01 tail any `transcript_path`
  that a hook names. A same-user holder of the hook token can point it at another
  session's JSONL file, and the daemon then serves that file to phones. Fix: canonical
  path under `~/.claude/projects/` or `~/.codex/sessions/`, regular file, not a symlink,
  owned by `$USER`, with a basename that matches `session_id`. Add a test.
- Also: the loopback `remote_ip` check (MP-E7-C6-T01) is not a boundary behind a local
  tunnel or proxy. The token is the boundary, and the docs must say so.
- **voice-session §10** (the normative disclosure source) leaves out Apple and Google
  system dictation: watch D-sys (MP-N7-C4-T02, the recommended v1) and phone keyboard
  dictation in the WebView composer. MP-N1-C8-T02 and MP-N7 already cover it, but §10
  is the copy source. Add a row "System dictation (watch/phone keyboard): audio to
  Apple or Google under their policy; aiur receives text only".

---

## Tickets on a sensitive path whose test would not fail if the check were removed

| Ticket | Missing or inert test |
| --- | --- |
| MP-R2-C7-T05 | Test 3 simulates the revoke broadcast in-process (M1). |
| MP-N2-C6-T02 | No test of a write after revoke on an open LiveView (M2). |
| MP-N2-C6-T01 | No transport restriction test (M3). |
| MP-E2-C3-T01 / C6-T01 | No relay-versus-direct or relay-self-answer test (B2). |
| MP-E4-C1-T01 | No provenance test for the operator role (M6). |
| MP-E4-C2 (History) | No redaction test for device principals (M5). |
| MP-N4-C2-T02 | No test that the relay pins the fallback (m1). |
| MP-E3-C2-T01 | No `transcript_path` validation test (m10). |

---

## Verified OK

- **Provider keys stay on the daemon** (voice V4). The ElevenLabs key is not in device
  paths. The unwired sidecar TTS key path is flagged for deletion (MP-R5-C4-T02).
- **Key separation is correct.** The device auth key (Secure Enclave or Keystore P-256,
  cannot be exported), the push key (X25519, one per device per machine) and access
  tokens (only sha256 stored) are independent. A device never receives
  `AIUR_DASHBOARD_PASSWORD`, `AIUR_SUPERVISOR_TOKEN`, `GITHUB_TOKEN` or the cookie
  (pairing §2).
- **Pairing protocol.** Single-use pairing secret with a 10-minute expiry. HMAC proof,
  so the secret is never sent. Claim lockout. Nonce consumed on the first attempt.
  Machine key pinned with no silent re-pin. The settings page needs a one-time token
  and is never served on the device listener (MP-N2-C8-T01).
- **Push crypto.** HPKE `info` binds `device_id` and `kid`. Detached Ed25519 signature
  over the exact bytes. Duplicates dropped by `nid`, `seq` and `expires_at`. FCM is
  data-only with no `notification` block (test). Uniform fallback. The relay never logs
  `sealed`; retention is capped at 7 days and the relay refuses to start above it.
  The outbox drops jobs for revoked devices (MP-N4-C3-T03/T05).
- **Device Command API.** `device_id` comes from the token, never the body
  (MP-N6-C1-T03 test). Basic Auth alone does not open device routes. Route order is
  tested against the `/api/v1/:issue_identifier` catch-all. Idempotent retry uses the
  same key. Stale version maps to 409. The read-only dashboard refuses answers.
- **Device voice path.** It re-checks the store every 15 s and on stop/end
  (MP-E5-C8-T02, mutation-checked). The ticket is not logged. The read-only dashboard
  refuses the ticket and the socket. Legacy auto-submit topics are refused on the
  device socket.
- **Command authority on the normal tools** (but see B2 and M4). The Executor cannot
  answer its own Command (CLI path). `defer` is refused for `human_required`. The
  Executor cannot supersede a direct human answer. Native `isSecret` questions are
  released, not captured. `human_needed` carries no question text.
- **Event export.** Topics and fields are allowlisted. There is no publish endpoint.
  Filters can only narrow the result. The webhook path is never used for the feed.
- **Bind and Tailscale.** The MP-R3-C1-T01 route and socket census and the bind matrix
  (`0.0.0.0`, `::`, `127.0.0.2`) are in place. The gateway binds loopback by default.
  The HTTPS listener never binds while `mobile.enabled` is false. "Reachability is not
  authorization" is in the contracts and the docs. The Certificate Transparency
  exposure of `tailscale cert` is stated (RQ-TRANSPORT).
- **Voice disclosure** (except the m10 row). Encrypted push is explicitly not a claim
  that voice is local. The `record_voice=false` preflight refuses to start. Zero
  Retention needs Enterprise, and the docs say so. `SecretRedactor` runs before the
  provider and before storage.
- **Deep links.** `aiur://` only navigates, uses an allowlist, carries no credentials,
  and every screen re-fetches with the device credential (MP-N1-C4-T01).
- **Executor hook endpoint.** Token in a 0600 header file, never in argv, compared in
  constant time. Wrong token gives 401 with no change of state (MP-E3-C1-T02).
