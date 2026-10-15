# Configuration notes

- Path values support `~` for the home directory and `$VAR` for environment substitution.
- Run credentials resolve in this order: exported environment, repository-local
  `./.env`, then `~/.aiur/.env`; GitHub credentials resolve as one group from
  the first file that sets any of them. The native provider variables are
  `MOONSHOT_API_KEY`, `DEEPSEEK_API_KEY`, and `OPENROUTER_API_KEY`;
  OpenRouter credit polling additionally uses `OPENROUTER_MANAGEMENT_KEY`.
  Keep values out of workflow YAML and Git.
- `agent.kind` may name any registered backend, including `kimi`, `deepseek`,
  and `openrouter`. Per-instance overrides live under
  `agent.backend_configs.<name>`. DeepSeek is disabled for dispatch until its
  entry sets `enabled: true`. OpenRouter requires an explicit underlying model
  through a model label/routing rule or `backend_configs.openrouter.model`.
  Kimi and DeepSeek have native default models.
- OpenAI-compatible backends are local-only transports today: when SSH workers
  are configured, their sessions remain on the orchestrator host. They are
  deliberately non-resumable, so backend switches continue from shared
  workspace state rather than a cross-provider transcript.
- `agent.prior_work_continuation` defaults to `true`; a cold redispatch or
  backend switch receives continuation guidance based on the existing shared
  workspace instead of pretending the provider conversation was resumed.
- Codex defaults to safer policies when omitted (`approval_policy` rejects unprompted
  approvals, `thread_sandbox` is `workspace-write`).
- Setting `agent.codex.thread_sandbox: danger-full-access` also defaults Codex turns to
  `dangerFullAccess` unless `turn_sandbox_policy` is explicitly configured.
- Local Codex `workspaceWrite` turns derive the current issue workspace and, when
  enabled, the shared GitHub budget directory. Configured `writableRoots` are
  daemon-host extras: each must already be a writable directory, and extras are not
  forwarded to SSH workers, which derive their own remote workspace roots.
- `agent.max_turns` caps how many back-to-back backend turns Aiur runs in a single
  invocation when a turn completes but the issue is still active. Default: `20`.
- `agent.max_turns_by_complexity` optionally overrides that cap for tickets with
  `complexity:N` labels, for example `{1: 4, 2: 8, 3: 12}`. Missing levels and
  unlabeled tickets continue to use `agent.max_turns`.
- `agent.max_concurrent_agents` caps active workers only. Paused agents remain visible
  and can keep their panes open without consuming an active slot.
- An explicit `aiur --max-agents N` launch value takes precedence over
  `agent.max_concurrent_agents`, including when it is higher. Aiur warns when
  the CLI value exceeds the configured value so the effective cap is visible; omit the flag or set it at
  or below the configured value to silence the warning.
- `agent.switch_model_on_ratelimit` is an opt-in ordered list of configured
  backends, for example `[claude, codex]`. It applies only when no explicit
  `model:` label or complexity-routing rule selected a backend, and only to new
  claims: a running agent stays on the backend it started with.
- Aiur records rate-limit observations in `model-usage.json` next to the active
  workflow config. Each backend entry contains any reported `hourly`, `weekly`,
  and `monthly` `{used, limit, reset_at}` windows plus `observed_at`; Executors
  can inspect or remove this file while Aiur is stopped. Codex refreshes its
  authenticated account windows with `account/rateLimits/read` when a Codex
  session starts and also records streaming updates and runtime usage-limit
  failures. The Claude transports currently expose no equivalent authenticated
  account-usage endpoint, so they participate when a runtime limit is reported.
  Unknown reset times expire after one hour rather than excluding a backend
  forever for new dispatches. The running-agent fallback does not treat that
  estimate alone as recovery; it waits for a positive Codex observation or a
  real reported reset time.
- When every eligible fallback backend is limited, Aiur leaves the ticket
  unclaimed and emits one visible pause/retry alert until availability changes;
  it does not busy-loop dispatch attempts.
