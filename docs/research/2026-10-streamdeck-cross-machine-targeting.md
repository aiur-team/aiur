# Stream Deck cross-machine targeting

Research date: 2026-10-27. Scope: research only for #6903; no runtime,
configuration or tracker-relationship changes. Recommendations below are proposed
contracts, not implemented behavior or a provider selection.

## Recommendation and source hierarchy

Use [#6901](https://github.com/aiur-team/aiur/issues/6901) and the
[unified plan at PR #6902](https://github.com/aiur-team/aiur/blob/3f231bf637c25637affc737518b063530e7f9ee5/docs/plans/2026-10-27-001-feat-multi-repo-multi-machine-unified-plan.md)
as the parent requirements: R15–R22, phase 4 targeting, phase 6 voice, and Q4.
Keep SD-207's direct, one-instance-at-a-time fleet connection. For voice,
recommend Q4's **local-daemon broker**: capture/playback on the deck machine,
provider calls on the local daemon, and bounded context plus confirmed delivery
at the selected remote instance. This requires new broker wiring; it does not
exist today. Direct remote voice remains the simpler alternative if Kevin
prefers credentials on each destination. Neither choice blocks non-voice work.

Make the Executor an explicit, capability-gated target, subject to Kevin's
approval of the MP-R6 amendment in question 7. Never infer Executor from the
absence of a selected ticket. Never redirect a failed target to another one.

The source inventory is code at `3e3badb33ce894fcc286dc8bbc2f0d0b9f8158c7`,
plus these versioned planning inputs, which are not evidence of shipped code:

- [Stream Deck pack, PR #6023](https://github.com/aiur-team/aiur/tree/41d11360ece85b93fb0004d6b293d02cf916acae/docs/plans/2026-10-23-streamdeck-redesign): SD-207, SD-406, SD-407, group B/D findings, and the parent redesign plan.
- [Multi-instance pack, PR #5958](https://github.com/aiur-team/aiur/tree/9a81c5409c3b0d66cbabc255e8b2605d5b4007ac/docs/plans/2026-10-23-multi-instance-control): MIC-002/003/006 and decisions on direct control, registry and Executor identity. Its merged parts must be checked against current code.
- The current #6036, #6046 and #6047 contracts were read separately; their old line numbers and prerequisite states are historical.

Propose making #6903 a research sub-issue of #6901, with this report supplying
phase 4 details and Q4 evidence. Do not block #6036 on the parent plan's open
UI/design questions. The unified plan currently puts phase 4 after phase 3 data;
amend that dependency for SD-207's registry-only slice: it needs no aggregated
dashboard or mobile gateway. #6047 consumes this research; final voice wiring
still waits for provider choice and the relevant voice APIs.

## 1. Navigation: machine, instance and repository

Evidence: `packages/streamdeck/src/main.ts`, `main()`'s `connectDaemon` and
`scheduleConnect`, capture one environment-selected daemon and reconnect with
backoff. `packaging/npm/aiur-cli/libexec/engine/remote.sh` already supplies
`load_remote_instance`, `validate_remote_url` and `load_remote_token`: a named,
versioned registry with exactly one token reference per entry, HTTPS except
loopback, restricted token environment names, and mode-0600 token files.
Registry aliases are operator labels, not proven machine or repository identity.

| Option | Benefit | Cost / decision |
| --- | --- | --- |
| SD-207 one selected instance | Existing channel/projection ownership; bounded strip | Recommended for action and conversation |
| Aggregated agents from all instances | Browse a whole fleet without switching | Needs deduplication, mixed freshness and destination-qualified writes; defer to #6901 |
| Relay all fleet reads through one daemon | One client connection | New proxy/cache authority; local daemon failure hides healthy peers; unnecessary for SD-207 |

Dial 3 browses registry aliases without network calls; press commits the switch.
Show selected instance and repository continuously, and distinguish the browsing
candidate from the connected destination. A machine label is supplementary;
several repositories or instances may run on one machine. On connection, obtain
and verify stable instance/repository identity before enabling writes; do not
pretend an alias proves either. Keep unavailable registry entries visible.
Initially a repository change means selecting its instance. An aggregated
repository chooser can later use #6901's summary model, preserving the same
selected-instance action boundary. Pin or resolve a stable service endpoint;
the unified plan correctly identifies changing dashboard ports as a risk.

## 2. Selecting and naming the recipient

Evidence: `AiurWeb.StreamdeckChannel.handle_in/3` handles `focus`, `unfocus` and
`say` by ticket identifier; `packages/streamdeck/src/main.ts` refocuses the
remembered identifier after reconnect. That behavior is unsafe to copy across
instances with colliding ticket numbers. `Aiur.Conversation.Ref.worker/1` and
`canonical/1` include tracker/repository identity, while `Ref.executor/0` is a
local Executor subject. Neither alone is a fleet-wide routing address.
`AiurWeb.VoiceTargets.validate/2` checks surface and instance; its
`same_instance?` currently permits absent instance identity, so it is not a
strict cross-machine identity fence.

| Option | Benefit | Cost / decision |
| --- | --- | --- |
| Ticket number or implicit Executor | Fits today's small payload | Ambiguous across repositories; reject as a remote routing contract |
| Explicit destination envelope | Makes recipient inspectable and verifiable | Recommended; pair stable instance, repository, subject and live generation |
| Follow the ticket when ownership moves | Less reselection | Can change the recipient mid-utterance; require explicit reselection instead |

Proposed envelope: `{instance_id, repository_identity, conversation_ref,
agent_generation, connection_generation}`; Executor selection additionally binds
the managed Executor identity/session. Use the canonical conversation ref where
supported, with an adapter for current ticket payloads. The receiving daemon
must verify ownership and current generation at delivery, not just at focus.

Strip priority: selected alias / repository, target kind and ticket or Executor
name, then capture/draft/delivery state. Long labels must remain inspectable
before Send; do not truncate away the distinguishing part. During browsing,
label the candidate as a candidate and disable Talk/Send. Require a fresh focus
after switching; never reuse the same numeric ticket automatically. Echo the
resolved destination in acknowledgements and match it to the pinned envelope.

## 3. Remote control and Command answers

Evidence: `connectStreamDeckChannel` in `packages/streamdeck/src/channel.ts`
exchanges bearer or Basic credentials at the token route, then joins the deck
socket. `AiurWeb.StreamdeckSocket.connect/3` verifies the short-lived token.
`AiurWeb.StreamdeckChannel.handle_in/3` supports pause, resume and implement;
it explicitly excludes priority today. `CommandAnswers.record_command_answer/2`
uses `Aiur.Commands.Answering.answer/2`, preserving expected version,
idempotency and the operator actor from `StreamdeckCommands.actor/0`.
The CLI alternative exists through `ControlController.run/2`,
`Aiur.ControlCall.Allowlist.fetch/3` and `Audit.append/1`.

| Channel | Auth and audit | Latency / failure modes |
| --- | --- | --- |
| Direct sidecar to selected daemon | Per-instance bearer exchange; target owns controls and Command record | Recommended for controls; one network leg; destination failure visible directly |
| Local daemon relay | Needs local authorization plus a remote credential and origin attribution | Extra hop and local dependency; useful for Q4 voice but unnecessary for controls |
| Hosted relay | Needs relay identity, remote trust and correlated audit | Extra service, queue and outage boundary; no requirement justifies it |

Do not claim the deck socket automatically inherits HTTP control auditing or
per-client read/write scope. Its current token carries configuration generation
and expiry, not a client principal or a control-route audit record. A follow-up
must preserve authenticated client identity, enforce write capability, and record
remote control attempts/results without secrets. Keep Command answers on the
operator answer facade: routing them as Executor answers would lose the ability
to answer human-required Commands truthfully. The HTTP CLI path is not a
substitute for this operator attribution.

Priority needs an explicit server action that uses the owning control facade;
do not send a currently unsupported string or write labels from the sidecar.
Show accepted versus applied versus outcome-unknown. Retry a Command answer
only against its original instance/version with the same idempotency key.
Never replay a timed-out write into the newly selected instance.

## 4. Reading remote context

Evidence: `Aiur.Conversation.History` is a daemon-local read facade:
`transcript/2`, `bus_events/1`, `workspace_paged_tail/2`, `live_resolve/1` and
`live_subscribe/1` delegate to existing stores. It is not a network API.
`AiurWeb.StreamdeckLogs.load/1` currently projects a 50-entry transcript plus
bus events; `project/1` uses shared anchors. `main.ts` intentionally ignores the
message-only transcript feed and renders the combined logs feed.
`AiurWeb.Build.ConversationSource.Wave0b.tail/3`, `page/3` and `subscribe/2`
provide bounded reads; `read/4` uses a live projection for remote workers.
`AiurWeb.Build.Conversation.page/2` and `info/2` track paging, generation changes
and refresh. These are read-model precedents, not a ready deck network protocol.

| Option | Benefit | Cost / decision |
| --- | --- | --- |
| Read local workspace files for remote agents | No new API | Wrong authority and often no files; reject |
| Selected daemon projects shared history | Same context as its dashboard; bounded paging | Recommended; authenticated deck adapter over shared read seam |
| Copy all transcripts to the deck or broker | Offline scroll | Duplicated retention/privacy and stale context; unnecessary |

Keep turn/event IDs and cursors opaque and scoped to the destination,
conversation and generation. Reset them on switch/restart; reject foreign
cursors. Distinguish unavailable history, empty history, retained older history
and a bounded remote window. Render observed time/age for stale context; missing
context must never silently become an empty prompt. The local voice broker
fetches only a bounded authorized context window from the remote read service,
not remote filesystem paths, and does not become the conversation store writer.
Only confirmed text/delivery enters the target's ordinary conversation history.

## 5. Audio, speech calls and credentials (Q4)

Evidence: `StreamdeckChannel.Voice.open_voice_session/0` calls
`Aiur.Voice.start_transcription/1`; audio travels from local capture to the
connected daemon. `Aiur.Voice.provider/0`, `availability/0`, `push/2` and
`start_speech/3` already separate provider work from delivery; `Voice.Provider`
names transcriber and synthesizer modules and never returns the credential.
The deck socket routes only `streamdeck:fleet` today. There is no
`VoiceConverseChannel` or device voice socket in this inspected checkout;
#4142, #4145 and #5729 describe proposed APIs. A legacy topic called
`voice:conversation` on `VoiceSocket` is not the proposed `voice:converse`.

Newer reuse target: `packages/elixir/voice_converse/lib/voice_converse.ex`
already exposes `start_session/3`, `push_audio/3`, `confirm_draft/4` and
`end_session/3`. Its `Ports.BriefingSource` (`brief/1`, `alive?/1`) and
`Ports.AgentChannel` (`instruct/4`, `ask/4`) are natural remote host adapters;
`Ports.Credentials.fetch/2` keeps secrets at the broker. Its standalone
`Transport.WebSock` and `Wire.decode/1` use a versioned protocol, not the old
Phoenix topic contract. `Providers.ElevenLabsAgents` delegates to a concrete
provider, while registry entries alone do not prove an OpenAI implementation.
No host wiring referencing `VoiceConverse` was found in `src/lib` or
`src/config`. Reuse this core after checking its host ports; absence of the
planned Phoenix channel does not mean conversation primitives are missing.

| Placement | Credential and context boundary | Assessment |
| --- | --- | --- |
| Local sidecar calls provider | Key or ephemeral provider authorization on client; client becomes orchestrator | Avoid; bypasses daemon voice ownership and duplicates policy |
| Selected remote daemon calls provider | Key per remote daemon; context and delivery stay local there | Simplest transport; alternative if Kevin accepts distributed credentials |
| Local daemon brokers voice to remote target | Key only on broker; bounded remote context and remote delivery authorization required | Recommend unified-plan Q4 default; additional broker contract needed |
| Hosted voice relay | Another credential and conversation processor | Defer; no need for an additional hosted service |

Recommended flow: local mic → local daemon voice session → speech provider;
remote context → local voice session; reviewed draft → remote authorized Send;
remote reply text → local speech synthesis → local speaker. Audio never needs
to enter the remote daemon. The sidecar keeps one selected fleet channel plus
a separate local voice channel; revise SD-207's “one channel” invariant to
“one selected fleet destination,” not a ban on the future broker connection.
The broker must pin the destination and acquire its context before capture.
Failure of either broker or destination stops the turn. No local daemon is
needed for non-voice remote control; the voice key's absence disables voice only.

Provider comparison, checked against official documentation on the research date:
[ElevenLabs realtime STT](https://elevenlabs.io/docs/api-reference/speech-to-text/v-1-speech-to-text-realtime)
returns transcripts and accepts server keys or single-use client tokens.
[OpenAI Realtime WebSockets](https://developers.openai.com/api/docs/guides/voice-websockets)
support server connections and audio conversation events. Both permit server
ownership; client-token availability does not require moving the provider leg
to the deck. ElevenLabs STT still needs an assistant/context and reply-synthesis
path. An OpenAI speech-to-speech choice could put response/turn management in
the provider session, requiring an adapter that preserves draft confirmation,
interruption and the canonical target history. This is a design implication,
not proof of deck integration. Negotiate format
and sample rate; `audio/node-playback.ts` currently defaults to 44.1 kHz.
No latency saving or comparative benchmark is claimed.

## 6. Failures and switching during a turn

Evidence: `main.ts`'s `closed` callback calls `voiceLink.drop`, disposes capture
and schedules reconnect. `Voice.stop_voice_session/1` synchronously stops its
child and drains old transcript messages. `StreamdeckAuth.verify_token/1`
checks expiry and configuration generation; the channel schedules auth expiry.
`channel.ts` currently reduces every unsuccessful token response to a generic
unauthorized error, so detailed connection states need work. `VoiceTargets`
refuses missing/stale targets but does not by itself fence delayed Send.

| Policy | Benefit | Risk / recommendation |
| --- | --- | --- |
| Auto-fallback to another instance or Executor | Appears available | Wrong recipient; forbid |
| Wait to switch until current turn ends | Fewer cancellations | Can trap navigation behind an unreachable target; avoid |
| Explicit switch cancels and fences old work | Predictable destination | Recommended; incomplete draft remains unsent or is discarded with clear notice |

Required transitions:

- Unreachable: stop capture/playback, disable writes, show destination plus last observation age; reconnect only that destination with backoff.
- Auth failure: distinguish authentication refusal from read-only scope, transient transport failure and incompatible protocol. Do not retry credentials endlessly or fall back to Basic on a remote bind.
- Stale instance: retain its identity and mark stale; require fresh target validation before recording or sending. Heartbeat presence alone is not conversation freshness.
- Switch: stop/flush audio, cancel provider turn, invalidate connection generation, clear focus/cursors/pending writes and drafts before opening the next destination. Late callbacks cannot repaint or deliver to the new target.
- Agent ends or is replaced: stop Talk; retained context may remain readable with its ended state. Reject Send to the old generation. Do not follow a replacement or Executor silently.
- Ambiguous write timeout: show outcome unknown; reconcile with the same destination and request ID before another submission. Switching never replays it elsewhere.

## 7. Executor as a target: resolve the conflicting contracts

The historical “Executor must never be a target” rule is reported by #6903
against MP-R6/#3462. The current #3462 body lists projection/anchor acceptance
and does not contain that sentence; the MP-R6 pack is absent from this checkout.
Do not present the quotation as current-code behavior or invent a source line.
Current, reproducible evidence is `VoiceTargets.check/1`: Executor returns
`unsupported_target`. Conversely, `Conversation.Ref.executor/0` exists, and
MP-E5-C5-T02 plus MP-E6-C4-T06 explicitly plan Executor voice support.
SD-407 currently promises Executor conversation and an implicit Executor fallback.
These contracts need a recorded product decision; code alone cannot settle it.

| Policy for Kevin | Consequence | Recommendation |
| --- | --- | --- |
| Keep Executor forbidden everywhere | Agent-only deck; remove SD-407 Executor scope | Conflicts with item 7's stated intent |
| Allow explicit managed Executor target | Agent and Executor choices, separately validated; amend historical rule | Recommended resolution |
| Default to Executor outside a ticket page | Convenient global talk | Hidden target changes; reject implicit fallback |

**Question for Kevin:** may an operator explicitly select a managed Executor
conversation, superseding the MP-R6 restriction for that explicit choice?
Recommend yes, while retaining the prohibition on implicit Executor targeting.
An absent, unmanaged or ambiguous Executor stays unavailable; roster presence
alone does not prove a writable chat endpoint. Selecting an Executor never
grants it the operator's authority to answer human-required Commands. Pending
Kevin's answer, ship non-voice navigation and agent selection; keep Executor
voice disabled, and do not claim this report grants the product exception.

## Amendments and follow-up contracts

These are proposed amendments, not newly filed duplicate SD tickets. No ticket
or dependency was mutated by this research.

| Owner | Amendment | Can proceed now? |
| --- | --- | --- |
| SD-207 #6036 | Registry-only switch; destination identity and generation fence; cancel old state; explicit status; no same-number refocus | Yes; no provider/design/mobile dependency |
| SD-406 #6046 | Sidecar owns mic/speaker IDs, brightness and last instance per physical deck; remote daemon owns view/sort/alert preferences per instance | Yes; reuse SD-207 selection model |
| SD-407 #6047 | Explicit target; Q4 broker adapter; provider-neutral availability; sample-rate negotiation; no Executor fallback | Contract work now; final voice waits for provider and target policy |
| #6901 / PR #6902 | Link this research; separate registry-only phase 4 from aggregated dashboard data; record Q4 and Executor decisions | Planning amendment now |

SD-406 currently stores all settings on the selected daemon. That makes a
switch change hardware configuration and lets a remote machine persist device
IDs it cannot resolve. Amend it so a selected remote daemon renders reported
local devices and requests changes through the sidecar's settings port; the
sidecar validates and persists them. Do not send token references or secrets as
ordinary settings. Migrate existing `audio/preferences.ts` selection once.

Worker-ready slices for the existing owners:

1. **SD-207: destination-safe connection switch.** Inputs: registry rules in
   `remote.sh`, current `connectStreamDeckChannel`, stable daemon identity.
   Files: new instance registry adapter and focused tests, `main.ts`, channel
   types and connection-status projection. Acceptance: two destinations with
   equal ticket numbers never share focus or queued writes; delayed connect
   callbacks cannot resurrect the old destination; malformed registry keeps
   current selection; auth failure never falls back. Verify fake channel order,
   failed switch and restart persistence. Manual: switch on a physical deck
   between two instances and inspect destination and ticket list. Docs: existing
   Stream Deck guide and channel contract. No voice-provider prerequisite.
2. **SD-406: device-local settings boundary.** Inputs: sidecar device discovery
   and SD-207 selection. Files: settings ports, local preferences, daemon
   settings projection and their tests. Acceptance: choosing a mic or speaker
   survives instance switching and sidecar restart; remote preferences cannot
   apply an unknown device without a visible missing state; failed persistence
   retains prior settings. Fake devices/storage/clock tests cover these cases;
   physical-deck check confirms the selected local speaker. Docs: same guide.
3. **Shared read/control adapter, coordinate under #6901.** Inputs: destination
   envelope, `History`/Build conversation seam and Command answer facade.
   Acceptance: remote turns and event keys share anchors; foreign cursor and
   wrong instance/generation are refused; unavailable context stays unavailable;
   control records retain client/operator attribution and version/idempotency.
   Add only missing adapter/audit work after checking SD-201/SD-301 ownership;
   do not rebuild the redesigned renderer. Test colliding IDs and delayed
   answers. Non-voice read/control work starts now; priority is additive only
   when an explicit server action exists. Docs: channel contract and guide.
4. **SD-407: brokered voice integration.** Reuse `VoiceConverse` and add remote
   host ports instead of another session core; choose its versioned transport
   or the planned Phoenix adapter explicitly. Inputs: Kevin's provider/Q4 answer,
   #4142/#4145 conversation/interruption contract and a device-authority path
   equivalent to #5729, plus slices 1–3. Mobile pairing is not required merely
   to authenticate a deck; adapt bearer-derived deck authority rather than
   adding browser cookies. Acceptance: hold captures locally, remote context
   is used, Send reaches only pinned target, barge-in flushes playback, and
   switch/disconnect/agent end cancels both broker and destination work. Tests
   use fake provider, two daemons and playback ports; missing provider opens no
   capture and exposes a neutral reason. Mutation checks remove the generation
   fence and playback flush separately and must fail. Physical-deck acceptance:
   talk to the remote agent, hear its reply locally, interrupt it, then switch
   while holding Talk and prove neither destination receives the canceled turn.
   Docs: existing voice/Stream Deck guide and channel contract in that PR.

## Remaining questions and validation limits

Kevin's outstanding choices are Q4 (local voice broker versus direct remote
voice), explicit Executor permission (question 7), and the provider. The first
two have recommendations above; none blocks this research or non-voice work.
The broader #6901 hosting questions remain owned there.

This report is source analysis, not a live deployment or hardware proof. The
versioned packs were read from their PR heads because they are absent from the
base checkout. No CLI/TUI smoke, physical dictation, latency measurement or
cross-machine delivery was run. Follow-up owners must collect those results;
this document neither selects a provider nor declares the proposed APIs ready.
