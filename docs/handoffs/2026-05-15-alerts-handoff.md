# Alerts Handoff

Created: 2026-05-15
Current branch: `symphony/sounds`

## Why This Handoff Exists

The alert feature is now partially implemented in `symphony-sounds`, but there
is still active follow-up work and some runtime behavior to validate. This
handoff is for another agent to continue in parallel without re-discovering the
current design, touched files, and known gaps.

## Product Shape Landed So Far

Alerts are now treated as first-class lifecycle events.

Current model:

- checked-in `alerts.yaml`
- alert name is the YAML key
- entry body defines:
  - `message`
  - optional `sound`
- logs are authoritative
- audio is optional
- multiple sounds per alert choose randomly
- dedicated `[alert]` label in CLI log rendering
- custom agent alerts are emitted through Codex dynamic tool `emit_alert`
- system-owned scopes remain:
  - `task.*`
  - `agent.*`
  - `chat.*`
- custom workflow scope remains:
  - `phase.*`

## Important Current Config

Current alert catalog lives in:

- `alerts.yaml`

Important recent user-driven changes:

- removed redundant `name:` requirement from the YAML shape
- preserved and supported:
  - `agent.paused`
  - `agent.unpaused`
- startup dispatch should emit `task.todo` once per initially claimed todo
  ticket, staggered by `1s`
- user wants some alerts silent by design; do not assume every alert should
  have audio

## Audio Sourcing And Clipping Context

This branch also contains the temporary audio bootstrap assets for the alert
system.

What has already happened:

- quote-reel videos were downloaded from YouTube with `yt-dlp`
- source audio was extracted as `.wav`
- individual quotes were clipped from those source files with timestamp-guided
  `ffmpeg` cuts
- the clips were tightened against actual silence/low-energy boundaries, not
  just the rough user-supplied timestamps
- current clip files were copied to:
  - `~/alerts`
- `alerts.yaml` points at those files with paths like:
  - `"~/alerts/upgrade-complete.wav"`

Current operational assumptions:

- the user may continue providing new YouTube quote compilations to mine for
  additional alert sounds
- clipping is an iterative workflow:
  - download video audio
  - inspect rough timestamps from the user
  - trim start/end to avoid bleed between adjacent quotes
  - export clean `.wav` snippets with intentional filenames
- the user explicitly wants to preserve context about this workflow because
  future agents may need to add or replace alert sounds the same way

Important clipping guidance from the user:

- the timestamps the user provides are rough anchors, not exact cut points
- these quote reels usually contain short silence buffers between spoken lines
- future clipping work should review the actual waveform or audio energy around
  the requested range before exporting
- do not assume a clip starts or ends exactly on the supplied timestamp
- the goal is to avoid bleeding into neighboring quotes while also avoiding
  cutting off the first or last phoneme of the intended line
- if a quote sounds clipped, bias slightly earlier/later into surrounding
  silence rather than trimming aggressively to the nominal timestamp

Important current status:

- `public/` currently exists in this repo as a temporary staging area for audio
  files so the user can fetch them on another machine
- long term, the user expects these assets to move out of the repo and live at
  stable local or hosted paths
- do not assume the current clip set is final; more source videos and clips are
  expected

## Runtime Code Added / Changed

New modules:

- `elixir/lib/symphony_elixir/alerts.ex`
  - loads `alerts.yaml`
  - resolves `~/alerts/...`
  - emits structured alert log entries
  - optionally plays sound with `afplay`
- `elixir/lib/symphony_elixir/agent_event_log.ex`
  - shared writer for `logs/agent.ndjson` and `logs/agent.md`

Main integrations:

- `elixir/lib/symphony_elixir/orchestrator.ex`
  - emits `task.<state>` on tracker state transitions
  - emits `task.todo.more_agents`
  - emits `chat.send`
  - emits `agent.paused` / `agent.unpaused` from worker control-state changes
  - schedules initial `task.todo` alerts during startup dispatch with `1s`
    spacing
- `elixir/lib/symphony_elixir/agent_runner.ex`
  - uses shared log writer
  - injects dynamic tool executor with alert emitter
  - emits `agent.more_tokens` on token/rate-limit style terminal errors
- `elixir/lib/symphony_elixir/codex/dynamic_tool.ex`
  - adds `emit_alert`
  - custom alerts now take:
    - `name`
    - `message`
  - rejects reserved system scopes
- `elixir/lib/symphony_elixir/agent_log.ex`
  - parses alert events into dedicated `alert` role
  - title shown in the log is now derived from alert `name`
