# Group D findings — strip counts, meters, settings, voice

Researched at `6a7d6b445`. Paths are relative to the repo root.

## 1. Why the strip shows "543 agents"

- The TS strip prints `pagerLabel: \`${grid.total} Agents\`` and builds the summary from
  `grid.agents.filter(bucket === "running").length` and `grid.total - running`
  (`packages/streamdeck/src/surface.ts:447-468`).
- `grid.total` is `length(agents)` in `AiurWeb.StreamDeckGrid.project/2`
  (`src/lib/aiur_web/stream_deck_grid.ex:47-54`). `agents` comes from `snapshot_agents/1`
  (`:67-72`): every `running`, every `retrying`, and every `idle` entry without a
  `dispatch_decline_reason` (`:77`).
- `idle` is `idle_snapshot/3` in `src/lib/aiur/orchestrator/status_report/snapshot_payload.ex:39,58`.
  It is every active-state candidate ticket that has no agent. That is the queued backlog.
  So "543 agents" is about 10 to 16 live agents plus about 530 queued tickets with no agent.
- Each entry is bucketed by the deck-only `Aiur.AgentEvents.streamdeck_bucket/1`
  (`src/lib/aiur/agent_events.ex:298-312`). It has 5 buckets (alert, stuck, running, paused,
  queued). It does not use the Build page taxonomy.
- The emulator uses the same count: `live_count/1` and `remaining: grid.total - live`
  (`src/lib/aiur_web/live/streamdeck_live/surface.ex:72-77,132`).
- The grid also feeds paging (`windows`, `max_column_offset`, `stream_deck_grid.ex:56-64`;
  `pagerModel(grid.total, ...)`, `surface.ts:466`). A phase-1 fix must not change
  `grid.total`. It must add a separate counts block.

## 2. What Build.NowRows offers for counts

- `AiurWeb.Build.NowRows.build/2` (`src/lib/aiur_web/build/now_rows.ex:44-65`) projects the
  Units catalog into one row per live or retrying ticket in this repo. Finished, replacement,
  lifetime-latched and other-repo rows are excluded (`:79-84`).
- The `agent.state` precedence (`now_rows.ex:8-20`, `:115-157`) gives 9 states:
  `error`, `retrying`, `command`, `usage_limited`, `ci_wait`, `parked`, `paused`, `active`,
  and `nil` (unknown). A reason label suffix wins over all of them (`runtime_reason_state/1`,
  `:168-175`). That adds the pass-through states `merge-queued`, `ci-red`, `body-fix`,
  `paused-usage-limit`, `paused-decision`, `paused-agent`, `blocked`, `handed-off`, `retries`.
  The wire enum is `AiurWeb.Build.PayloadSchema` line 33.
- The page reads it through `AiurWeb.Build.IndexReader.read_now/2`
  (`build/index_reader.ex:38-62`, with a fallback to the running snapshot). The shared index is
  `AiurWeb.Build.Index.window/3` (`build/index.ex:27-35`), and `IndexSource.snapshot/1`
  (`build/index_source.ex:17-31`) adds usage. Sections are `now`, `plan` (queued backlog,
  `PlannedRows`, with `qpos`), `nq` (not queued) and `hist`.
- The Build page counts are computed in the browser, not on the server:
  `src/priv/static/build-home/list.js:86-96` folds `now` rows into
  `running | retrying | stuck | paused | unknown`. `plan` shows "N in build-queue order" and
  `nq` shows "N open". Labels come from `src/priv/static/build-home/now-state.js:2-12`.
  `AiurWeb.Build.NavCount` (`build/nav_count.ex:49`) counts only `active` rows for the nav badge.
- So there is no server-side count function to reuse. The deck section must count
  `sections.now` by `agent.state`, plus `length(plan)` and `length(nq)`. Unknown sources
  must give `nil`, never `0`.

## 3. Why Claude meters show "Awaiting data"

Root cause (high confidence): the daemon and the sidecar classify windows twice, and the
second step cannot work on the first step's output.

1. The daemon re-keys windows to the semantic slots `"session"` and `"weekly"`
   (`AiurWeb.ProviderMeterWindows.semantic/2`, `src/lib/aiur_web/provider_meter_windows.ex:30-42`,
   called from `StreamdeckProjection.Meters.normalized_windows/5`, `streamdeck_projection/meters.ex:134-141`).
   `normalize_window/4` (`:143-156`) keeps only `used_percent`, `remaining`, `resets_at`,
   `observed_at`, `age_seconds`, `freshness`. It drops `duration_minutes`.
