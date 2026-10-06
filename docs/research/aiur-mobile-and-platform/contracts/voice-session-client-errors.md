---
contract: voice-session (sibling)
parent: voice-session.md §8.1
version: draft-3
base_main_sha: 45a290e3
date: 2026-10-06
status: Phase D fix pass (review-feasibility-failures.md M7)
---

# Voice session: client error and end-reason table

This file is §8.1 of [voice-session.md](voice-session.md), split out to keep the contract under
500 lines. It is normative for every client.

Every client (dashboard, phone, watch, Stream Deck) renders voice failures from this table, so
cost cap, quota, provider outage and daemon restart are never collapsed into one "error". The
table is projected verbatim into the shared fixture
`packages/aiur-mobile/fixtures/contract/voice/end-reasons.json`
(`[{code, kinds, retry, copy_key}]`). The first of MP-N6-C4-T03 and MP-N7-C4-T05 to merge
creates the fixture; both decode it and assert that every code below is present. The dashboard
(MP-E6-C7-T02) reads the same rows from the Elixir module that emits them
(`Aiur.VoiceConversation.ClientErrors.table/0`, MP-E6-C4-T01), and a test asserts that module
equals the fixture.

`retry`: `none` = no retry button (the same action fails again); `now` = Retry offered at once;
`later` = Retry offered with "try again in a minute". Copy is DESIGN-E5/E6/N6/N7; the copy key
is fixed here.

| Code | End reason | Error code | Retry | Copy key | Meaning |
| --- | --- | --- | --- | --- | --- |
| `user_end` | yes | — | n/a | `voice.ended.user` | the human ended it |
| `idle_timeout` | yes | — | `now` | `voice.ended.idle` | no speech for `idle_timeout_seconds` |
| `max_duration` | yes | — | `now` | `voice.ended.max_duration` | session hit `max_session_seconds` |
| `target_gone` | yes | — | `none` | `voice.ended.target_gone` | the agent or Command is gone |
| `capability_lost` | yes | — | `none` | `voice.ended.capability_lost` | voice turned off mid-session |
| `auth_changed` | yes | yes | `none` | `voice.ended.auth_changed` | dashboard auth changed or the device was revoked; re-pair or sign in |
| `cost_cap` | yes | yes | `none` | `voice.ended.cost_cap` | the daily minute cap is used up; typing still works; resets at local midnight |
| `provider_quota` | yes | yes | `none` | `voice.error.provider_quota` | the provider account is out of quota |
| `provider_auth` | — | yes | `none` | `voice.error.provider_auth` | the provider rejected the key; fix on the machine |
| `provider_unavailable` | — | yes | `later` | `voice.error.provider_unavailable` | the provider is down or unreachable |
| `provider_error` | yes | yes | `now` (once) | `voice.error.provider_error` | provider failure of no known class (cause-neutral) |
| `transport_lost` | yes | yes | `now` | `voice.error.transport_lost` | the client socket dropped (includes a daemon restart seen from the client) |
| `daemon_restart` | yes (history only) | — | n/a | `voice.ended.daemon_restart` | recorded at boot for a session the daemon lost |
| `privacy_preflight_failed` | — | yes | `none` | `voice.error.privacy_preflight` | provider privacy settings are wrong; fix on the machine |
| `capacity` / `session_limit` | — | yes | `later` | `voice.error.capacity` | too many voice sessions |
| `ticket_used` | — | yes | `now` (new ticket) | `voice.error.transport_lost` | device ticket reused; the client fetches a new one silently |
| `unconfigured` / `not_installed` / `read_only` | — | yes | `none` | `voice.unavailable.<code>` | the mode button should not have been shown (§7) |
| `target_not_found` / `target_not_writable` / `target_stale` / `unsupported_target` | — | yes | `none` | `voice.error.target` | the target is not valid for voice |
| `chunk_too_large` / `invalid_payload` | — | yes | `now` | `voice.error.client` | client bug; Retry starts a clean session |
| `permission_denied` / `no_device` | — | client-side | `none` | `voice.error.<code>` | microphone permission or device missing |
| `unknown` | yes | yes | `now` | `voice.error.unknown` | unclassified; never relabelled as a specific cause |

A client test per row asserts the rendered copy key and the Retry affordance, and fails when
that row's branch is replaced by a generic "error" (AGENTS.md "a collapsed cause names the
collapse at the source").