- `agent.rate_limit_fallback` (default `claude`) automatically reroutes an
  **already-running** codex agent to the headless Claude backend when it pauses on
  `usage_limit_exhausted`, and reverts it back to codex at a safe turn boundary
  after a positive recovery observation or a real reported reset. Unlike
  `switch_model_on_ratelimit` above (opt-in, new claims only), this is
  default-on and acts on a running agent. Set it to `""` to disable. After
  upgrading an existing GitHub workflow, run `aiur init` once to provision the
  marker and `model:claude` labels used by the automatic switch. Headless Claude
  currently runs on the orchestrator host, so Aiur leaves Codex agents on SSH
  worker workspaces parked instead of moving them to an unrunnable backend.
- `agent.max_cpu_pressure` caps dispatch on Linux CPU PSI `some avg60`
  (default `20.0` percent). High I/O load does not hold low-pressure dispatch.
  Set it to `null` to disable the hard ceiling.
- `agent.target_cpu_pressure` sets the AIMD target (default `10.0` percent).
  Three fresh above-target samples halve capacity, bounded by the decrease
  cooldown. Ramps require pressure below 80% of target; unavailable samples
  reset the streak. Set the target to `null` to disable PSI AIMD.
- `agent.load_resume_max_age_seconds` retains safe capacity for 21600 seconds;
  0 disables resume. Five fresh occupied samples demonstrate a level. Boot
  starts at one and the first fresh sample holds. Recovery below 80% of the
  PSI target doubles, at most +3, toward that level.
- When PSI is unavailable, `max_load_average` (default `1.5`) and
  `target_load_average` (default `1.0`) are per-scheduler fallbacks. Status
  names the binding signal. Build cap, stagger and nice throttle bursts.
- `agent.min_free_memory_mb` optionally sets a Linux `MemAvailable` floor for
  normal new-work dispatch and local agent `mix compile` / `mix test` commands.
  Omit it to disable memory admission. Values are whole MB derived from
  `/proc/meminfo`; an unreadable sample fails open for non-Linux development
  hosts. A low-memory dispatch emits `aiur_perf memory_hold surface=dispatch`,
  while a local Mix command waits before claiming a build slot and emits the
  same phase with `surface=build`. Dispatch or builds resume once available
  memory is at or above the configured floor.
- Aiur also keeps a default-on file-descriptor reserve for normal new-work
  dispatch. It compares the daemon's open descriptors with its finite soft
  `ulimit -n` and holds dispatch below 10% remaining headroom (rounded up to a
  whole descriptor). Linux samples come from `/proc/<pid>/fd` and
  `/proc/<pid>/limits`; the shared launcher exports its effective post-raise
  limit so the daemon can use `/dev/fd` on supported non-procfs hosts. Missing
  platform data fails open, while a sampling `:emfile` fails closed until the
  next poll. Holds emit `aiur_perf fd_hold surface=dispatch` with the used,
  limit, available, and threshold values. `Aiur.SystemFileDescriptors.sample/1`
  exposes the same raw per-process sample for controller and telemetry consumers.
- `agent.max_concurrent_builds` caps agent-launched `mix compile` and `mix test`
  commands across all local workspaces for the current OS user. It defaults to `4`; agents queue only their Mix verification
  while ordinary editing, Git, and model work continue. Set it to `0` to remove
  the concurrency cap; a configured memory floor or start stagger remains active
  independently.
  Local Codex, Claude, and Muse launches prepend shell-independent `elixir`, `mix`, and
  `mise` entrypoints, and local workspace lifecycle hooks run with the same admission
  environment before agent support is installed. This keeps `after_create` and
  `before_run` warm-up builds under the fleet cap as well as builds started during
  agent turns.
  Admission recognizes direct `mix compile` / `mix test`, `mix do` compounds separated
  by `+` or the legacy comma grammar, `elixir -S mix`, and `mise exec` / `mise x`
  commands passed after `--` or as a simple `-c` / `--command` string. A compound holds
  one lease for its whole invocation; nested wrappers reuse it only while its token is
  live. Malformed compounds and shell command strings that could hide Mix fail with
  status `125` instead of running ambiguously.
  The gate is cooperative: it covers Aiur's installed PATH entrypoints and Bash
  functions, including aliases of those wrappers, but a command that deliberately
  invokes a separate real executable by absolute, relative, or symlinked path never
  enters those entrypoints and cannot be intercepted.
  Local Codex `workspaceWrite` turns also add the canonical `~/.aiur/build-gate` metadata
  directory to `writableRoots` without replacing configured, workspace, budget, or
  writable Git roots. Persistent lock inodes live in the host-prepared sibling
  `~/.aiur/build-gate.locks`, which is deliberately excluded from turn-writable roots so
  a sandbox cannot unlink or replace a held slot. Linux admission uses a lock-owning
  subreaper, so sandbox-local PID/PGID values are diagnostic only and detached Mix
  descendants keep their slot until they exit.
  Agent transcripts emit
  `aiur_build_gate` queue/acquire/release/timeout signals, and `aiur status` reports
  active or queued contention.