2. The sidecar classifies again by `duration_minutes` only
   (`packages/streamdeck/src/touchStrip/providerSegment.ts:110-159`). A window with no duration is
   skipped. The fallback accepts only a single window (`:144`).
3. Claude's usage API windows (`five_hour`, `seven_day`, and so on) never carry
   `duration_minutes` (`src/lib/aiur/provider_meter_probe.ex:358-372`). The daemon sends both a
   `session` and a `weekly` window, so the sidecar finds 0 classifiable windows, the fallback does not apply,
   `hasData` is false, and `art/segments.ts:99-100` prints "Awaiting data".
   Any provider with two windows has the same problem, because the duration is always dropped.
4. The TS test fixtures carry `duration_minutes`
   (`packages/streamdeck/test/touchStrip/providerSegment.test.ts:9-17`). This shape never
   reaches the device, so the test cannot see the bug.
5. The browser emulator reads `windows.session` and `windows.weekly` by key
   (`live/streamdeck_live/surface.ex:134-163`), so it shows data while the physical deck does not.
   This is the parity divergence that the redesign removes.

Second factor: `AiurWeb.StreamdeckMeterRetention.newer?/2` (`streamdeck_meter_retention.ex:7-14`)
rejects every Claude snapshot without a `summary_label` once a labelled one has been stored. The
app-server rate-limit adapter snapshots are therefore ignored after the first usage-API poll. With a
whole-map read from `Build.Usage`, this per-snapshot merge (and the module) is not needed.

## 4. Multi-login accounts

- Configured names: `Aiur.Accounts.configured_names/1` (`src/lib/aiur/accounts.ex:81`).
- Per-account readings: `Aiur.Accounts.UsageReadings.record/5` and `snapshot/2`
  (`src/lib/aiur/accounts/usage_readings.ex`). Each entry has a `reading` with
  `windows: [%{window: "five_hour" | "seven_day" | ..., used_percent, resets_at}]`, plus
  `observed_at` and a freshness value.
- `ProviderMeterProbe.probe_claude_accounts/2` (`provider_meter_probe.ex:220-252`) polls every
  account and records each one. It then publishes **one** `ProviderMeterSnapshot` for the account with the highest
  `account_used_percent`, with `summary_label` "worst of N accounts · name" or
  "name · k/N accounts observed".
- `AiurWeb.Build.Usage` (`build/usage.ex:162-175`) has the full multi-account model. When there are 2 or more
  accounts, the Claude row gets `accounts: names` and `session.acc` / `weekly.acc` lists with one
  value per account. `reset_at` is the earliest reset across accounts. A per-account
  reset is not kept.
- Only Claude is multi-account today. Other providers have one account.

## 5. #5589 and its open PR #5618

- #5589 (open, `agent:rework`): every API and model bar shows **remaining**. The bar is full at 100% left,
  and the label reads "N% left". Colour follows remaining. It names the Stream Deck screens.
- PR #5618 (open, branch `aiur/5589-make-every-api-and`) edits these files:
  `build/usage.ex`, `build/usage_apis.ex`, `build/payload.ex` (`acc` now means remaining),
  `streamdeck_projection/meters.ex` (adds `remaining_percent`), `packages/streamdeck/src/art/segments.ts`
  (the label becomes "Session N% left"), `live/streamdeck_live/screen_components.ex` and `surface.ex`, and the new
  `src/lib/aiur_web/remaining_meter.ex` (`AiurWeb.RemainingMeter.percent/1`).
- These are the files SD-403 edits, and the PR changes the meaning of `acc`. SD-403 must be natively
  `blocked_by` #5589. Otherwise either SD-403 builds on used-semantics and #5589 inverts it,
  or the two PRs conflict in four files.

## 6. API budgets for the dashboard

- GitHub core and GraphQL: `Aiur.GitHub.Quota.cached_snapshot_at/3` and `snapshot!/2`
  (`src/lib/aiur/github/quota.ex:83-111`). These are read by `Build.Usage.github_snapshot/1` (`usage.ex:44-56`,
  a 60 s cache and then a 1 s call) and shaped by `AiurWeb.Build.UsageAPIs.github_row/3`
  (`build/usage_apis.ex:11-45`): lines `core` and `gql`, a 1h window, `hold_until`.
