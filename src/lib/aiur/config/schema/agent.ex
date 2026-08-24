defmodule Aiur.Config.Schema.Codex do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  alias Aiur.Config.Schema.StringOrMap

  @primary_key false
  embedded_schema do
    field(:command, :string, default: "codex app-server")

    # codex app-server expects an enum string (untrusted | on-failure |
    # on-request | granular | never); a map crashes the turn. `untrusted`
    # preserves the prior fail-closed default (only `never` auto-approves).
    field(:approval_policy, StringOrMap, default: "untrusted")

    field(:thread_sandbox, :string, default: "workspace-write")
    field(:turn_sandbox_policy, :map)
    field(:read_timeout_ms, :integer, default: 5_000)
    # Codex-specific thrash guard (moved out of the shared agent section).
    field(:thrash_max_per_window, :integer, default: 6)
    field(:thrash_window_seconds, :integer, default: 60)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(
      attrs,
      [
        :command,
        :approval_policy,
        :thread_sandbox,
        :turn_sandbox_policy,
        :read_timeout_ms,
        :thrash_max_per_window,
        :thrash_window_seconds
      ],
      empty_values: []
    )
    |> validate_required([:command])
    |> validate_length(:command, min: 1)
    |> validate_number(:read_timeout_ms, greater_than: 0)
    |> validate_number(:thrash_max_per_window, greater_than: 0)
    |> validate_number(:thrash_window_seconds, greater_than: 0)
  end
end

defmodule Aiur.Config.Schema.Claude do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field(:command, :string, default: "aiur-claude")
    field(:model, :string)
    field(:permission_mode, :string, default: "bypassPermissions")
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:command, :model, :permission_mode], empty_values: [])
    |> validate_length(:command, min: 1)
  end
end