- `elixir/lib/symphony_elixir/status_dashboard.ex`
  - `[alert]` style in CLI log pane
  - removed transient `sent; waiting for agent turn`
  - typing mode always keeps helper key text
- `elixir/lib/symphony_elixir_web/live/dashboard_live.ex`
  - web-side `chat.open` / `chat.close` alert emission

Prompt/workflow/doc scaffolding already updated earlier:

- `elixir/prompts/shared-agent-instructions.md`
- `elixir/local-workflows/WORKFLOW.symphony.local.md`
- `docs/brainstorms/2026-05-15-alert-lifecycle-requirements.md`
- `README.md`

## Tests Added / Updated

Relevant tests:

- `elixir/test/symphony_elixir/alerts_test.exs`
- `elixir/test/symphony_elixir/dynamic_tool_test.exs`
- `elixir/test/symphony_elixir/agent_log_test.exs`
- `elixir/test/symphony_elixir/app_server_test.exs`
- `elixir/test/symphony_elixir/status_dashboard_view_test.exs`

Recently verified:

```text
mise exec -- mix test test/symphony_elixir/alerts_test.exs test/symphony_elixir/agent_log_test.exs
mise exec -- mix test test/symphony_elixir/status_dashboard_view_test.exs
mise exec -- mix test test/symphony_elixir/alerts_test.exs test/symphony_elixir/dynamic_tool_test.exs test/symphony_elixir/agent_log_test.exs test/symphony_elixir/app_server_test.exs
./scripts/agents build
```

At the time of handoff, focused test sets were green.

## Manual Verification Already Done

Manual runtime simulation was run through `mix run -e` against the compiled app
using memory tracker state.

Confirmed:

- `task.in-progress` logged
- `chat.send` logged
- `task.done` logged
- sound path selected correctly for sound-bearing events
- `afplay` exists on this machine
- `/Users/kevin/alerts` exists and contains expected files
- `agent.ndjson` now serializes `null` instead of `"nil"` for absent sound

`./scripts/agents symphony` was also launched successfully, but that live
profile had `0` active agents at the time, so it did not naturally exercise the
alert paths.

## Important Open Issue

The user reports:

- they hear sounds when I run direct test/manual scripts
- they still do not hear sounds from normal `agents` usage

This is the highest-signal unresolved behavior.

Current likely explanations:

- the live `agents` session may not have hit sound-bearing alerts
- the session may have only triggered silent alerts such as:
  - `task.in-progress`
  - `chat.send`
  - `phase.*.start`
  - `phase.work.end`
- startup `task.todo` stagger path needs real tracker-backed confirmation in
  the `agents` wrapper flow
- web and CLI may both emit `chat.open` / `chat.close`, so runtime behavior
  should be checked for duplicates once there is real activity

## Recommended Next Work

1. Verify sound behavior in a real `agents` session with actual runnable todo
   tickets.
   - easiest target is startup `task.todo`
   - ensure multiple initial tickets produce staggered audio at `0s`, `1s`,
     `2s`, etc.

2. Confirm `agent.paused` and `agent.unpaused` with an actual pause/resume flow
   through the CLI, not just orchestrator-level tests.

3. Check for duplicate `chat.open` / `chat.close` emissions.
   - currently emitted in both:
     - `StatusDashboard`
     - `DashboardLive`
   - if both surfaces are used for the same session, duplicate audio/logs may
     occur

4. Decide whether log display title for alerts should remain the raw name
   (`task.todo`) or be humanized for presentation only.
   - user explicitly removed `title` from config
   - current renderer uses `name` as the visible title

5. Consider whether `task.in-progress` should have a sound.
   - right now it is intentionally silent
   - that may contribute to user confusion when tickets are picked up outside
     startup

## Suggested Files To Inspect First

- `alerts.yaml`
- `elixir/lib/symphony_elixir/alerts.ex`
- `elixir/lib/symphony_elixir/orchestrator.ex`
- `elixir/lib/symphony_elixir/status_dashboard.ex`
- `elixir/lib/symphony_elixir_web/live/dashboard_live.ex`
- `elixir/test/symphony_elixir/alerts_test.exs`

## Boundaries

In scope next:

- finish runtime validation for real `agents` usage
- resolve missing audible behavior in normal interactive runs
- tighten alert emission ownership and duplication if needed

Out of scope unless redirected:

- redesigning the entire lifecycle model again
- remote asset hosting work
- removing temporary in-repo audio bootstrap files
