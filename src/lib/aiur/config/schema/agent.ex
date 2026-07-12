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

  alias Aiur.Config.Schema.{AgentValidation, Claude, Codex}

  @primary_key false
  embedded_schema do
    field(:kind, :string, default: "codex")
    # Setting #2 (RC opt-in), orthogonal to :kind. Only consulted when the
    # resolved backend is RC-capable. This default is the single flip point
    # for always-remote: change `false` here and every dispatch attaches RC.
    field(:remote_control, :boolean, default: false)
    field(:max_concurrent_agents, :integer, default: 10)
    # Fleet-wide cap for agent-launched `mix compile` / `mix test` commands.
    # 0 deliberately disables the gate for operators who need unrestricted
    # local verification.
    field(:max_concurrent_builds, :integer, default: 2)
    # Minimum spacing between local Mix compile/test starts when more than one
    # build may run concurrently. 0 disables start pacing.
    field(:build_start_stagger_seconds, :integer, default: 0)
    # Optional Linux MemAvailable floor shared by normal dispatch and the local
    # Mix build gate. Omitted means memory admission is disabled.
    field(:min_free_memory_mb, :integer)
    # nil = uncapped (no per-issue turn limit). A YAML value of `none` /
    # `unlimited` (or an absent key) resolves to nil; any present number must
    # be > 0.
    field(:max_turns, :integer)
    field(:max_retry_attempts, :integer, default: 3)
    field(:max_retry_backoff_ms, :integer, default: 300_000)
    field(:max_concurrent_agents_by_state, :map, default: %{})
    field(:routing, :map, default: %{})
    field(:switch_model_on_ratelimit, {:array, :string}, default: [])
    field(:complexity_prompts, :map, default: %{})
    # Backend-agnostic turn/stall timeouts (promoted from codex; claude-repl
    # already reads these via Config.agent_turn_timeout_ms/0).
    field(:turn_timeout_ms, :integer, default: 3_600_000)
    field(:stall_timeout_ms, :integer, default: 3_600_000)
    # Safety checkpoint: pause an agent that has been actively running this
    # many minutes (paused/blocked time excluded). 0 disables it.
    field(:max_agent_duration_minutes, :integer, default: 60)
    # Per-scheduler 1-min load ceiling for the dispatch load gate (#465).
    # Enabled by default so high-concurrency runs have protection without
    # extra operator knowledge; explicit YAML null disables it.
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

    embeds_one(:claude, Claude, on_replace: :update, defaults_to_struct: true)
    embeds_one(:codex, Codex, on_replace: :update, defaults_to_struct: true)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(
      attrs |> drop_uncapped_max_turns() |> default_mix_scheduler_cap(),
      [
        :kind,
        :remote_control,
        :max_concurrent_agents,
        :max_concurrent_builds,
        :build_start_stagger_seconds,
        :min_free_memory_mb,
        :max_turns,
        :max_retry_attempts,
        :max_retry_backoff_ms,
        :max_concurrent_agents_by_state,
        :routing,
        :switch_model_on_ratelimit,
        :complexity_prompts,
        :turn_timeout_ms,
        :stall_timeout_ms,
        :max_agent_duration_minutes,
        :max_load_average,
        :target_load_average,
        :load_ramp_step,
        :load_cooldown_seconds,
        :synthetic_load_process_cap,
        :mix_scheduler_cap
      ],
      empty_values: []
    )
    |> validate_number(:max_concurrent_agents, greater_than: 0)
    |> validate_number(:max_concurrent_builds, greater_than_or_equal_to: 0)
    |> validate_number(:build_start_stagger_seconds, greater_than_or_equal_to: 0)
    |> validate_number(:min_free_memory_mb, greater_than: 0)
    |> validate_number(:max_turns, greater_than: 0)
    |> validate_number(:max_retry_attempts, greater_than: 0)
    |> validate_number(:max_retry_backoff_ms, greater_than: 0)
    |> validate_number(:turn_timeout_ms, greater_than: 0)
    |> validate_number(:stall_timeout_ms, greater_than_or_equal_to: 0)
    |> validate_number(:max_agent_duration_minutes, greater_than_or_equal_to: 0)
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
    |> validate_change(:switch_model_on_ratelimit, fn :switch_model_on_ratelimit, backends ->
      known = Aiur.CodingAgent.known_backends()

      cond do
        backends != Enum.uniq(backends) -> [switch_model_on_ratelimit: "must not contain duplicate backends"]
        Enum.all?(backends, &(&1 in known)) -> []
        true -> [switch_model_on_ratelimit: "contains an unknown backend; known backends: #{inspect(known)}"]
      end
    end)
    |> update_change(:complexity_prompts, &AgentValidation.normalize_complexity_prompts/1)
    |> AgentValidation.validate_complexity_prompts(:complexity_prompts)
    |> cast_embed(:claude, with: &Claude.changeset/2)
    |> cast_embed(:codex, with: &Codex.changeset/2)
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