defmodule Aiur.Config.Schema.Agent do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  alias Aiur.Config.RoutingValue
  alias Aiur.Config.Schema.{AgentValidation, Claude, Codex, PricingPolicy}

  @primary_key false
  embedded_schema do
    # Deprecated: `priority` wins when present; read the effective value via `Aiur.Config.agent_kind/0`.
    field(:kind, :string, default: Aiur.CodingAgent.default_backend())

    # Ordered dispatch preference. Presence enables a backend, the first available entry is the default, and the array is the fallback order when a backend hits a token or usage limit.
    field(:priority, {:array, :string}, default: [])
    # Setting #2 (RC opt-in), orthogonal to :kind. Only consulted when the
    # resolved backend is RC-capable. This default is the single flip point
    # for always-remote: change `false` here and every dispatch attaches RC.
    field(:remote_control, :boolean, default: false)
    # When true, a re-dispatch of a ticket the orchestrator already ran (a
    # max_turns recycle or completed-entry replacement) whose codex thread could
    # not be resumed gets continuation guidance instead of the cold-start prompt,
    # so it does not re-run brainstorm/plan over work that already exists.
    field(:prior_work_continuation, :boolean, default: true)
    # Lifetime cap on (re)dispatches for one ticket. The per-window thrash
    # breaker resets whenever its window lapses, so a slowly-churning ticket is
    # never circuit-broken. 0 disables the latch.
    field(:max_dispatches_per_ticket, :integer, default: 0)
    # Ceiling for new fleet admissions. When omitted (nil), it derives from the
    # measured host capacity (see `Config.default_max_concurrent_agents/1`):
    # schedulers + 1/4 schedulers, which matches the measured ~19-20 concurrent
    # agents on a 16-core host. Explicit config still wins. The load envelope
    # reduces effective concurrency below this ceiling under host pressure.
    field(:max_concurrent_agents, :integer)
    # Per-scheduler runnable-process ceiling for the instantaneous run-queue
    # dispatch gate. nil disables the gate (the 1-minute load gate and envelope
    # still apply); a positive value holds new dispatch while `procs_running`
    # strictly exceeds `run_queue_threshold * schedulers`, catching short CPU
    # bursts the lagging load average smooths out.
    field(:run_queue_threshold, :float)
    # Fleet-wide cap for agent-launched `mix compile` / `mix test` commands.
    # 0 deliberately disables the gate for Executors who need unrestricted
    # local verification.
    field(:max_concurrent_builds, :integer, default: 4)
    # Minimum spacing between local Mix compile/test starts when more than one
    # build may run concurrently. 0 disables start pacing.
    field(:build_start_stagger_seconds, :integer, default: 0)
    # Optional Linux MemAvailable floor shared by normal dispatch and the local
    # Mix build gate. Omitted means memory admission is disabled.
    field(:min_free_memory_mb, :integer)
    # Absolute wall-clock cap (seconds) on how long any one build-gate slot may
    # be held (#2349). The detached lease holder releases the slot at the cap
    # and the daemon raises a needs-attention alert naming the command. 0
    # disables the backstop.
    field(:build_gate_max_hold_seconds, :integer, default: 3_600)
    # Maximum post-command courtesy window (seconds) the detached holder keeps
    # a slot after the wrapped command exits, gated on a descendant still
    # consuming CPU (#2398). The holder releases the moment the retained tree
    # goes idle, so this is the *ceiling* for a genuinely-busy descendant, not
    # a per-build hold. 0 disables the courtesy.
    field(:build_gate_retain_seconds, :integer, default: 120)
    # nil = uncapped (no per-issue turn limit). A YAML value of `none` /
    # `unlimited` (or an absent key) resolves to nil; any present number must
    # be > 0.
    field(:max_turns, :integer)
    field(:max_retry_attempts, :integer, default: 3)
    field(:max_retry_backoff_ms, :integer, default: 300_000)
    field(:max_concurrent_agents_by_state, :map, default: %{})
    # Provider settings are keyed by the backend's registry name. Built-in
    # schemas remain as typed compatibility views, while a new backend can keep
    # its section here without adding another Ecto embed to this module.
    field(:backend_configs, :map, default: %{})
    field(:routing, :map, default: %{})
    field(:switch_model_on_ratelimit, {:array, :string}, default: [])
    # Automatic reroute for an ALREADY-RUNNING agent on `rate_limit_primary`
    # that hits usage_limit_exhausted, reverted at a safe boundary once
    # ModelAvailability confirms the primary recovered
    # (Aiur.Orchestrator.RateLimitFallback). Default on, unlike
    # switch_model_on_ratelimit above (opt-in, applies only to a new claim).
    # Both name a registered backend and the pair is validated below; the
    # defaults preserve the historical codex -> claude reroute. "" on the
    # fallback disables it.
    field(:rate_limit_primary, :string, default: Aiur.CodingAgent.default_backend())
    field(:rate_limit_fallback, :string, default: Aiur.CodingAgent.default_rate_limit_fallback())
    field(:complexity_prompts, :map, default: %{})
    field(:max_turns_by_complexity, :map, default: %{})
    # Backend-agnostic turn/stall timeouts (promoted from codex; claude-repl
    # already reads these via Config.agent_turn_timeout_ms/0).
    field(:turn_timeout_ms, :integer, default: 3_600_000)
    field(:stall_timeout_ms, :integer, default: 3_600_000)
    # Safety checkpoint: pause an agent that has been actively running this
    # many minutes (paused/blocked time excluded). 0 disables it.
    field(:max_agent_duration_minutes, :integer, default: 60)
    # A CI-wait pause releases its dispatch slot. If no terminal CI event is
    # observed in this window, wake the agent for one recovery check.
    field(:ci_wait_rewake_minutes, :integer, default: 5)
    # Per-scheduler 1-min load ceiling for dispatch admission (#465). Exceeded
    # load is corroborated with short-window reclaimable CPU before holding.
    # Explicit YAML null disables it.
    field(:max_load_average, :float, default: 1.5)
    # Per-scheduler 1-min load target for the adaptive concurrency envelope.
    # It ramps capacity while below target and backs off before the separate
    # max_load_average hard gate is reached.
    field(:target_load_average, :float, default: 1.0)
    field(:load_ramp_step, :integer, default: 1)
    field(:load_cooldown_seconds, :integer, default: 60)
    # nil = derive from schedulers_online/4; 0 disables the runtime synthetic
    # load-generator guard; positive integers cap known generators per agent.
    field(:synthetic_load_process_cap, :integer)
    # Cap ERTS scheduler threads on agent-spawned Mix BEAMs via
    # ELIXIR_ERL_OPTIONS="+S N:N". ExUnit defaults max_cases to this value, so
    # four bounds every agent test shape without relying on prompt compliance.
    field(:mix_scheduler_cap, :integer, default: 4)
    # Saturation sentinel (#1429): a daemon-side recorder that appends
    # VM-internal + host diagnostics to saturation.log once 1-min load crosses
    # the escalation threshold, so a crash under saturation (the sparse
    # `erl_child_setup` dump has no stack) is interpretable. Default on; set
    # false to disable the recorder.
    field(:saturation_log_enabled, :boolean, default: true)

    embeds_one(:claude, Claude, on_replace: :update, defaults_to_struct: true)
    embeds_one(:codex, Codex, on_replace: :update, defaults_to_struct: true)
    embeds_one(:pricing_policy, PricingPolicy, on_replace: :update, defaults_to_struct: true)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(
      attrs |> drop_uncapped_max_turns() |> default_mix_scheduler_cap(),
      [
        :kind,
        :priority,
        :remote_control,
        :prior_work_continuation,
        :max_dispatches_per_ticket,
        :max_concurrent_agents,
        :run_queue_threshold,
        :max_concurrent_builds,
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
        :switch_model_on_ratelimit,
        :rate_limit_primary,
        :rate_limit_fallback,
        :complexity_prompts,
        :max_turns_by_complexity,
        :turn_timeout_ms,
        :stall_timeout_ms,
        :max_agent_duration_minutes,
        :ci_wait_rewake_minutes,
        :max_load_average,
        :target_load_average,
        :load_ramp_step,
        :load_cooldown_seconds,
        :synthetic_load_process_cap,
        :mix_scheduler_cap,
        :saturation_log_enabled
      ],
      empty_values: []
    )
    |> validate_number(:max_concurrent_agents, greater_than: 0)
    |> validate_number(:run_queue_threshold, greater_than: 0)
    |> validate_number(:max_concurrent_builds, greater_than_or_equal_to: 0)
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
    |> validate_number(:max_load_average, greater_than: 0)
    |> validate_number(:target_load_average, greater_than: 0)
    |> validate_number(:load_ramp_step, greater_than: 0)
    |> validate_number(:load_cooldown_seconds, greater_than_or_equal_to: 0)
    |> validate_number(:synthetic_load_process_cap, greater_than_or_equal_to: 0)
    |> validate_number(:mix_scheduler_cap, greater_than: 0)
    |> update_change(:max_concurrent_agents_by_state, &AgentValidation.normalize_state_limits/1)
    |> AgentValidation.validate_state_limits(:max_concurrent_agents_by_state)
    |> update_change(:routing, &AgentValidation.normalize_agent_routing/1)
    |> AgentValidation.validate_agent_routing(:routing)
    |> validate_dispatch_selections()
    |> AgentValidation.validate_agent_priority(:priority)
    |> validate_change(:switch_model_on_ratelimit, fn :switch_model_on_ratelimit, backends ->
      known = Aiur.CodingAgent.known_backends()

      cond do
        backends != Enum.uniq(backends) -> [switch_model_on_ratelimit: "must not contain duplicate backends"]
        Enum.all?(backends, &(&1 in known)) -> []
        true -> [switch_model_on_ratelimit: "contains an unknown backend; known backends: #{inspect(known)}"]
      end
    end)
    |> validate_change(:rate_limit_primary, fn :rate_limit_primary, backend ->
      known = Aiur.CodingAgent.known_backends()

      if backend in known,
        do: [],
        else: [rate_limit_primary: "must be a registered backend; known backends: #{inspect(known)}"]
    end)
    |> validate_rate_limit_fallback()
    |> update_change(:complexity_prompts, &AgentValidation.normalize_complexity_prompts/1)
    |> AgentValidation.validate_complexity_prompts(:complexity_prompts)
    |> update_change(:max_turns_by_complexity, &AgentValidation.normalize_max_turns_by_complexity/1)
    |> AgentValidation.validate_max_turns_by_complexity(:max_turns_by_complexity)
    |> cast_embed(:claude, with: &Claude.changeset/2)
    |> cast_embed(:codex, with: &Codex.changeset/2)
    |> cast_embed(:pricing_policy, with: &PricingPolicy.changeset/2)
  end

  defp validate_dispatch_selections(changeset) do
    dispatchable = dispatchable_with_priority(changeset)

    changeset
    |> reject_disabled_backend(:kind, Ecto.Changeset.get_field(changeset, :kind), dispatchable)
    |> reject_disabled_backends(:switch_model_on_ratelimit, Ecto.Changeset.get_field(changeset, :switch_model_on_ratelimit), dispatchable)
    |> reject_disabled_backend(:rate_limit_primary, Ecto.Changeset.get_field(changeset, :rate_limit_primary), dispatchable)
    |> reject_disabled_backend(:rate_limit_fallback, Ecto.Changeset.get_field(changeset, :rate_limit_fallback), dispatchable)
  end

  defp dispatchable_with_priority(changeset) do
    priority =
      (Ecto.Changeset.get_field(changeset, :priority) || [])
      |> Enum.map(&RoutingValue.routing_backend/1)
      |> Enum.reject(&is_nil/1)

    base = Aiur.CodingAgent.dispatchable_backends(Ecto.Changeset.get_field(changeset, :backend_configs) || %{})
    Enum.uniq(priority ++ base)
  end

  defp reject_disabled_backends(changeset, field, values, dispatchable) when is_list(values) do
    case Enum.find(values, &(&1 not in dispatchable)) do
      nil -> changeset
      backend -> Ecto.Changeset.add_error(changeset, field, "backend #{inspect(backend)} is disabled; dispatchable backends: #{inspect(dispatchable)}")
    end
  end

  defp reject_disabled_backends(changeset, _field, _values, _dispatchable), do: changeset

  defp reject_disabled_backend(changeset, _field, backend, _dispatchable) when backend in [nil, ""], do: changeset

  defp reject_disabled_backend(changeset, field, backend, dispatchable) do
    if backend in Aiur.CodingAgent.known_backends() and backend not in dispatchable do
      Ecto.Changeset.add_error(changeset, field, "backend #{inspect(backend)} is disabled; set agent.backend_configs.#{backend}.enabled: true to opt in")
    else
      changeset
    end
  end

  # The fallback names a registered backend distinct from the primary, or "" to
  # disable the reroute. Cross-field (fallback != primary), so it reads the
  # changeset rather than living in a `validate_change` closure.
  defp validate_rate_limit_fallback(changeset) do
    backend = Ecto.Changeset.get_field(changeset, :rate_limit_fallback)
    primary = Ecto.Changeset.get_field(changeset, :rate_limit_primary)
    known = Aiur.CodingAgent.known_backends()
    fallback_targets = Aiur.CodingAgent.rate_limit_fallback_targets()

    cond do
      backend in [nil, ""] ->
        changeset

      backend not in known ->
        Ecto.Changeset.add_error(changeset, :rate_limit_fallback, "must be a registered backend or \"\" to disable; known backends: #{inspect(known)}")

      backend == primary ->
        Ecto.Changeset.add_error(changeset, :rate_limit_fallback, "must differ from rate_limit_primary (#{inspect(primary)})")

      backend not in fallback_targets ->
        Ecto.Changeset.add_error(changeset, :rate_limit_fallback, "must be an eligible registered fallback backend; eligible backends: #{inspect(fallback_targets)}")

      true ->
        changeset
    end
  end

  # A `max_turns` of `none`/`unlimited`/`""` means uncapped — drop the key so
  # the field stays nil instead of failing integer casting.
  defp drop_uncapped_max_turns(attrs) do
    Enum.reduce([:max_turns, "max_turns"], attrs, &drop_key_if_uncapped/2)
  end

  defp default_mix_scheduler_cap(attrs) do
    if Map.has_key?(attrs, :mix_scheduler_cap) or Map.has_key?(attrs, "mix_scheduler_cap") do
      attrs
    else
      key = if Enum.any?(Map.keys(attrs), &is_atom/1), do: :mix_scheduler_cap, else: "mix_scheduler_cap"
      Map.put(attrs, key, 4)
    end
  end

  defp drop_key_if_uncapped(key, attrs) do
    case Map.fetch(attrs, key) do
      {:ok, value} when is_binary(value) ->
        if uncapped_max_turns?(value), do: Map.delete(attrs, key), else: attrs

      _ ->
        attrs
    end
  end

  defp uncapped_max_turns?(value) do
    String.downcase(String.trim(value)) in ["none", "unlimited", ""]
  end
end
