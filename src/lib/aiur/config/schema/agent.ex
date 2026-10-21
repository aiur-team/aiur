defmodule Aiur.Config.Schema.Claude do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    # @config-reference config-configuration-agent-04 agent.claude.command | string | `aiur-claude` | Command launching the Claude backend. |
    field(:command, :string, default: "aiur-claude")
    # @config-reference config-configuration-agent-04 agent.claude.model | string or nil | nil | Optional Claude model override. |
    field(:model, :string)
    # @config-reference config-configuration-agent-04 agent.claude.permission_mode | string | `bypassPermissions` | Claude permission mode. |
    field(:permission_mode, :string, default: "bypassPermissions")
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:command, :model, :permission_mode], empty_values: [])
    |> validate_length(:command, min: 1)
  end
end

defmodule Aiur.Config.Schema.Rtk do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    # Controls whether the analytics panel reports host-level rtk output
    # savings. This does not enable or disable a host-wide rtk hook; the
    # operator owns that hook and must configure it to exclude `gh`.
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-reference config-configuration-agent-00 agent.rtk.enabled | boolean | false | Enables the Agent output compression panel on the analytics page, which reports rtk's host-level output savings when available. Aiur does not install, enable, or disable rtk's hook and does not enforce this setting at agent dispatch. A host-wide rtk hook applies to every agent regardless of this setting; the operator owns the hook and must exclude `gh` (`exclude_commands = ["gh"]` under `[hooks]`), because `gh` in an agent workspace is the GitHub quota guard and rtk must not rewrite it. The analytics panel reports rtk's status, including when its probe detects that `gh` would be rewritten, but cannot disable the hook. At daemon startup Aiur also checks the host hook, independent of this setting, and raises an informational alert when it would rewrite `gh`. |
    field(:enabled, :boolean, default: false)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    cast(schema, attrs, [:enabled], empty_values: [])
  end
end