- ElevenLabs: `Aiur.ElevenLabs.Quota.snapshot/1` (`src/lib/aiur/eleven_labs/quota.ex:81`), shaped by
  `UsageAPIs.elevenlabs_rows/2` (`:54-66`). The row is left out when the state is `:unconfigured`.
- The deck has no API bars today: `StreamdeckProjection.provider_meters/2`
  (`streamdeck_projection.ex:88-96`) maps `CodingAgent.provider_families()` only.
- Auth: `Build.Usage.read/2` needs `{:ok, context}`. Its default `ProviderMeterSource`
  (`operator_control_center/provider_meter_source.ex:35-42`) re-checks a `FinancialDataAccess`
  context, and the deck socket has none (`streamdeck_socket.ex:11`, token auth only). However,
  `Build.Usage.load/2` takes `meter_source:` as an option (`usage.ex:34`), and the real read is just
  `ProviderMeterProjection.redacted_snapshot/1` (`provider_meter_source.ex:100`). The deck can pass
  a small meter source that is behind its own token auth, and then call `Usage.block({:ok, :streamdeck}, inputs, now)`.

## 7. Settings page and the test-mic key

- Settings mode is entered from Command (`packages/streamdeck/src/mode.ts:157-158`). The keys are
  `MIC_KEY_INDICES` [0,1,3,4,5,6], `SETTINGS_TEST_MIC_KEY = 2`, and `SETTINGS_NEXT_PAGE_KEY = 7`
  (`settings.ts:27-44`). They are painted by `descriptorSettings` (`surface.ts:302-332`, TestMic at `:323`). Release is handled at
  `controller.ts:277`, and the voice panel at `touchStrip/stripLayout.ts:76,234`. The emulator mirror is
  `live/streamdeck_live/modes.ex:54-58`.
- The mic choice is stored in a sidecar-local file (`audio/node-preferences.ts`, `audio/preferences.ts`). The device
  list comes from `pactl`/`pw-dump` on the PC (`audio/devices.ts`). The daemon cannot list devices itself.
- Brightness is the env `STREAMDECK_BRIGHTNESS` (`main.ts:65`, `device-path.ts:47`). It is applied on
  open and resume (`runtime.ts:57,205`). There is no dim-when-idle, no speaker choice, no default view, and no
  alert chime setting.

## 8. Deck voice events and TTS code

- Channel in: `voice_start`, `voice_audio`, `voice_stop` (`src/lib/aiur_web/streamdeck_channel.ex:199-236`).
  Channel out: `voice`, `voice_error`, `voice_closed` (`:310-330`). Helpers:
  `AiurWeb.StreamdeckChannel.Voice` (`streamdeck_channel/voice.ex:23-60`, `Aiur.Voice.start_transcription/1`).
  The join snapshot carries a `voice` entry (`streamdeck_projection.ex:21,35-41`).
- Sidecar: `channel.ts:114-132,230-251,271-274`, `voiceHost.ts`, `voicePanel.ts`, and
  `audio/relay.ts` (relay transcriber over the channel), all exported from `audio/index.ts`.
- Unused TTS: `audio/tts.ts` has no importer in `src/` (only `test/audio/tts.test.ts`).
  `audio/playback.ts` and `audio/node-playback.ts` (pacat, 44.1 kHz) are also unused in `src/`.
  They are the PC-speaker sink that SD-407 needs, so SD-408 keeps them.
- `voice:converse` does not exist at this commit. `AiurWeb.VoiceChannel` and `VoiceSocket` serve
  the browser dictation topic only.
- #4142 (parked) adds `AiurWeb.VoiceConverseChannel`: join, `audio`, `end`, `confirm_draft`,
  `client_text`, `playback_state` in, and `state`, `transcript`, `assistant_text`, `audio`,
  `audio_done`, `interrupted`, `draft`, `delivery`, `error` out. It needs MP-E6-C4-T01 (the session),
  MP-E5-C2-T01 (`VoiceTargets`) and DESIGN-E6.
- #4145 (parked) defines the barge-in client contract: stop and flush on `interrupted`, send
  `playback_state`, use echo-cancelled capture or the half-duplex fallback. The browser file is not the deck's,
  but the deck must follow the same contract.
- #5729 (parked) adds the non-browser authority pattern: `voice_authority %{kind: :device}` and
  `/voice/device`, for paired phones. The deck needs the same kind of authority for its own socket.
