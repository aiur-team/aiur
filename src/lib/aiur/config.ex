defmodule Aiur.Config do
  @moduledoc """
  Runtime configuration loaded from the aiur config file (`.aiur/config`).
  """

  alias Aiur.Config.{Schema, SemanticChecks}
  alias Aiur.Config.Schema.EnvResolver
  alias Aiur.Workflow
  alias Aiur.WorkflowStore.Cache, as: WorkflowStoreCache

  # Every environment variable config preparation or `Schema.parse/1` can read
  # that is *not* named by the config itself. The workspace-root default is
  # `System.tmp_dir!/0`, which reads TMPDIR/TEMP/TMP before its non-environment
  # fallbacks. Anything added to those paths must be added here, or the settings
  # memo will not expire when the variable changes.
  @implicit_env_vars ~w(LINEAR_API_KEY LINEAR_ASSIGNEE ELEVENLABS_API_KEY AIUR_DEFAULT_DASHBOARD_HOST TMPDIR TEMP TMP)

  @type codex_runtime_settings :: %{
          approval_policy: String.t(),
          thread_sandbox: String.t(),
          turn_sandbox_policy: map()
        }

  @doc """
  The parsed config.

  This is the single most-called read in the system, so it must be cheap and it
  must not serialize. Two things make it so (#1731):

    * `Workflow.current_with_cache_identity/0` is an ETS lookup, not a
      `GenServer.call` into `Aiur.WorkflowStore`.
    * the `Schema.parse/1` result is memoized against the store generation and
      collision-free publication reference, plus the environment epoch, so the
      schema work happens once per *config or environment change* rather than
      once per read. Before this, every caller re-prepared and re-parsed the
      same map.
  """
  @spec settings() :: {:ok, Schema.t()} | {:error, term()}
  def settings do
    case Workflow.current_with_cache_identity() do
      {:ok, workflow, generation, publication} when is_integer(generation) and is_reference(publication) ->
        cached_settings(workflow, {generation, publication})

      {:ok, workflow, _unknown_generation, _unknown_publication} ->
        settings_from({:ok, workflow})

      {:error, reason} ->
        {:error, reason}
    end
  end

  # `Schema.parse/1` is not a pure function of the config map: `$ENV` references,
  # `LINEAR_API_KEY`/`LINEAR_ASSIGNEE` and the workspace-root default all read
  # the process environment at parse time. Keying the memo on the config
  # generation alone would freeze a resolved secret for the life of the config —
  # and would break every test that sets an env var and re-reads settings. So
  # the key carries a collision-free publication reference and an environment
  # epoch as well; a
  # `System.put_env` to any variable the parse depends on invalidates the memo
  # exactly like a config edit does. The publication reference prevents a late
  # reader from republishing settings for older content if a generation is
  # reused, without copying the full config term on this hot path. See
  # `env_epoch/2` for why that is not the whole environment.
  defp cached_settings(workflow, cache_identity) do
    key = {cache_identity, env_epoch(workflow, cache_identity)}

    case WorkflowStoreCache.fetch_settings(key) do
      {:ok, settings} ->
        {:ok, settings}

      :error ->
        case settings_from({:ok, workflow}) do
          {:ok, settings} = result ->
            WorkflowStoreCache.put_settings(key, settings)
            result

          error ->
            # Never memoize a parse failure: the operator fixes the config in
            # place and the fix arrives as a new generation anyway, but a
            # cached error would also mask a transient read.
            error
        end
    end
  end

  # The memo must expire when any environment variable the parse depends on
  # changes, or a resolved secret freezes for the life of the config. Hashing
  # the *whole* environment does that, but it is not free: 154us per call on a
  # 226-variable host, against ~0.5us for the ETS lookup it guards. Since
  # `settings/0` is the most-called read in the system — a single status render
  # reaches it dozens of times — that made the env hash essentially 100% of the
  # remaining cost of this function.
  #
  # The variables the parse can actually consult are fixed by the config
  # content: the `$NAME` tokens the config itself references, plus the implicit
  # set above. So derive that list once per generation and sample only those.
  # The dependency set is a superset of what is really read (every `$NAME`
  # anywhere in the config, not just in fields that resolve one), so the key
  # can only expire too eagerly, never too late.
  defp env_epoch(workflow, cache_identity) do
    workflow
    |> env_names(cache_identity)
    |> Enum.map(&System.get_env/1)
    |> :erlang.phash2()
  end

  defp env_names(workflow, cache_identity) do
    case WorkflowStoreCache.fetch_env_names(cache_identity) do
      {:ok, names} ->
        names

      :error ->
        names = referenced_env_names(workflow)
        WorkflowStoreCache.put_env_names(cache_identity, names)
        names
    end
  end

  defp referenced_env_names(%{config: config}) when is_map(config) do
    @implicit_env_vars
    |> MapSet.new()
    |> collect_env_names(config)
    |> Enum.sort()
  end

  defp collect_env_names(acc, value) when is_map(value) and not is_struct(value) do
    Enum.reduce(value, acc, fn {key, nested}, acc ->
      acc |> collect_env_names(key) |> collect_env_names(nested)
    end)
  end

  defp collect_env_names(acc, value) when is_list(value) do
    Enum.reduce(value, acc, &collect_env_names(&2, &1))
  end

  defp collect_env_names(acc, value) when is_binary(value) do
    case EnvResolver.env_reference_name(value) do
      {:ok, name} -> MapSet.put(acc, name)
      :error -> acc
    end
  end

  defp collect_env_names(acc, _value), do: acc

  # Like `settings/0` but reads the config file directly, bypassing the
  # `WorkflowStore` cache. For callers that must see on-disk truth rather than a
  # possibly-stale cached config — notably `LogFile.apply_config_debug/0`, which
  # runs at boot before the cache exists and must stay deterministic under test.
  @spec settings_uncached() :: {:ok, Schema.t()} | {:error, term()}
  def settings_uncached, do: settings_from(Workflow.load())

  defp settings_from({:ok, %{config: config}}) when is_map(config) do
    config
    |> prepare_config()
    |> Schema.parse()
  end

  defp settings_from({:error, reason}), do: {:error, reason}

  @spec settings!() :: Schema.t()
  def settings! do
    case settings() do
      {:ok, settings} ->
        settings

      {:error, reason} ->
        raise ArgumentError, message: format_config_error(reason)
    end
  end

  defdelegate tracker_kind(), to: Aiur.Config.TrackerSettings
  defdelegate base_branch(source \\ settings(), context \\ []), to: Aiur.Config.TrackerSettings
  defdelegate active_states(), to: Aiur.Config.TrackerSettings
  defdelegate terminal_states(), to: Aiur.Config.TrackerSettings
  defdelegate terminal_fence_grace_seconds(), to: Aiur.Config.TrackerSettings
  defdelegate poll_interval_seconds(), to: Aiur.Config.TrackerSettings
  defdelegate poll_intervals(), to: Aiur.Config.TrackerSettings
  defdelegate view_state_sweep_seconds(), to: Aiur.Config.TrackerSettings
  defdelegate events_block_state_debounce_seconds(), to: Aiur.Config.TrackerSettings
  defdelegate events_custom_events_per_turn_max(), to: Aiur.Config.TrackerSettings
  defdelegate events_codeowners_refresh_seconds(), to: Aiur.Config.TrackerSettings
  defdelegate workspace_root(), to: Aiur.Config.TrackerSettings
  defdelegate workspace_bootstrap_image(), to: Aiur.Config.TrackerSettings
  defdelegate workspace_bootstrap_image_pull?(), to: Aiur.Config.TrackerSettings
  defdelegate max_vertical_panes(), to: Aiur.Config.TrackerSettings
  defdelegate max_log_history_mb(), to: Aiur.Config.TrackerSettings
  defdelegate workspace_hooks(), to: Aiur.Config.TrackerSettings
  defdelegate hook_timeout_ms(), to: Aiur.Config.TrackerSettings
  defdelegate elevenlabs_api_key(), to: Aiur.Config.ObservabilitySettings
  defdelegate elevenlabs_language_code(), to: Aiur.Config.ObservabilitySettings
  defdelegate elevenlabs_voice_id(), to: Aiur.Config.ObservabilitySettings
  defdelegate workflow_prompt(), to: Aiur.Config.ObservabilitySettings
  defdelegate server_port(), to: Aiur.Config.ObservabilitySettings
  defdelegate server_host(), to: Aiur.Config.ObservabilitySettings
  defdelegate server_tailscale_funnel?(), to: Aiur.Config.ObservabilitySettings
  defdelegate observability_enabled?(), to: Aiur.Config.ObservabilitySettings
  defdelegate telemetry_enabled?(settings \\ settings_uncached()), to: Aiur.Config.ObservabilitySettings
  defdelegate build_order_funnel_health_check_enabled?(settings \\ settings_uncached()), to: Aiur.Config.ObservabilitySettings
  defdelegate upgrade_check_enabled?(settings \\ settings_uncached()), to: Aiur.Config.ObservabilitySettings
  defdelegate dashboard_writable?(), to: Aiur.Config.ObservabilitySettings
  defdelegate supervisor_decision_policy(), to: Aiur.Config.ObservabilitySettings
  defdelegate observability_refresh_ms(), to: Aiur.Config.ObservabilitySettings
  defdelegate observability_render_interval_ms(), to: Aiur.Config.ObservabilitySettings
  defdelegate daemon_heartbeat_stale_ms(), to: Aiur.Config.ObservabilitySettings
  defdelegate telemetry_retention(), to: Aiur.Config.ObservabilitySettings
  defdelegate agent_priority(), to: Aiur.Config.AgentSettings
  defdelegate avoid_peak_pricing?(), to: Aiur.Config.AgentSettings
  defdelegate avoid_peak_pricing_value(settings), to: Aiur.Config.AgentSettings
  defdelegate agent_priority_backends(), to: Aiur.Config.AgentSettings
  defdelegate agent_kind(), to: Aiur.Config.AgentSettings
  defdelegate backend_config(backend), to: Aiur.Config.AgentSettings
  defdelegate agent_backend_configs(), to: Aiur.Config.AgentSettings
  defdelegate agent_routing(), to: Aiur.Config.AgentSettings
  defdelegate switch_model_on_ratelimit(), to: Aiur.Config.AgentSettings
  defdelegate rate_limit_fallback_backend(), to: Aiur.Config.AgentSettings
  defdelegate rate_limit_primary_backend(), to: Aiur.Config.AgentSettings
  defdelegate agent_remote_control?(), to: Aiur.Config.AgentSettings
  defdelegate agent_max_dispatches_per_ticket(), to: Aiur.Config.AgentSettings
  defdelegate agent_prior_work_continuation?(), to: Aiur.Config.AgentSettings
  defdelegate agent_complexity_prompts(), to: Aiur.Config.AgentSettings
  defdelegate agent_max_turns_by_complexity(), to: Aiur.Config.AgentSettings
  defdelegate alerts_settings(), to: Aiur.Config.AgentSettings
  defdelegate executor_takeover_first_alert_hours(), to: Aiur.Config.AgentSettings
  defdelegate executor_takeover_continuous_alert_hours(), to: Aiur.Config.AgentSettings
  defdelegate max_retry_attempts(), to: Aiur.Config.AgentSettings
  defdelegate max_retry_backoff_ms(), to: Aiur.Config.AgentSettings
  defdelegate codex_thrash_max_per_window(), to: Aiur.Config.AgentSettings
  defdelegate codex_thrash_window_seconds(), to: Aiur.Config.AgentSettings
  defdelegate agent_max_turns(), to: Aiur.Config.AgentSettings
  defdelegate agent_max_consecutive_noop_turns(), to: Aiur.Config.AgentSettings
  defdelegate agent_turn_timeout_ms(), to: Aiur.Config.AgentSettings
  defdelegate agent_read_timeout_ms(), to: Aiur.Config.AgentSettings
  defdelegate agent_stall_timeout_ms(), to: Aiur.Config.AgentSettings
  defdelegate max_agent_duration_minutes(), to: Aiur.Config.AgentSettings
  defdelegate ci_wait_rewake_minutes(), to: Aiur.Config.AgentSettings
  defdelegate max_concurrent_agents_for_state(state_name), to: Aiur.Config.CapacitySettings
  defdelegate usage_ledger_durability_timeout(), to: Aiur.Config.CapacitySettings
  defdelegate max_concurrent_agents(), to: Aiur.Config.CapacitySettings
  defdelegate default_max_concurrent_agents(schedulers \\ System.schedulers_online()), to: Aiur.Config.CapacitySettings
  defdelegate run_queue_threshold(), to: Aiur.Config.CapacitySettings
  defdelegate max_concurrent_builds(), to: Aiur.Config.CapacitySettings
  defdelegate build_start_stagger_seconds(), to: Aiur.Config.CapacitySettings
  defdelegate min_free_memory_mb(), to: Aiur.Config.CapacitySettings
  defdelegate build_gate_max_hold_seconds(), to: Aiur.Config.CapacitySettings
  defdelegate build_gate_retain_seconds(), to: Aiur.Config.CapacitySettings
  defdelegate mix_scheduler_cap(), to: Aiur.Config.CapacitySettings
  defdelegate saturation_log_enabled?(), to: Aiur.Config.CapacitySettings
  defdelegate pre_warmed_sessions(), to: Aiur.Config.CapacitySettings
  defdelegate prewarm_enabled?(), to: Aiur.Config.CapacitySettings
  defdelegate prewarm_base_build(), to: Aiur.Config.CapacitySettings
  defdelegate prewarm_poll_seconds(), to: Aiur.Config.CapacitySettings
  defdelegate synthetic_load_process_cap(), to: Aiur.Config.CapacitySettings
  defdelegate default_synthetic_load_process_cap(schedulers \\ System.schedulers_online()), to: Aiur.Config.CapacitySettings
  defdelegate max_cpu_pressure(), to: Aiur.Config.CapacitySettings
  defdelegate target_cpu_pressure(), to: Aiur.Config.CapacitySettings
  defdelegate max_load_average(), to: Aiur.Config.CapacitySettings
  defdelegate target_load_average(), to: Aiur.Config.CapacitySettings
  defdelegate load_ramp_step(), to: Aiur.Config.CapacitySettings
  defdelegate load_resume_max_age_seconds(), to: Aiur.Config.CapacitySettings
  defdelegate load_cooldown_seconds(), to: Aiur.Config.CapacitySettings
  defdelegate capacity_starvation_alert_after_seconds(), to: Aiur.Config.CapacitySettings
  defdelegate budget_broker_rate_window_seconds(), to: Aiur.Config.CapacitySettings
  defdelegate budget_broker_degraded_retry_threshold(), to: Aiur.Config.CapacitySettings
  defdelegate budget_broker_degraded_alert_after_seconds(), to: Aiur.Config.CapacitySettings
  defdelegate codex_reset_time_zone(), to: Aiur.Config.CodexRuntime
  defdelegate codex_reset_min_delay_seconds(), to: Aiur.Config.CodexRuntime
  defdelegate codex_turn_sandbox_policy(workspace \\ nil), to: Aiur.Config.CodexRuntime
  defdelegate codex_runtime_settings(workspace \\ nil, opts \\ []), to: Aiur.Config.CodexRuntime

  @spec validate!() :: :ok | {:error, term()}
  def validate! do
    with {:ok, settings} <- settings() do
      SemanticChecks.validate(settings)
    end
  end

  defp prepare_config(config) do
    tracker = map_section(config, "tracker")
    agent = map_section(config, "agent")
    linear = map_section(config, "linear")
    server = map_section(config, "server")

    config
    |> Map.put("tracker", prepare_tracker_config(config, tracker, linear))
    |> Map.put("agent", prepare_agent_config(config, agent))
    |> Map.put("server", prepare_server_config(server))
  end

  defp prepare_server_config(server) do
    if has_section?(server, "host") do
      server
    else
      Map.put(server, "host", default_server_host())
    end
  end

  defp default_server_host do
    case System.get_env("AIUR_DEFAULT_DASHBOARD_HOST") do
      host when is_binary(host) and host != "" -> host
      _ -> "127.0.0.1"
    end
  end

  defp prepare_tracker_config(config, tracker, linear) do
    tracker
    |> Map.merge(linear, fn _key, tracker_value, _linear_value -> tracker_value end)
    |> put_default_kind(inferred_tracker_kind(config))
  end

  defp prepare_agent_config(config, agent) do
    agent
    |> Map.put("backend_configs", backend_config_sections(config, agent))
    |> put_default_kind(inferred_agent_kind(config))
  end

  defp put_default_kind(section, kind) do
    case Map.get(section, "kind") || Map.get(section, :kind) do
      nil -> Map.put(section, "kind", kind)
      _ -> section
    end
  end

  defp inferred_tracker_kind(config) do
    cond do
      has_section?(config, "github") -> "github"
      has_section?(config, "linear") -> "linear"
      has_section?(config, "memory") -> "memory"
      true -> nil
    end
  end

  defp inferred_agent_kind(config) do
    agent = map_section(config, "agent")

    Enum.find(Aiur.CodingAgent.configurable_backends(), fn backend ->
      has_section?(config, backend) or Map.has_key?(backend_config_sections(config, agent), backend)
    end) || Aiur.CodingAgent.default_config_backend()
  end

  defp backend_config_sections(config, agent) do
    explicit = map_section(agent, "backend_configs")

    Aiur.CodingAgent.known_backends()
    |> Enum.reduce(explicit, fn backend, sections ->
      section =
        config
        |> map_section(backend)
        |> Map.merge(map_section(agent, backend))
        |> Map.merge(map_section(explicit, backend))

      if map_size(section) > 0, do: Map.put(sections, backend, section), else: sections
    end)
  end

  defp has_section?(config, name) do
    Map.has_key?(config, name) or Map.has_key?(config, String.to_atom(name))
  end

  defp map_section(config, name) do
    case Map.get(config, name) || Map.get(config, String.to_atom(name)) do
      section when is_map(section) -> section
      _ -> %{}
    end
  end

  defp format_config_error(reason) do
    label = config_file_label()

    case reason do
      {:invalid_workflow_config, message} ->
        "Invalid #{label} config: #{message}"

      {:missing_workflow_file, path, raw_reason} ->
        "Missing #{Path.basename(path)} at #{path}: #{inspect(raw_reason)}. Run `aiur init` to scaffold a .aiur/config."

      {tag, path, raw_reason}
      when tag in [:missing_prompt_file, :missing_hooks_file, :missing_prewarm_file] ->
        "Missing #{missing_file_label(tag)} at #{path}: #{inspect(raw_reason)}"

      {:invalid_hooks_file, path, raw_reason} ->
        "Invalid hooks_file at #{path}: #{inspect(raw_reason)}"

      {:workflow_parse_error, raw_reason} ->
        "Failed to parse #{label}: #{inspect(raw_reason)}"

      :workflow_front_matter_not_a_map ->
        "Failed to parse #{label}: top-level YAML must be a map"

      other ->
        "Invalid #{label} config: #{inspect(other)}"
    end
  end

  defp missing_file_label(:missing_prompt_file), do: "prompt_file"
  defp missing_file_label(:missing_hooks_file), do: "hooks_file"
  defp missing_file_label(:missing_prewarm_file), do: "prewarm base_build_file"

  defp config_file_label do
    Path.basename(Workflow.workflow_file_path())
  end
end