- Gate coordination errors return status `125` without invoking Mix. Repair the path
  named by the error (metadata or lock-directory type, ownership, permissions, missing
  `flock`, or missing `python3` subreaper support) and
  restart/re-dispatch the affected agents. `BUILD GATE DEGRADED` means legacy or
  unreadable metadata needs attention. Stop/re-dispatch the old fleet, confirm no old
  `mix compile` or `mix test` process is still running, then remove only the reported
  legacy records and retry. Do not delete legacy records while old builds may still be
  live. As a deliberate emergency opt-out, set `agent.max_concurrent_builds: 0`, set
  `agent.build_start_stagger_seconds: 0`, omit `agent.min_free_memory_mb`, and
  restart/re-dispatch. All three settings can enable the shared gate; this sequence
  disables build admission entirely and removes its fleet safeguards.
- `agent.build_start_stagger_seconds` optionally separates admitted local `mix compile`
  and `mix test` starts at their actual heavy-command boundary. It defaults to `0`
  (disabled); this repository's dogfood workflow uses `5`. The memory floor runs
  before build-slot acquisition, then a multi-slot or unlimited gate waits until the
  configured start interval has elapsed. A one-slot build cap already serializes
  starts and therefore skips the extra delay. Whole-second portable timing may round
  the interval up by less than one second. Delays emit
  `aiur_perf phase_stagger_hold surface=build phase=<compile|test> wait_seconds=<n>`;
  paced multi-slot work remains visible as active capacity, and phase-only work stays
  queued until it starts. Set the interval to `0` to disable pacing independently of
  the memory and build-cap gates.
- Build-gate settings are captured when each agent process starts. Restart or
  re-dispatch the fleet after changing them. To tune staggering, compare at least
  three enabled and three disabled runs with the same tickets, revision, agent cap,
  build cap, and scheduler cap; compare median peak load and wall time. The dogfood
  acceptance target is at least 10% lower median peak load with no more than 10%
  median completion-time regression. If no fixed interval meets both, leave pacing
  disabled and prefer load-aware admission rather than hiding the throughput loss.
- Use `hooks.after_create` to bootstrap a fresh workspace (typically a `git clone`).
- Optional alert sounds play when an agent gets stuck or needs input. Enable via the
  `alerts:` block in `.aiur/config` (offered during `aiur init`): `enabled` is the master
  switch; `use_os_default_sounds: true` plays built-in macOS/Linux system sounds out of the
  box (macOS via `afplay`, Linux via `paplay`/`canberra-gtk-play`/`aplay`); `sound_dir`
  points at a folder of custom clips that overrides the defaults; `alerts_file` points at the
  topic→sound map. `aiur init` scaffolds an editable `.aiur/alerts` and sets `alerts_file: alerts`
  (a relative value resolves next to `.aiur/config`); an absolute or `~/` path points elsewhere,
  and when the file is unset or missing aiur falls back to the default `.aiur/alerts` next to
  the config. Playback is fully gated by `enabled` and is a no-op when no
  player binary or sound file is available.