defmodule Aiur.Config.Schema.Agent do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  alias Aiur.Config.CatalogValidation
  alias Aiur.Config.Schema.{AgentValidation, Claude, Codex, GitIdentity, PricingPolicy, Rtk}

  @default_backend "codex"
  @default_rate_limit_fallback "claude"
  @primary_key false
  embedded_schema do
    # Deprecated: `priority` wins when present; read the effective value via `Aiur.Config.agent_kind/0`.
    # @config-reference config-configuration-agent-00 agent.kind | string | `codex` | Deprecated default backend; ignored when `agent.priority` is non-empty. |
    field(:kind, :string, default: @default_backend)

    # Ordered dispatch preference. Presence enables a backend, the first available entry is the default, and the array is the fallback order when a backend hits a token or usage limit.
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-reference config-configuration-agent-00 agent.priority | array | `[]` | Ordered dispatch preference, as **routes** (`backend` or `backend:model`); see [Routes in `agent.priority`](#routes-in-agent-priority). Presence makes a backend dispatchable, the first available entry is the default, and limits advance to the next entry until recovery. A non-empty list replaces `agent.kind`, `agent.switch_model_on_ratelimit`, and `backend_configs.<b>.enabled`. |
    field(:priority, {:array, :string}, default: [])
    # Setting #2 (RC opt-in), orthogonal to :kind. Only consulted when the
    # resolved backend is RC-capable. This default is the single flip point
    # for always-remote: change `false` here and every dispatch attaches RC.
    # @config-reference config-configuration-agent-00 agent.remote_control | boolean | false | Opts RC-capable backends into remote control. |
    field(:remote_control, :boolean, default: false)
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-reference config-configuration-agent-00 agent.relay | boolean | true | Runs local Codex app-server and headless Claude behind a detached relay that retains provider output between controller connections. `false` uses the direct Port transport. Remote SSH workers keep their existing transport; normal stop and the BEAM-death watchdog still reap agents. On Linux the relay adopts every process an agent command leaves behind, even one that called `setsid` or was orphaned, and kills it at each turn's start and end and when the provider exits; the direct Port transport does not. |
    field(:relay, :boolean, default: true)
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-reference config-configuration-agent-00 agent.relay_orphan_timeout_seconds | integer | 1800 | Stops the provider process group after this many seconds without a relay controller. Must be positive. |
    field(:relay_orphan_timeout_seconds, :integer, default: 1_800)
    # When true, a re-dispatch of a ticket the orchestrator already ran (a
    # max_turns recycle or completed-entry replacement) whose codex thread could
    # not be resumed gets continuation guidance instead of the cold-start prompt,
    # so it does not re-run brainstorm/plan over work that already exists.
    # @config-reference config-configuration-agent-00 agent.prior_work_continuation | boolean | true | Lets a resumed ticket continue existing workspace work when policy permits. |
    field(:prior_work_continuation, :boolean, default: true)
    # Lifetime cap on (re)dispatches for one ticket. The per-window thrash
    # breaker resets whenever its window lapses, so a slowly-churning ticket is
    # never circuit-broken. 0 disables the latch.
    # @config-reference config-configuration-agent-00 agent.max_dispatches_per_ticket | integer | 0 | Per-ticket dispatch latch; 0 disables the latch. |
    field(:max_dispatches_per_ticket, :integer, default: 0)
    # Ceiling for new fleet admissions. When omitted (nil), it derives from the
    # measured host capacity (see `Config.default_max_concurrent_agents/1`):
    # schedulers + 1/4 schedulers, which matches the measured ~19-20 concurrent
    # agents on a 16-core host. Explicit config still wins. The load envelope
    # reduces effective concurrency below this ceiling under host pressure.
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-reference config-configuration-agent-00 agent.max_concurrent_agents | integer or nil | derived from host capacity | Global simultaneous-agent cap. When omitted, it derives from the measured host capacity: `schedulers + schedulers / 4` (e.g. 20 on a 16-core host), so the ceiling is calibrated to the box instead of a hard-coded count. Explicit config wins. The adaptive envelope reduces effective concurrency below this ceiling under CPU pressure. [Fixer tickets](/reference/merge-policy) take the next free slot first, within this cap and the same pressure gates. |
    field(:max_concurrent_agents, :integer)
    # Per-scheduler runnable-process ceiling for the instantaneous run-queue
    # dispatch gate. nil disables the gate (the 1-minute load gate and envelope
    # still apply); a positive value holds new dispatch while `procs_running`
    # strictly exceeds `run_queue_threshold * schedulers`, catching short CPU
    # bursts the lagging load average smooths out.
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-reference config-configuration-agent-00 agent.run_queue_threshold | float or nil | nil | Optional per-scheduler runnable ceiling used only when CPU PSI is unavailable. Subtracts CPU niced above the daemon and outside registered fleet-agent trees; holds above the scaled ceiling only below 60% reclaimable CPU; null disables it. |
    field(:run_queue_threshold, :float)
    # Fleet-wide cap for agent-launched `mix compile` / `mix test` commands.
    # 0 deliberately disables the gate for Executors who need unrestricted
    # local verification.
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-reference config-configuration-agent-00 agent.max_concurrent_builds | integer | 4 | Caps local agent Mix verification and browser tests; 0 disables the concurrency cap. Busy or queued builds wait at the build gate without holding fleet dispatch. |
    field(:max_concurrent_builds, :integer, default: 4)
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-reference config-configuration-agent-00 agent.build_nice | integer | 10 | CPU nice adjustment (0–19) applied once to admitted build commands and inherited by descendants; 0 preserves launch priority. Nested builds reuse the lease without another adjustment. Build processes under registered agent relays remain counted by soft load/run-queue admission; build capacity also counts them. |
    field(:build_nice, :integer, default: 10)
    # Minimum spacing between local Mix compile/test starts when more than one
    # build may run concurrently. 0 disables start pacing.
    # @config-reference config-configuration-agent-00 agent.build_start_stagger_seconds | integer | 0 | Minimum spacing between local Mix build starts; 0 disables pacing. |
    field(:build_start_stagger_seconds, :integer, default: 0)
    # Optional Linux MemAvailable floor shared by normal dispatch and the local
    # Mix build gate. Omitted means memory admission is disabled.
    # @config-reference config-configuration-agent-00 agent.min_free_memory_mb | integer or nil | nil | Linux `MemAvailable` floor shared by dispatch and the Mix build gate. |
    field(:min_free_memory_mb, :integer)
    # Absolute wall-clock cap (seconds) on how long any one build-gate slot may
    # be held (#2349). The detached lease holder releases the slot at the cap
    # and the daemon raises a needs-attention alert naming the command. 0
    # disables the backstop.
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-reference config-configuration-agent-00 agent.build_gate_max_hold_seconds | integer | 3600 | Absolute wall-clock cap on how long one build-gate slot may be held. The lease holder releases the slot at the cap and the daemon raises a needs-attention alert naming the command; `0` disables the backstop. |
    field(:build_gate_max_hold_seconds, :integer, default: 3_600)
    # Maximum post-command courtesy window (seconds) the detached holder keeps
    # a slot after the wrapped command exits, gated on a descendant still
    # consuming CPU (#2398). The holder releases the moment the retained tree
    # goes idle, so this is the *ceiling* for a genuinely-busy descendant, not
    # a per-build hold. 0 disables the courtesy.
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-reference config-configuration-agent-00 agent.build_gate_retain_seconds | integer | 120 | Maximum post-command window the lease holder keeps a slot after the wrapped command exits, gated on a descendant still consuming CPU. The holder releases the moment the retained tree goes idle, so this bounds only a genuinely-busy descendant (a runaway build), not an adopted idle daemon; `0` disables the courtesy. |
    field(:build_gate_retain_seconds, :integer, default: 120)
    # nil = uncapped (no per-issue turn limit). A YAML value of `none` /
    # `unlimited` (or an absent key) resolves to nil; any present number must
    # be > 0.
    #
    # #2806 asked whether this should default to a finite value, and the answer
    # is no. This cap counts *effort*, not outcome: it cannot tell eleven wasted
    # turns from eleven turns of real work, so any default low enough to stop a
    # spin is also low enough to cut a legitimate long run short. Reaching it
    # does not abort the ticket — the loop hands control back and the
    # orchestrator recycles the ticket with `prior_work: true` — but that costs
    # a fresh provider session and the context rebuild #378 exists to avoid.
    # `max_consecutive_noop_turns` below is the outcome-based bound instead:
    # productive turns are unbounded, unproductive ones are not. Operators who
    # do want an effort cap set this key, or `max_turns_by_complexity`.
    # @config-reference config-configuration-agent-00 agent.max_turns | integer or nil | nil | Per-issue turn cap; nil is uncapped. |
    field(:max_turns, :integer)
    # #2806: how many CONSECUTIVE continuation turns that changed nothing
    # observable (no commit, no push, no working-tree change, no label change,
    # and no new input in the prompt) a run may take before the loop stops and
    # raises a needs-attention alert. A productive turn resets the count, so
    # this never caps a long run of real work — unlike `max_turns`, which does.
    # 0 / `nil` disables the bound.
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-reference config-configuration-agent-00 agent.max_consecutive_noop_turns | integer | 3 | Consecutive continuation turns that changed nothing observable (no commit, no push, no working-tree change, no label change, no new input) before the loop stops and raises a needs-attention alert. An open PR is handed to CI wait or human review; so is rework whose head is newer than every blocking review, red CI included; rework with nothing pushed for its review becomes `agent:error`; otherwise the current label is kept. After the first no-op turn the worker parks and waits for a queued ticket event or operator message instead of re-prompting (a pushed rework PR is handed off right away); the count survives the wake, so the bound caps wakes that still change nothing. A productive turn resets the count; 0 disables the bound. The park lasts at most two minutes: on timeout the worker resumes with a normal turn and the surviving count still ends an idle ticket. |
    field(:max_consecutive_noop_turns, :integer, default: 3)
    # @config-reference config-configuration-agent-00 agent.max_retry_attempts | integer | 3 | Failed-turn retry count. |
    field(:max_retry_attempts, :integer, default: 3)
    # @config-reference config-configuration-agent-00 agent.max_retry_backoff_ms | integer | 300000 | Retry backoff ceiling in milliseconds. |
    field(:max_retry_backoff_ms, :integer, default: 300_000)
    # @config-reference config-configuration-agent-00 agent.max_concurrent_agents_by_state | map | `%{}` | Per-state caps overriding the global cap. These caps also constrain fixer tickets. |
    field(:max_concurrent_agents_by_state, :map, default: %{})
    # Provider settings are keyed by the backend's registry name. Built-in
    # schemas remain as typed compatibility views, while a new backend can keep
    # its section here without adding another Ecto embed to this module.
    # Provider-specific map paths are expanded by scripts/check-config-docs.py.
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-reference config-configuration-agent-01 agent.backend_configs.<backend>.enabled | boolean | backend registry default | Explicitly enables or disables dispatch for the backend. `agent.priority` takes precedence by enabling every backend it names. |
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-reference config-configuration-agent-01 agent.backend_configs.<backend>.command | string | backend registry command | Overrides the backend command used for model discovery and setup where supported. |
    # @config-reference config-configuration-agent-01 agent.backend_configs.<backend>.model | string or nil | nil | Selects the backend's default model where the backend accepts a configured model. |
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-reference config-configuration-agent-06 agent.backend_configs.<backend>.model_discovery | boolean | true | Set `false` to stop aiur asking this backend for its model list — the catalogue endpoint for an OpenAI-compatible backend, or the CLI's `model/list` for `codex` and `claude`. The curated list and any list already cached keep working; aiur just stops refreshing them. |
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-reference config-configuration-agent-01 agent.backend_configs.<backend>.default_model | string or nil | backend registry value | Overrides the registry fallback model for an OpenAI-compatible backend; `model` takes precedence. |
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-reference config-configuration-agent-01 agent.backend_configs.<backend>.base_url | URL string | backend registry value | Overrides the registry endpoint for an OpenAI-compatible backend. |
    # @config-reference config-configuration-agent-01 agent.backend_configs.<backend>.api_key_env | string | backend registry value | Names the environment variable containing the backend API key. |
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-reference config-configuration-agent-01 agent.backend_configs.<backend>.management_api_key_env | string or nil | backend registry value | Names the environment variable containing a provider's usage-management API key. |
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-reference config-configuration-agent-01 agent.backend_configs.<backend>.transport | string | backend registry value | Overrides the OpenAI-compatible transport with `chat_completions` or `responses`. |
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-reference config-configuration-agent-01 agent.backend_configs.<backend>.balance_baseline | number or nil | nil | Seeds prepaid-balance usage tracking for backends that expose a balance API. |
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-reference config-configuration-agent-01 agent.backend_configs.<backend>.quirks.reasoning_content_replay | boolean | backend registry value | Replays reasoning content when the backend requires it in later requests. |
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-reference config-configuration-agent-01 agent.backend_configs.<backend>.quirks.text_tool_fallback | boolean | backend registry value | Parses text-encoded tool calls when the backend does not return structured calls. |
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-reference config-configuration-agent-01 agent.backend_configs.<backend>.quirks.openrouter_metadata | boolean | backend registry value | Enables OpenRouter endpoint metadata used for billing attribution. |
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-reference config-configuration-agent-01 agent.backend_configs.<backend>.quirks.local_concurrency_limit | boolean | backend registry value | Applies aiur's local concurrency slot around backend requests. |
    # @config-reference config-configuration-agent-02 agent.backend_configs.openrouter.provider.order | array of strings or nil | omitted | Preferred upstream providers, most preferred first. |
    # @config-reference config-configuration-agent-02 agent.backend_configs.openrouter.provider.ignore | array of strings or nil | omitted | Upstream providers to exclude. |
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-reference config-configuration-agent-02 agent.backend_configs.openrouter.provider.allow_fallbacks | boolean or nil | omitted | Whether OpenRouter may cross to another upstream within one request. |
    # @config-reference config-configuration-agent-02 agent.backend_configs.openrouter.provider.sort | string or nil | omitted | `price`, `throughput`, or `latency`. |
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-reference config-configuration-agent-00 agent.backend_configs | map | `%{}` | Provider-specific configuration, including per-backend settings and credentials for OpenAI-compatible backends. A backend listed in `agent.priority` is enabled automatically. |
    field(:backend_configs, :map, default: %{})
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-reference config-configuration-agent-00 agent.routing | map | `%{}` | Maps complexity levels to backend/model/effort routing. A value is one route (`"claude:sonnet"`) or, for `account_selection: headroom`, a list of the routes that level allows (`["claude:sonnet", "codex:gpt-5.5:high"]`). Every other policy and reader uses the list's first route. Claude takes no effort segment: `claude:sonnet:medium` is rejected. |
    field(:routing, :map, default: %{})
    # Derived, never cast: every level's route list when a routing value is a
    # list (`AgentValidation.split_routing_candidates/1`, #3960).
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-reference config-configuration-agent-00 agent.routing_candidates | map | `%{}` | Read-only: every level's route list, derived from list values in `agent.routing`. A value set here is ignored. |
    field(:routing_candidates, :map, default: %{})
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-reference config-configuration-agent-00 agent.accounts | map | `%{}` | Machine-local account names enabled per harness, for example `{claude: [default, max]}`. The list is priority order; absent or empty keeps the existing single-account behavior. Claude and Codex use isolated profile directories; Kimi, DeepSeek, and OpenRouter use named API keys; Muse is unsupported. See [accounts by backend](/guide/claude-accounts). |
    field(:accounts, :map, default: %{})
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-reference config-configuration-agent-00 agent.account_selection | string | `balance` | Selects an enabled account by lowest weekly utilization (`balance`) or first configured name (`priority`). `headroom` scores every allowed backend **and** account at dispatch and picks the one with the most remaining usage; see [Headroom dispatch](/concepts/headroom-dispatch). Usage-based selection applies to Claude and Codex; API-key account usage is unavailable. |
    field(:account_selection, :string, default: "balance")
    # Headroom dispatch treats a usage reading older than this as unknown (#3960).
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-reference config-configuration-agent-00 agent.headroom_reading_max_age_seconds | integer | 1800 | Under `account_selection: headroom`, a usage reading older than this scores as unknown and shows its age; see [Headroom dispatch](/concepts/headroom-dispatch). |
    field(:headroom_reading_max_age_seconds, :integer, default: 1800)
    # @config-reference config-configuration-agent-00 agent.switch_model_on_ratelimit | array | `[]` | Deprecated claim-time fallback order; ignored when `agent.priority` is non-empty. |
    field(:switch_model_on_ratelimit, {:array, :string}, default: [])
    # Automatic reroute for an ALREADY-RUNNING agent on `rate_limit_primary`
    # that hits usage_limit_exhausted, reverted at a safe boundary once
    # ModelAvailability confirms the primary recovered
    # (Aiur.Orchestrator.RateLimitFallback). Default on, unlike
    # switch_model_on_ratelimit above (opt-in, applies only to a new claim).
    # Both name a registered backend and the pair is validated below; the
    # defaults preserve the historical codex -> claude reroute. "" on the
    # fallback disables it.
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-reference config-configuration-agent-00 agent.rate_limit_primary | string | default backend | Deprecated primary backend watched for automatic rate-limit recovery; derived from `agent.priority` when set. |
    field(:rate_limit_primary, :string, default: @default_backend)
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-reference config-configuration-agent-00 agent.rate_limit_fallback | string | `claude` | Deprecated automatic recovery backend for an already-running agent; derived from the first eligible `agent.priority` entry after the primary when set; `""` disables it. |
    field(:rate_limit_fallback, :string, default: @default_rate_limit_fallback)
    # @config-reference config-configuration-agent-00 agent.complexity_prompts | map | `%{}` | Adds prompt guidance by complexity level. |
    field(:complexity_prompts, :map, default: %{})
    # @config-reference config-configuration-agent-00 agent.max_turns_by_complexity | map | `%{}` | Per-complexity turn caps. |
    field(:max_turns_by_complexity, :map, default: %{})
    # Backend-agnostic turn/stall timeouts (promoted from codex; claude-repl
    # already reads these via Config.agent_turn_timeout_ms/0).
    # @config-reference config-configuration-agent-00 agent.turn_timeout_ms | integer | 3600000 | Backstop timeout for one turn. |
    field(:turn_timeout_ms, :integer, default: 3_600_000)
    # @config-reference config-configuration-agent-00 agent.stall_timeout_ms | integer | 3600000 | Silent-agent watchdog; 0 disables it. |
    field(:stall_timeout_ms, :integer, default: 3_600_000)
    # Runtime cap in minutes (paused/blocked time excluded); 0 disables it.
    # @config-reference config-configuration-agent-00 agent.max_agent_duration_minutes | integer | 60 | Active-runtime cap; the parked worker is released to rework or human-review. 0 disables it. |
    field(:max_agent_duration_minutes, :integer, default: 60)
    # Re-wake after this many minutes in CI-wait if no terminal event arrives.
    # @config-reference config-configuration-agent-00 agent.ci_wait_rewake_minutes | positive integer | 5 | Re-wakes a CI-wait-paused agent for one recovery check when no terminal event arrives. |
    field(:ci_wait_rewake_minutes, :integer, default: 5)

    # @config-reference config-configuration-agent-00 agent.non_closing_merge_marker | string | `needs-triage` | Marker for a merged PR that references the ticket but does not close it. |
    field(:non_closing_merge_marker, :string, default: "needs-triage")
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-reference config-configuration-agent-00 agent.unreviewed_pr_age_limit_minutes | positive integer | 120 | Re-raises ready PRs with green CI and no review after this many minutes; reminders repeat with the same interval. |
    field(:unreviewed_pr_age_limit_minutes, :integer, default: 120)
    # @config-reference config-configuration-agent-00 agent.ci_recovery_enabled | boolean | true | Enables automatic CI recovery reruns; set `false` to disable them. |
    field(:ci_recovery_enabled, :boolean, default: true)
    # @config-reference config-configuration-agent-00 agent.ci_recovery_max_per_poll | positive integer | 5 | Maximum recovery reruns admitted by one CI poll. |
    field(:ci_recovery_max_per_poll, :integer, default: 5)
    # @config-reference config-configuration-agent-00 agent.ci_recovery_max_per_hour | positive integer | 20 | Maximum recovery reruns admitted in a rolling hour. |
    field(:ci_recovery_max_per_hour, :integer, default: 20)
    # Linux CPU PSI some avg60 percentages; explicit null disables each.
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-reference config-configuration-agent-00 agent.max_cpu_pressure | float or nil | 20.0 | Linux CPU PSI `some avg60` ceiling in percent (greater than 0, at most 100). Holds new dispatch above the ceiling; null disables it. Independent of scheduler count; avg10 is diagnostic and does not gate dispatch. |
    field(:max_cpu_pressure, :float, default: 20.0)
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-reference config-configuration-agent-00 agent.target_cpu_pressure | float or nil | 10.0 | AIMD target for Linux CPU PSI `some avg60`, in percent (greater than 0, at most 100); null disables it. After 3 fresh above-target samples and the decrease cooldown, floors the reduction at half occupied slots or the recorded safe level, capped at the current envelope. Ramps only below 80% of target. Unavailable samples reset the streak and never count as zero. |
    field(:target_cpu_pressure, :float, default: 10.0)
    # Per-scheduler load settings apply only when CPU PSI is unavailable.
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-reference config-configuration-agent-00 agent.max_load_average | float or nil | 1.5 | Per-scheduler load ceiling used only when CPU PSI is unavailable. Uses CPU corroboration when available, otherwise raw load; null disables it. |
    field(:max_load_average, :float, default: 1.5)
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-reference config-configuration-agent-00 agent.target_load_average | float or nil | 1.0 | Per-scheduler adaptive target used only when CPU PSI is unavailable; null disables it. Keeps the legacy 3-sample decrease streak, cooldown, and below-target recovery. |
    field(:target_load_average, :float, default: 1.0)
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-reference config-configuration-agent-00 agent.load_resume_max_age_seconds | integer | 21600 | Safe occupancy record lifetime; 0 disables resume. Five fresh samples demonstrate a level; sustained reductions lower it. Same scheduler count required. Adoption restores the greater of occupancy and the valid record (record bounded by the static cap); new admission still respects the cap. Empty fleets start at one, holding the first fresh sample. |
    field(:load_resume_max_age_seconds, :integer, default: 21_600)
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-reference config-configuration-agent-00 agent.load_ramp_step | integer | 1 | Capacity increase below 80% of the PSI target (at or below the load target in fallback). Saved safe levels allow doubling, at most +3, toward that level; above it, fast probing requires below half target before a sustained decrease. |
    field(:load_ramp_step, :integer, default: 1)
    # @config-reference config-configuration-agent-00 agent.load_cooldown_seconds | integer | 60 | Minimum interval between adaptive capacity reductions. |
    field(:load_cooldown_seconds, :integer, default: 60)
    # Runtime synthetic load-generator cap; nil derives from CPUs, 0 disables.
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-reference config-configuration-agent-00 agent.synthetic_load_process_cap | integer or nil | nil | Caps synthetic CPU load generators per agent process tree; nil derives `max(1, cores / 4)` and 0 disables the guard. A generator is a known command (`yes`, `stress`, `stress-ng`) or any process seen busy-looping for 10 seconds: runnable and burning CPU with no read/write syscall, no new page fault and no voluntary context switch. A tree with at least as many spinning processes as the host has cores is flagged after one sample (about a second) instead. Known commands above the cap are killed. A generator that outlives its agent command (its session leader has exited or init adopted it, and its working directory is under `workspace.root`) is flagged regardless of the cap; that orphan scan is skipped when `workspace.root` is the home directory or one of its ancestors. Every kill or first sighting raises an alert naming the workspace that wakes the Executor: the ticket's `ticket.<N>.agent.attention.synthetic-load` attention, or `system.agent.synthetic_load_cap` when no ticket is known (an orphan). |
    field(:synthetic_load_process_cap, :integer)
    # false = busy-loop-detected and orphaned generators are reported, not killed.
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-reference config-configuration-agent-00 agent.synthetic_load_kill_detected | boolean | false | When false, a busy loop detected by behaviour and any orphaned generator are report-only: logged with pid and command line and alerted once, but left running. Set true to kill them too (busy loops above the cap, orphans outright). |
    field(:synthetic_load_kill_detected, :boolean, default: false)
    # Cap ERTS scheduler threads on agent-spawned Mix BEAMs via
    # ELIXIR_ERL_OPTIONS="+S N:N". ExUnit defaults max_cases to this value, so
    # four bounds every agent test shape without relying on prompt compliance.
    # @config-reference config-configuration-agent-00 agent.mix_scheduler_cap | integer | 4 | Caps schedulers in agent-launched Mix BEAMs. |
    field(:mix_scheduler_cap, :integer, default: 4)
    # Saturation sentinel (#1429): a daemon-side recorder that appends
    # VM-internal + host diagnostics to saturation.log once 1-min load crosses
    # the escalation threshold, so a crash under saturation (the sparse
    # `erl_child_setup` dump has no stack) is interpretable. Default on; set
    # false to disable the recorder.
    # @config-reference config-configuration-agent-00 agent.saturation_log_enabled | boolean | true | Records host and VM diagnostics when sustained load crosses the saturation threshold. |
    field(:saturation_log_enabled, :boolean, default: true)
    # Minimum seconds a ready-work capacity-starvation condition must persist
    # before `system.dispatch.capacity_starved` / `system.fleet.capacity.starved`
    # raise. The below-target dispatch ramp clears itself within a few poll
    # cycles, so this dwell keeps the intended ramp quiet while a genuine gate
    # that outlives the bound still raises (#2447).
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-reference config-configuration-agent-00 agent.capacity_starvation_alert_after_seconds | integer | 60 | Minimum seconds a ready-work capacity-starvation condition must persist before `system.dispatch.capacity_starved` / `system.fleet.capacity.starved` raise. The below-target dispatch ramp clears itself within a few poll cycles, so this dwell keeps the intended ramp quiet while a genuine gate that outlives the bound still raises. |
    field(:capacity_starvation_alert_after_seconds, :integer, default: 60)
    # The sliding window over which budget-broker-timeout retries are counted
    # (#2464). The retry rate is the whole signal — the individual retry is
    # uninteresting — and this is how much recent history the rate is measured
    # over. The measured 2026-08-24 fault produced 28 timeouts in ~10 minutes.
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-reference config-configuration-agent-00 agent.budget_broker_rate_window_seconds | integer | 300 | The sliding window over which budget-broker-timeout retries are counted for the retry-rate signal. The individual retry is uninteresting; the rate is the signal. |
    field(:budget_broker_rate_window_seconds, :integer, default: 300)
    # The retry count within the window above which the broker counts as
    # degraded. Default sits above an isolated timeout (which must page nobody)
    # while keeping "if the normal rate is zero, almost any sustained rate is
    # worth surfacing". Derived from a measured quiet-period baseline, not
    # guessed — this is the knob an operator tunes from their own baseline.
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-reference config-configuration-agent-00 agent.budget_broker_degraded_retry_threshold | integer | 5 | The retry count within the window above which the budget broker counts as degraded. Set from a measured quiet-period baseline — if the normal rate is zero, almost any sustained rate is worth surfacing — and kept above an isolated timeout, which must page nobody. |
    field(:budget_broker_degraded_retry_threshold, :integer, default: 5)
    # How long the degraded retry rate must persist before the single
    # `system.github.budget_broker_degraded` alert raises (#2434/#2449 dwell):
    # a momentary blip that clears within this bound produces nothing, a
    # sustained degradation raises exactly once. Kept longer than the rate
    # window so a burst that stops ages out of the window before the dwell
    # completes — the dwell then filters exactly the momentary cases.
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-reference config-configuration-agent-00 agent.budget_broker_degraded_alert_after_seconds | integer | 600 | How long the degraded budget-broker retry rate must persist before the single `system.github.budget_broker_degraded` alert raises (the dwell): a momentary blip that clears within this bound produces nothing, a sustained degradation raises exactly once. |
    field(:budget_broker_degraded_alert_after_seconds, :integer, default: 600)
    # A dispatch declined by a local GitHub budget hold is a retry. It raises an
    # Executor attention only once the same ticket has been declined this many
    # times in a row (#4067).
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-reference config-configuration-agent-00 agent.dispatch_hold_attention_threshold | integer | 3 | Consecutive dispatch declines caused by local GitHub budget holds on one ticket before Aiur raises an Executor attention. Earlier declines retry on the next dispatch poll; a successful dispatch validation or a different failure clears the count. |
    field(:dispatch_hold_attention_threshold, :integer, default: 3)
    embeds_one(:claude, Claude, on_replace: :update, defaults_to_struct: true)
    embeds_one(:codex, Codex, on_replace: :update, defaults_to_struct: true)
    embeds_one(:git_identity, GitIdentity, on_replace: :update, defaults_to_struct: true)
    embeds_one(:pricing_policy, PricingPolicy, on_replace: :update, defaults_to_struct: true)
    embeds_one(:rtk, Rtk, on_replace: :update, defaults_to_struct: true)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(
      AgentValidation.prepare_attrs(attrs),
      [
        :kind,
        :priority,
        :remote_control,
        :relay,
        :relay_orphan_timeout_seconds,
        :prior_work_continuation,
        :max_dispatches_per_ticket,
        :max_concurrent_agents,
        :run_queue_threshold,
        :max_concurrent_builds,
        :build_nice,
        :build_start_stagger_seconds,
        :min_free_memory_mb,
        :build_gate_max_hold_seconds,
        :build_gate_retain_seconds,
        :max_turns,
        :max_retry_attempts,
        :max_retry_backoff_ms,
        :max_concurrent_agents_by_state,
        :backend_configs,
        :routing,
        :accounts,
        :account_selection,
        :headroom_reading_max_age_seconds,
        :switch_model_on_ratelimit,
        :rate_limit_primary,
        :rate_limit_fallback,
        :complexity_prompts,
        :max_turns_by_complexity,
        :turn_timeout_ms,
        :stall_timeout_ms,
        :max_agent_duration_minutes,
        :ci_wait_rewake_minutes,
        :non_closing_merge_marker,
        :unreviewed_pr_age_limit_minutes,
        :ci_recovery_enabled,
        :ci_recovery_max_per_poll,
        :ci_recovery_max_per_hour,
        :max_cpu_pressure,
        :target_cpu_pressure,
        :max_load_average,
        :target_load_average,
        :load_resume_max_age_seconds,
        :load_ramp_step,
        :load_cooldown_seconds,
        :synthetic_load_process_cap,
        :synthetic_load_kill_detected,
        :mix_scheduler_cap,
        :saturation_log_enabled,
        :capacity_starvation_alert_after_seconds,
        :budget_broker_rate_window_seconds,
        :budget_broker_degraded_retry_threshold,
        :budget_broker_degraded_alert_after_seconds,
        :dispatch_hold_attention_threshold
      ],
      empty_values: []
    )
    |> validate_number(:relay_orphan_timeout_seconds, greater_than: 0)
    |> validate_number(:max_concurrent_agents, greater_than: 0)
    |> validate_inclusion(:account_selection, ["balance", "priority", "headroom"])
    |> validate_number(:headroom_reading_max_age_seconds, greater_than: 0)
    |> validate_change(:accounts, &validate_accounts/2)
    |> validate_number(:run_queue_threshold, greater_than: 0)
    |> validate_number(:max_concurrent_builds, greater_than_or_equal_to: 0)
    |> validate_required([:build_nice])
    |> validate_number(:build_nice, greater_than_or_equal_to: 0, less_than_or_equal_to: 19)
    |> validate_number(:build_start_stagger_seconds, greater_than_or_equal_to: 0)
    |> validate_number(:min_free_memory_mb, greater_than: 0)
    |> validate_number(:build_gate_max_hold_seconds, greater_than_or_equal_to: 0)
    |> validate_number(:build_gate_retain_seconds, greater_than_or_equal_to: 0)
    |> validate_number(:max_turns, greater_than: 0)
    |> validate_number(:max_dispatches_per_ticket, greater_than_or_equal_to: 0)
    |> validate_number(:max_retry_attempts, greater_than: 0)
    |> validate_number(:max_retry_backoff_ms, greater_than: 0)
    |> validate_number(:turn_timeout_ms, greater_than: 0)
    |> validate_number(:stall_timeout_ms, greater_than_or_equal_to: 0)
    |> validate_number(:max_agent_duration_minutes, greater_than_or_equal_to: 0)
    |> validate_number(:ci_wait_rewake_minutes, greater_than: 0)
    |> validate_length(:non_closing_merge_marker, min: 1)
    |> validate_number(:unreviewed_pr_age_limit_minutes, greater_than: 0)
    |> validate_number(:ci_recovery_max_per_poll, greater_than: 0)
    |> validate_number(:ci_recovery_max_per_hour, greater_than: 0)
    |> validate_number(:max_cpu_pressure, greater_than: 0, less_than_or_equal_to: 100)
    |> validate_number(:target_cpu_pressure, greater_than: 0, less_than_or_equal_to: 100)
    |> validate_number(:max_load_average, greater_than: 0)
    |> validate_number(:target_load_average, greater_than: 0)
    |> validate_number(:load_resume_max_age_seconds, greater_than_or_equal_to: 0)
    |> validate_number(:load_ramp_step, greater_than: 0)
    |> validate_number(:load_cooldown_seconds, greater_than_or_equal_to: 0)
    |> validate_number(:synthetic_load_process_cap, greater_than_or_equal_to: 0)
    |> validate_number(:mix_scheduler_cap, greater_than: 0)
    |> validate_number(:capacity_starvation_alert_after_seconds, greater_than: 0)
    |> validate_number(:budget_broker_rate_window_seconds, greater_than: 0)
    |> validate_number(:budget_broker_degraded_retry_threshold, greater_than: 0)
    |> validate_number(:budget_broker_degraded_alert_after_seconds, greater_than: 0)
    |> validate_number(:dispatch_hold_attention_threshold, greater_than: 0)
    |> CatalogValidation.validate()
    |> update_change(:complexity_prompts, &AgentValidation.normalize_complexity_prompts/1)
    |> AgentValidation.validate_complexity_prompts(:complexity_prompts)
    |> update_change(:max_turns_by_complexity, &AgentValidation.normalize_max_turns_by_complexity/1)
    |> AgentValidation.validate_max_turns_by_complexity(:max_turns_by_complexity)
    |> cast_embed(:claude, with: &Claude.changeset/2)
    |> cast_embed(:codex, with: &Codex.changeset/2)
    |> cast_embed(:git_identity, with: &GitIdentity.changeset/2)
    |> cast_embed(:pricing_policy, with: &PricingPolicy.changeset/2)
    |> cast_embed(:rtk, with: &Rtk.changeset/2)
  end

  defp validate_accounts(field, accounts) when is_map(accounts) do
    if Enum.all?(accounts, fn {harness, names} ->
         is_binary(harness) and is_list(names) and Enum.all?(names, &is_binary/1)
       end) do
      []
    else
      [{field, "must map harness names to lists of account names"}]
    end
  end

  defp validate_accounts(field, _accounts), do: [{field, "must be a map"}]
end
