defmodule Aiur.Config do
  @moduledoc """
  Runtime configuration loaded from the aiur config file (`.aiur/config`).
  """

  alias Aiur.AgentEnvironment
  alias Aiur.BuildGate
  alias Aiur.BuildOrder.Cadence
  alias Aiur.Config.RoutingValue
  alias Aiur.Config.Schema
  alias Aiur.Config.Schema.AgentValidation
  alias Aiur.Config.Schema.EnvResolver
  alias Aiur.GitHub.Budget
  alias Aiur.Workflow
  alias Aiur.WorkflowStore.Cache, as: WorkflowStoreCache

  # Every environment variable config preparation or `Schema.parse/1` can read
  # that is *not* named by the config itself. The workspace-root default is
  # `System.tmp_dir!/0`, which reads TMPDIR/TEMP/TMP before its non-environment
  # fallbacks. Anything added to those paths must be added here, or the settings
  # memo will not expire when the variable changes.
  @implicit_env_vars ~w(LINEAR_API_KEY LINEAR_ASSIGNEE ELEVENLABS_API_KEY AIUR_DEFAULT_DASHBOARD_HOST TMPDIR TEMP TMP)

  @default_prompt_template """
  You are working on a Linear issue.

  Identifier: {{ issue.identifier }}
  Title: {{ issue.title }}

  Body:
  {% if issue.description %}
  {{ issue.description }}
  {% else %}
  No description provided.
  {% endif %}
  """

  @default_telemetry_retention_max_bytes 64 * 1024 * 1024
  @default_telemetry_retention_max_age_days 30
  @minimum_telemetry_retention_prune_interval_bytes 1 * 1024 * 1024

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

  @spec max_concurrent_agents_for_state(term()) :: pos_integer()
  def max_concurrent_agents_for_state(state_name) when is_binary(state_name) do
    config = settings!()

    Map.get(
      config.agent.max_concurrent_agents_by_state,
      AgentValidation.normalize_issue_state(state_name),
      max_concurrent_agents()
    )
  end

  def max_concurrent_agents_for_state(_state_name), do: max_concurrent_agents()

  @spec tracker_kind() :: String.t() | nil
  def tracker_kind do
    settings!().tracker.kind
  end

  @doc "The configured tracker integration branch. Raises when it cannot be resolved safely."
  @spec base_branch() :: String.t()
  @spec base_branch(term()) :: String.t()
  @spec base_branch(term(), keyword()) :: String.t()
  def base_branch(source \\ settings(), context \\ [])

  def base_branch({:ok, %{tracker: tracker}}, context), do: base_branch(tracker, context)

  def base_branch({:error, reason}, context) do
    raise_unresolved_base_branch({:config_error, reason}, context)
  end

  def base_branch(opts, context) when is_list(opts) do
    case Keyword.fetch(opts, :base_branch) do
      {:ok, branch} -> require_base_branch(branch, context)
      :error -> base_branch(settings(), context)
    end
  end

  def base_branch(%{tracker: tracker}, context), do: base_branch(tracker, context)
  def base_branch(%{"tracker" => tracker}, context), do: base_branch(tracker, context)
  def base_branch(%{base_branch: branch}, context), do: require_base_branch(branch, context)
  def base_branch(%{"base_branch" => branch}, context), do: require_base_branch(branch, context)
  def base_branch(%{}, context), do: raise_unresolved_base_branch(:missing, context)
  def base_branch(source, context), do: raise_unresolved_base_branch({:invalid_source, source}, context)

  defp require_base_branch(branch, context) when is_binary(branch) and byte_size(branch) > 0 do
    case String.trim(branch) do
      "" -> raise_unresolved_base_branch(:empty, context)
      trimmed -> trimmed
    end
  end

  defp require_base_branch(branch, context), do: raise_unresolved_base_branch({:invalid, branch}, context)

  defp raise_unresolved_base_branch(reason, context) do
    cwd = context |> Keyword.get_lazy(:cwd, &File.cwd!/0) |> Path.expand()

    config_path =
      context
      |> Keyword.get_lazy(:config_path, &Workflow.workflow_file_path/0)
      |> Path.expand(cwd)

    raise ArgumentError,
          "tracker.base_branch could not be resolved; config path searched: #{config_path}; " <>
            "resolved working directory: #{cwd}; reason: #{inspect(reason)}"
  end

  @doc """
  Ordered dispatch preference, as **routes** — each entry is a
  `Aiur.Config.RoutingValue` (`backend[:model[:effort]][+remote]`), so
  `"openrouter:anthropic/claude-sonnet-5"` and a bare `"claude"` are both
  valid members and one model reachable two ways may appear twice. Empty means
  the deprecated `agent.kind`/`agent.switch_model_on_ratelimit` fields apply.

  Callers that need only the backend must map through
  `agent_priority_backends/0` (or `RoutingValue.routing_backend/1`); anything
  comparing a member against `known_backends()` directly will silently drop
  every route that names a model.
  """
  @spec agent_priority() :: [String.t()]
  def agent_priority, do: settings!().agent.priority || []

  @doc """
  Whether dispatch should route away from a route that is currently inside a
  provider's peak-pricing window, falling through to the next `agent.priority`
  entry. Defaults to `true`.

  Shape only for now — #1456 implements the behaviour. `false` means "ignore
  pricing windows entirely and use `agent.priority` exactly as written"; it
  never changes how spend is *reported*. See
  `Aiur.Config.Schema.PricingPolicy`.
  """
  @spec avoid_peak_pricing?() :: boolean()
  def avoid_peak_pricing? do
    case settings!().agent.pricing_policy do
      %{avoid_peak_pricing: value} when is_boolean(value) -> value
      _ -> true
    end
  end

  @doc "The backends named by `agent_priority/0`, in order, with the model segment stripped and duplicates collapsed."
  @spec agent_priority_backends() :: [String.t()]
  def agent_priority_backends do
    agent_priority() |> Enum.map(&RoutingValue.routing_backend/1) |> Enum.reject(&is_nil/1) |> Enum.uniq()
  end

  @doc "Default backend: the backend of the first `agent.priority` route when present, else the deprecated `agent.kind` field."
  @spec agent_kind() :: String.t()
  def agent_kind do
    case agent_priority_backends() do
      [primary | _] -> primary
      [] -> settings!().agent.kind || Aiur.CodingAgent.default_backend()
    end
  end

  @doc """
  ElevenLabs speech-to-text credential for Stream Deck voice input, or `nil` when
  unconfigured. Resolved from `elevenlabs.api_key` (which may be a
  `$ELEVENLABS_API_KEY` reference) with the `ELEVENLABS_API_KEY` env var as the
  fallback. It is a secret: never log the returned value.
  """
  @spec elevenlabs_api_key() :: String.t() | nil
  def elevenlabs_api_key, do: settings!().elevenlabs.api_key

  @doc "ISO-639-3 transcription language for Stream Deck voice input."
  @spec elevenlabs_language_code() :: String.t()
  def elevenlabs_language_code, do: settings!().elevenlabs.language_code || "eng"

  @doc "ElevenLabs voice used for dashboard interactive conversation replies."
  @spec elevenlabs_voice_id() :: String.t() | nil
  def elevenlabs_voice_id do
    case settings!().elevenlabs.voice_id do
      voice_id when is_binary(voice_id) -> if String.trim(voice_id) == "", do: nil, else: voice_id
      _absent -> nil
    end
  end

  @doc "Raw settings for a registry-named backend, or an empty map when absent."
  @spec backend_config(String.t()) :: map()
  def backend_config(backend) when is_binary(backend) do
    agent_backend_configs()
    |> Map.get(backend, %{})
  end

  @doc """
  Raw settings for all registry-named backends, with the backend of each
  `agent.priority` route marked enabled so naming a route makes its backend
  dispatchable. Keyed by backend, never by route: several routes may share one
  backend (`openrouter:a` and `openrouter:b`) and they configure one transport.
  """
  @spec agent_backend_configs() :: map()
  def agent_backend_configs do
    Enum.reduce(agent_priority_backends(), settings!().agent.backend_configs || %{}, fn backend, acc ->
      Map.update(acc, backend, %{"enabled" => true}, &Map.put(&1, "enabled", true))
    end)
  end

  @spec agent_routing() :: %{pos_integer() => String.t()}
  def agent_routing do
    settings!().agent.routing || %{}
  end

  @doc """
  Claim-time fallback order: `agent.priority` when present, else the deprecated
  `agent.switch_model_on_ratelimit` field. Returns **routes**, not backends —
  selection consumes the model segment, so stripping it here would collapse
  `[claude, "openrouter:anthropic/claude-sonnet-5"]` into one candidate and
  erase the fallback the operator wrote.
  """
  @spec switch_model_on_ratelimit() :: [String.t()]
  def switch_model_on_ratelimit do
    case agent_priority() do
      [] -> settings!().agent.switch_model_on_ratelimit || []
      priority -> priority
    end
  end

  @doc """
  The registered backend the automatic usage-limit fallback reroutes *to*
  (`Aiur.Orchestrator.RateLimitFallback`) when an already-running agent on
  `rate_limit_primary_backend/0` hits `usage_limit_exhausted`, or `nil` when
  disabled. When `agent.priority` is set, this is the first eligible fallback
  target after the primary; otherwise it reads the deprecated
  `agent.rate_limit_fallback` field (`""` disables).
  """
  @spec rate_limit_fallback_backend() :: String.t() | nil
  def rate_limit_fallback_backend do
    case agent_priority_backends() do
      [_primary | rest] -> Enum.find(rest, &(&1 in Aiur.CodingAgent.rate_limit_fallback_targets()))
      [] -> legacy_rate_limit_fallback()
    end
  end

  defp legacy_rate_limit_fallback do
    case settings!().agent.rate_limit_fallback do
      backend when is_binary(backend) and backend != "" -> backend
      _ -> nil
    end
  end

  @doc """
  The registered backend the usage-limit fallback reroutes *from* — the pair's
  primary. Only an already-running agent on this backend that hits
  `usage_limit_exhausted` is eligible for the reroute to
  `rate_limit_fallback_backend/0`. When `agent.priority` is set this is its
  first entry; otherwise it reads the deprecated `agent.rate_limit_primary`.
  """
  @spec rate_limit_primary_backend() :: String.t()
  def rate_limit_primary_backend do
    case agent_priority_backends() do
      [primary | _] -> primary
      [] -> settings!().agent.rate_limit_primary
    end
  end

  @doc """
  Setting #2: whether dispatched agents attach a `claude remote-control`
  session. Orthogonal to `agent_kind/0` and only meaningful for an
  RC-capable backend. The default lives in `Config.Schema` so flipping to
  always-remote is a one-line change there.
  """
  @spec agent_remote_control?() :: boolean()
  def agent_remote_control? do
    settings!().agent.remote_control || false
  end

  @doc """
  Lifetime cap on (re)dispatches for a single ticket, or 0 when disabled.
  """
  @spec agent_max_dispatches_per_ticket() :: non_neg_integer()
  def agent_max_dispatches_per_ticket do
    case settings() do
      {:ok, settings} -> Map.get(settings.agent, :max_dispatches_per_ticket) || 0
      _ -> 0
    end
  end

  @doc """
  Whether a recycled re-dispatch that could not resume its thread gets
  continuation guidance instead of the cold-start prompt. Defaults to true so
  a non-resumable backend switch picks up the shared workspace without claiming
  cross-backend conversation continuity.
  """
  @spec agent_prior_work_continuation?() :: boolean()
  def agent_prior_work_continuation? do
    case settings() do
      # Map.get, not dot access, so a config cached before this field existed
      # uses the current default rather than raising after a schema upgrade.
      {:ok, settings} -> Map.get(settings.agent, :prior_work_continuation, true)
      _ -> true
    end
  end

  @doc """
  Per-complexity-level guidance strings, keyed by complexity level.
  Appended to the end of the rendered prompt for an issue carrying the
  matching `complexity:<n>` label. Returns `%{}` when unset or the config
  cannot be loaded, so prompt building never fails on this lookup.
  """
  @spec agent_complexity_prompts() :: %{pos_integer() => String.t()}
  def agent_complexity_prompts do
    case settings() do
      {:ok, settings} -> settings.agent.complexity_prompts || %{}
      _ -> %{}
    end
  end

  @doc """
  Per-complexity turn-cap map, keyed by complexity level. `%{}` when unset.
  """
  @spec agent_max_turns_by_complexity() :: %{pos_integer() => pos_integer()}
  def agent_max_turns_by_complexity do
    case settings() do
      # Map.get (not dot access) so a config cached before this field existed
      # returns %{} rather than raising KeyError after a schema upgrade.
      {:ok, settings} -> Map.get(settings.agent, :max_turns_by_complexity) || %{}
      _ -> %{}
    end
  end

  @doc """
  Effective turn cap for an issue: the `agent.max_turns_by_complexity` entry for
  the issue's `complexity:N` level when present, otherwise the flat
  `agent.max_turns`.
  """
  @spec agent_max_turns_for(Aiur.Issue.t()) :: pos_integer() | nil
  def agent_max_turns_for(%Aiur.Issue{} = issue) do
    with level when is_integer(level) <- Aiur.CodingAgent.complexity_level(issue),
         cap when is_integer(cap) <- Map.get(agent_max_turns_by_complexity(), level) do
      cap
    else
      _ -> agent_max_turns()
    end
  end

  @spec active_states() :: [String.t()]
  def active_states do
    settings!().tracker.active_states
  end

  @spec terminal_states() :: [String.t()]
  def terminal_states do
    settings!().tracker.terminal_states
  end

  @doc """
  How long a terminal tracker observation stays lifecycle-fenced while a queued
  authoritative item is undelivered before the daemon finalizes the running
  entry. Defaults to 30 seconds; raise it when provider turn-delivery latency is
  longer (a queued authoritative input that lands after the grace expires is
  dropped at teardown).
  """
  @spec terminal_fence_grace_seconds() :: pos_integer()
  def terminal_fence_grace_seconds do
    settings!().tracker.terminal_fence_grace_seconds
  end

  @spec poll_interval_seconds() :: pos_integer()
  def poll_interval_seconds do
    settings!().polling.interval_seconds
  end

  @doc """
  How often the single view-state reconciliation sweep runs.

  A recovery bound for lost webhook deliveries, not a freshness knob. See
  `Aiur.GitHub.ViewStateSweep`.
  """
  @spec view_state_sweep_seconds() :: pos_integer()
  def view_state_sweep_seconds do
    settings!().polling.view_state_sweep_seconds
  end

  @spec events_block_state_debounce_seconds() :: non_neg_integer()
  def events_block_state_debounce_seconds do
    settings!().events.block_state_debounce_seconds
  end

  @spec events_custom_events_per_turn_max() :: pos_integer()
  def events_custom_events_per_turn_max do
    settings!().events.custom_events_per_turn_max
  end

  @spec events_codeowners_refresh_seconds() :: pos_integer()
  def events_codeowners_refresh_seconds do
    settings!().events.codeowners_refresh_seconds
  end

  @spec workspace_root() :: Path.t()
  def workspace_root do
    settings!().workspace.root
  end

  @doc "Optional Docker image used to seed warm build artifacts into workspaces."
  @spec workspace_bootstrap_image() :: String.t() | nil
  def workspace_bootstrap_image do
    settings!().workspace.bootstrap_image
  end

  @doc "Whether aiur should pull the configured workspace bootstrap image before seeding."
  @spec workspace_bootstrap_image_pull?() :: boolean()
  def workspace_bootstrap_image_pull? do
    settings!().workspace.bootstrap_image_pull
  end

  @spec max_vertical_panes() :: pos_integer()
  def max_vertical_panes do
    settings!().max_vertical_panes
  end

  @spec max_log_history_mb() :: pos_integer()
  def max_log_history_mb do
    settings!().max_log_history_mb
  end

  @doc false
  @spec build_order_ticket_detail_coordinator_options() :: keyword()
  def build_order_ticket_detail_coordinator_options do
    build_order = settings!().build_order

    # Deliberately the *base* interval, unlike the graph cadences below.
    # `TicketDetailCoordinator` reads these options once, in `init/1`, and never
    # re-derives them — so a value taken from the effective interval would be
    # frozen at whatever the cadence happened to be at boot and would never
    # narrow again. It is also not part of what #2118 was about: this is a
    # conditional REST staleness window, where an unchanged refresh is a free
    # `304`, not an unconditional GraphQL read.
    [
      freshness_ms:
        Cadence.resolve(
          :ticket_detail_freshness_ms,
          build_order.ticket_detail_freshness_ms,
          poll_interval_seconds()
        ),
      max_entries: build_order.ticket_detail_max_entries,
      max_description_bytes: build_order.ticket_detail_max_description_bytes
    ]
  end

  @doc false
  @spec build_order_ticket_history_options() :: keyword()
  def build_order_ticket_history_options do
    build_order = settings!().build_order

    [
      history_limit: build_order.ticket_history_limit,
      max_identities: build_order.ticket_history_max_identities,
      stale_after_ms: build_order.ticket_history_stale_after_ms
    ]
  end

  @doc false
  @spec build_order_graph_projection_options() :: keyword()
  def build_order_graph_projection_options do
    build_order = settings!().build_order

    # Derived from the tracker's *effective* cycle unless the operator said
    # otherwise — the interval the dispatcher actually scheduled, idle and
    # webhook widening included. Build Order shows state the tracker produces,
    # so a cadence faster than the poll re-reads a graph that cannot have moved:
    # the old 15s and 5s constants did that once #2064 slowed the tracker, and
    # the base interval did it again whenever the fleet went idle (#2118).
    #
    # `GraphProjection` calls this on every reconcile, so it derives once and
    # reads both keys off the same map rather than deriving twice.
    derived = Cadence.effective()

    [
      catalog_refresh_ms: Cadence.prefer_configured(build_order.graph_catalog_refresh_ms, derived, :graph_catalog_refresh_ms),
      catalog_labels_refresh_ms:
        Cadence.prefer_configured(
          build_order.graph_catalog_labels_refresh_ms,
          derived,
          :graph_catalog_labels_refresh_ms
        ),
      refresh_timeout_ms: build_order.graph_refresh_timeout_ms,
      max_selected_roots: build_order.graph_max_selected_roots,
      max_inflight: build_order.graph_max_inflight
    ]
  end

  @spec workspace_hooks() :: map()
  def workspace_hooks do
    hooks = settings!().hooks

    %{
      after_create: hooks.after_create,
      before_run: hooks.before_run,
      after_run: hooks.after_run,
      before_remove: hooks.before_remove,
      timeout_ms: hooks.timeout_ms
    }
  end

  @spec hook_timeout_ms() :: pos_integer()
  def hook_timeout_ms do
    settings!().hooks.timeout_ms
  end

  @doc false
  @spec usage_ledger_durability_timeout() :: timeout()
  def usage_ledger_durability_timeout do
    case Application.get_env(:aiur, :usage_ledger_durability_timeout, :infinity) do
      :infinity -> :infinity
      timeout when is_integer(timeout) and timeout > 0 -> timeout
      _other -> :infinity
    end
  end

  @doc """
  Ceiling for new fleet admissions, derived from measured host capacity when the
  workflow omits `max_concurrent_agents`. Explicit config always wins; see
  `default_max_concurrent_agents/1` for the calibration.
  """
  @spec max_concurrent_agents() :: pos_integer()
  def max_concurrent_agents do
    case settings!().agent.max_concurrent_agents do
      n when is_integer(n) and n > 0 -> n
      _other -> default_max_concurrent_agents()
    end
  end

  @doc """
  Default fleet admission ceiling calibrated from measured host capacity rather
  than a hard-coded global agent count.

  The 2026-07-31 capacity run found a 16-core host saturates near ~19-20
  concurrent agents (load ~14 of 16), so the calibration is
  `schedulers + schedulers / 4` (16 → 20), floored at 2. This is a ceiling the
  load envelope adaptively backs off from under pressure, not a guaranteed
  concurrency target.
  """
  @spec default_max_concurrent_agents() :: pos_integer()
  @spec default_max_concurrent_agents(pos_integer()) :: pos_integer()
  def default_max_concurrent_agents(schedulers \\ System.schedulers_online())

  def default_max_concurrent_agents(schedulers)
      when is_integer(schedulers) and schedulers > 0 do
    max(schedulers + div(schedulers, 4), 2)
  end

  def default_max_concurrent_agents(_schedulers), do: 2

  @doc """
  Per-scheduler runnable-process ceiling for the instantaneous run-queue
  dispatch gate (#1430). `nil` disables the gate; a positive value holds new
  dispatch while `procs_running` strictly exceeds it times the scheduler count.
  """
  @spec run_queue_threshold() :: float() | nil
  def run_queue_threshold do
    settings!().agent.run_queue_threshold
  end

  @doc """
  Maximum number of agent-launched Mix compile/test commands allowed across the
  local workspace fleet. `0` disables the build gate intentionally.
  """
  @spec max_concurrent_builds() :: non_neg_integer()
  def max_concurrent_builds do
    settings!().agent.max_concurrent_builds
  end

  @doc "Minimum whole-second spacing between concurrent local Mix compile/test starts."
  @spec build_start_stagger_seconds() :: non_neg_integer()
  def build_start_stagger_seconds do
    settings!().agent.build_start_stagger_seconds || 0
  end

  @doc """
  Minimum Linux `MemAvailable` headroom required for normal dispatch and local
  agent Mix verification. `nil` disables memory admission.
  """
  @spec min_free_memory_mb() :: pos_integer() | nil
  def min_free_memory_mb do
    settings!().agent.min_free_memory_mb
  end

  @doc """
  Absolute wall-clock cap (seconds) on how long any one build-gate slot may be
  held before the detached lease holder releases it (#2349). `0` disables the
  backstop.
  """
  @spec build_gate_max_hold_seconds() :: non_neg_integer()
  def build_gate_max_hold_seconds do
    settings!().agent.build_gate_max_hold_seconds || 0
  end

  @doc "Scheduler count enforced for every Mix VM launched by an agent."
  @spec mix_scheduler_cap() :: pos_integer()
  def mix_scheduler_cap do
    settings!().agent.mix_scheduler_cap || 4
  end

  @doc """
  Whether the saturation sentinel recorder is enabled. The sentinel appends
  VM-internal + host diagnostics to `saturation.log` when 1-min load crosses
  the escalation threshold, so a crash under saturation is interpretable.
  """
  @spec saturation_log_enabled?() :: boolean()
  def saturation_log_enabled? do
    settings!().agent.saturation_log_enabled
  end

  @doc """
  Number of opencode-serve instances to pre-warm at boot. Each pre-
  warmed slot binds to a different active ticket as its leadoff so
  the user's first click on that ticket opens its chat pane in
  <100 ms. Defaults to 3 when absent from `.aiur/config`. `0` is valid
  and disables pre-warm entirely (all opens go through the cold
  placeholder path).
  """
  @spec pre_warmed_sessions() :: non_neg_integer()
  def pre_warmed_sessions do
    settings!().pre_warmed_sessions
  end

  @doc "Whether the repo-agnostic warm-base pre-warm is enabled (opt-in)."
  @spec prewarm_enabled?() :: boolean()
  def prewarm_enabled? do
    settings!().prewarm.enabled
  end

  @doc """
  The one-time base build command for the warm base, or nil when unset.
  Populated by `aiur init`'s toolchain detection; runs in the base checkout.
  """
  @spec prewarm_base_build() :: String.t() | nil
  def prewarm_base_build do
    settings!().prewarm.base_build
  end

  @doc "Background warm-base refresh interval in seconds; 0 disables polling."
  @spec prewarm_poll_seconds() :: non_neg_integer()
  def prewarm_poll_seconds do
    settings!().prewarm.poll_seconds
  end

  @doc """
  Resolved alert sound settings (`enabled`, `use_os_default_sounds`,
  `sound_dir`, `alerts_file`). Returns the non-raising `{:ok, _} | {:error, _}`
  so `Aiur.Alerts` can fall back to safe defaults rather than crashing a turn
  when no workflow config is loaded (early boot, tests).
  """
  @spec alerts_settings() :: {:ok, Schema.Alerts.t()} | {:error, term()}
  def alerts_settings do
    with {:ok, settings} <- settings(), do: {:ok, settings.alerts}
  end

  @doc """
  First Executor takeover advisory threshold in hours, or `0` when disabled.
  A nonterminal ticket first emits an advisory alert once its convergence age
  reaches this value.
  """
  @spec executor_takeover_first_alert_hours() :: non_neg_integer()
  def executor_takeover_first_alert_hours do
    settings!().executor_takeover_first_alert_hours
  end

  @doc """
  Repeated Executor takeover advisory cadence in hours, or `0` when disabled.
  After the first advisory, the monitor re-alerts at most this often while the
  ticket remains nonterminal and unresolved.
  """
  @spec executor_takeover_continuous_alert_hours() :: non_neg_integer()
  def executor_takeover_continuous_alert_hours do
    settings!().executor_takeover_continuous_alert_hours
  end

  @spec max_retry_attempts() :: pos_integer()
  def max_retry_attempts do
    settings!().agent.max_retry_attempts
  end

  @spec max_retry_backoff_ms() :: pos_integer()
  def max_retry_backoff_ms do
    settings!().agent.max_retry_backoff_ms
  end

  @spec codex_thrash_max_per_window() :: pos_integer()
  def codex_thrash_max_per_window do
    settings!().agent.codex.thrash_max_per_window
  end

  @spec codex_thrash_window_seconds() :: pos_integer()
  def codex_thrash_window_seconds do
    settings!().agent.codex.thrash_window_seconds
  end

  @spec agent_max_turns() :: pos_integer() | nil
  def agent_max_turns do
    settings!().agent.max_turns
  end

  @spec agent_turn_timeout_ms() :: pos_integer()
  def agent_turn_timeout_ms do
    settings!().agent.turn_timeout_ms
  end

  @spec agent_read_timeout_ms() :: pos_integer()
  def agent_read_timeout_ms do
    settings!().agent.codex.read_timeout_ms
  end

  @spec agent_stall_timeout_ms() :: non_neg_integer()
  def agent_stall_timeout_ms do
    settings!().agent.stall_timeout_ms
  end

  @spec max_agent_duration_minutes() :: non_neg_integer()
  def max_agent_duration_minutes do
    settings!().agent.max_agent_duration_minutes
  end

  @doc "Minutes before a CI-wait agent is re-woken for one recovery check."
  @spec ci_wait_rewake_minutes() :: pos_integer()
  def ci_wait_rewake_minutes do
    settings!().agent.ci_wait_rewake_minutes
  end

  @doc """
  Maximum known synthetic load-generator descendants allowed per agent process
  tree. `nil` in config derives from available schedulers; `0` disables the
  guard for Executors that prefer manual containment.
  """
  @spec synthetic_load_process_cap() :: non_neg_integer()
  def synthetic_load_process_cap do
    case settings!().agent.synthetic_load_process_cap do
      cap when is_integer(cap) and cap >= 0 -> cap
      _ -> default_synthetic_load_process_cap()
    end
  end

  @spec default_synthetic_load_process_cap() :: pos_integer()
  @spec default_synthetic_load_process_cap(integer()) :: pos_integer()
  def default_synthetic_load_process_cap(schedulers \\ System.schedulers_online())

  def default_synthetic_load_process_cap(schedulers)
      when is_integer(schedulers) and schedulers > 0 do
    max(1, div(schedulers, 4))
  end

  def default_synthetic_load_process_cap(_schedulers), do: 1

  # Per-scheduler 1-min load ceiling for dispatch admission (#465). Exceeded
  # load is corroborated with short-window reclaimable CPU before holding. The
  # default is 1.5; explicit YAML null disables the gate. The threshold is
  # multiplied by System.schedulers_online/0 (BEAM online schedulers, ~= cores
  # unless +S-limited).
  @spec max_load_average() :: float() | nil
  def max_load_average do
    settings!().agent.max_load_average
  end

  @doc """
  Per-scheduler 1-minute load target for adaptive dispatch capacity. Defaults
  to 1.0; explicit YAML `null` disables the adaptive envelope while preserving
  the independent `max_load_average` hard gate.
  """
  @spec target_load_average() :: float() | nil
  def target_load_average do
    settings!().agent.target_load_average
  end

  @doc """
  Number of dispatch slots added by each below-target envelope sample.
  """
  @spec load_ramp_step() :: pos_integer()
  def load_ramp_step do
    settings!().agent.load_ramp_step
  end

  @doc """
  Minimum number of seconds between high-load envelope decreases.
  """
  @spec load_cooldown_seconds() :: non_neg_integer()
  def load_cooldown_seconds do
    settings!().agent.load_cooldown_seconds
  end

  @spec codex_turn_sandbox_policy(Path.t() | nil) :: map()
  def codex_turn_sandbox_policy(workspace \\ nil) do
    case Schema.resolve_runtime_turn_sandbox_policy(settings!(), workspace) do
      {:ok, policy} ->
        policy

      {:error, reason} ->
        raise ArgumentError, message: "Invalid codex turn sandbox policy: #{inspect(reason)}"
    end
  end

  @spec workflow_prompt() :: String.t()
  def workflow_prompt do
    case Workflow.current() do
      {:ok, %{prompt_template: prompt}} ->
        if String.trim(prompt) == "", do: @default_prompt_template, else: prompt

      _ ->
        @default_prompt_template
    end
  end

  @spec server_port() :: non_neg_integer() | nil
  def server_port do
    case Application.get_env(:aiur, :server_port_override) do
      port when is_integer(port) and port >= 0 -> port
      _ -> settings!().server.port
    end
  end

  @spec server_host() :: String.t()
  def server_host do
    case Application.get_env(:aiur, :server_host_override) do
      host when is_binary(host) and host != "" -> host
      _ -> settings!().server.host
    end
  end

  @spec observability_enabled?() :: boolean()
  def observability_enabled? do
    settings!().observability.dashboard_enabled
  end

  @doc "Whether run telemetry recording is active. True by default; set `observability.telemetry_enabled: false` to opt out."
  @spec telemetry_enabled?() :: boolean()
  @spec telemetry_enabled?(term()) :: boolean()
  def telemetry_enabled?(settings \\ settings_uncached()) do
    case settings do
      {:ok, %{observability: observability}} -> observability.telemetry_enabled
      _other -> true
    end
  end

  @doc """
  Whether the `aiur run` upgrade-version notice is enabled. True by default;
  set `upgrade.check_enabled: false` to suppress the registry check entirely.
  Fails open (returns true) when the config cannot be read, so a config error
  never silently disables the notice.
  """
  @spec upgrade_check_enabled?() :: boolean()
  @spec upgrade_check_enabled?(term()) :: boolean()
  def upgrade_check_enabled?(settings \\ settings_uncached()) do
    case settings do
      {:ok, %{upgrade: upgrade}} -> upgrade.check_enabled
      _other -> true
    end
  end

  # Whether the dashboard may drive agents (Executor chat, pause). Read-only by
  # default until a deliberate dashboard parity pass — see issue #371.
  @spec dashboard_writable?() :: boolean()
  def dashboard_writable? do
    settings!().observability.dashboard_writable
  end

  @spec supervisor_decision_policy() :: %{
          allowed_kinds: [String.t()],
          allow_non_reversible: boolean()
        }
  def supervisor_decision_policy do
    decisions = settings!().decisions

    %{
      allowed_kinds: decisions.supervisor_allowed_kinds,
      allow_non_reversible: decisions.supervisor_allow_non_reversible
    }
  end

  @spec observability_refresh_ms() :: pos_integer()
  def observability_refresh_ms do
    settings!().observability.refresh_ms
  end

  @spec observability_render_interval_ms() :: pos_integer()
  def observability_render_interval_ms do
    settings!().observability.render_interval_ms
  end

  @doc """
  Retention limits for the durable run-telemetry stream.

  - `:max_bytes` — maximum file size in bytes. Whole boot groups are pruned
    from oldest to newest until the file fits. Defaults to 64 MiB.
  - `:max_age_days` — maximum age of a retained boot in days. Defaults to 30.
  - `:prune_interval_bytes` — periodic in-writer pruning fires after this many
    bytes have been written since the last prune. Defaults to `max(max_bytes/8, 1 MiB)`
    and can be overridden with `observability.telemetry_retention_prune_interval_bytes`.
  """
  @spec telemetry_retention() :: [
          max_bytes: pos_integer(),
          max_age_days: pos_integer(),
          prune_interval_bytes: pos_integer()
        ]
  def telemetry_retention do
    case settings() do
      {:ok, %{observability: observability}} ->
        max_bytes = Map.get(observability, :telemetry_retention_max_bytes, @default_telemetry_retention_max_bytes)

        [
          max_bytes: max_bytes,
          max_age_days: Map.get(observability, :telemetry_retention_max_age_days, @default_telemetry_retention_max_age_days),
          prune_interval_bytes: Map.get(observability, :telemetry_retention_prune_interval_bytes) || default_prune_interval(max_bytes)
        ]

      _other ->
        [
          max_bytes: @default_telemetry_retention_max_bytes,
          max_age_days: @default_telemetry_retention_max_age_days,
          prune_interval_bytes: default_prune_interval(@default_telemetry_retention_max_bytes)
        ]
    end
  end

  defp default_prune_interval(max_bytes) when is_integer(max_bytes) and max_bytes > 0,
    do: max(div(max_bytes, 8), @minimum_telemetry_retention_prune_interval_bytes)

  @spec validate!() :: :ok | {:error, term()}
  def validate! do
    with {:ok, settings} <- settings() do
      validate_semantics(settings)
    end
  end

  @spec codex_runtime_settings(Path.t() | nil, keyword()) ::
          {:ok, codex_runtime_settings()} | {:error, term()}
  def codex_runtime_settings(workspace \\ nil, opts \\ []) do
    with {:ok, settings} <- settings(),
         {:ok, approval_policy} <-
           validate_codex_approval_policy(settings.agent.codex.approval_policy),
         {:ok, turn_sandbox_policy} <- codex_runtime_turn_sandbox_policy(settings, workspace, opts) do
      {:ok,
       %{
         approval_policy: approval_policy,
         thread_sandbox: settings.agent.codex.thread_sandbox,
         turn_sandbox_policy: turn_sandbox_policy
       }}
    end
  end

  defp codex_runtime_turn_sandbox_policy(settings, workspace, opts) do
    with {:ok, turn_sandbox_policy} <-
           Schema.resolve_runtime_turn_sandbox_policy(settings, workspace, opts),
         {:ok, turn_sandbox_policy} <-
           maybe_add_package_manager_roots(turn_sandbox_policy, opts),
         {:ok, turn_sandbox_policy} <- maybe_add_github_budget_root(turn_sandbox_policy, opts) do
      maybe_add_build_gate_root(turn_sandbox_policy, settings, opts)
    end
  end

  defp maybe_add_package_manager_roots(turn_sandbox_policy, opts) do
    cond do
      Keyword.get(opts, :remote, false) ->
        {:ok, turn_sandbox_policy}

      not workspace_write_policy?(turn_sandbox_policy) ->
        {:ok, turn_sandbox_policy}

      true ->
        Schema.add_runtime_turn_sandbox_roots(turn_sandbox_policy, AgentEnvironment.package_cache_paths(opts))
    end
  end

  defp maybe_add_github_budget_root(turn_sandbox_policy, opts) do
    cond do
      Keyword.get(opts, :remote, false) ->
        {:ok, turn_sandbox_policy}

      not workspace_write_policy?(turn_sandbox_policy) ->
        {:ok, turn_sandbox_policy}

      not Budget.enabled?() ->
        {:ok, turn_sandbox_policy}

      true ->
        with :ok <- Budget.ensure_state_dir() do
          Schema.add_runtime_turn_sandbox_roots(turn_sandbox_policy, [Budget.state_dir()])
        end
    end
  end

  defp maybe_add_build_gate_root(turn_sandbox_policy, settings, opts) do
    gate_opts = [
      slots: settings.agent.max_concurrent_builds,
      stagger_seconds: settings.agent.build_start_stagger_seconds,
      min_free_memory_mb: settings.agent.min_free_memory_mb
    ]

    cond do
      Keyword.get(opts, :remote, false) ->
        {:ok, turn_sandbox_policy}

      not BuildGate.enabled?(gate_opts) ->
        {:ok, turn_sandbox_policy}

      not workspace_write_policy?(turn_sandbox_policy) ->
        {:ok, turn_sandbox_policy}

      true ->
        with {:ok, effective_roots} <- policy_writable_roots(turn_sandbox_policy),
             {:ok, gate_dir} <-
               BuildGate.prepare_writable_root(Keyword.put(gate_opts, :writable_roots, effective_roots)) do
          Schema.add_runtime_turn_sandbox_roots(turn_sandbox_policy, [gate_dir])
        end
    end
  end

  defp workspace_write_policy?(policy) do
    (Map.get(policy, "type") || Map.get(policy, :type)) == "workspaceWrite"
  end

  defp policy_writable_roots(policy) do
    case Map.get(policy, "writableRoots") || Map.get(policy, :writableRoots) || [] do
      roots when is_list(roots) -> {:ok, roots}
      roots -> {:error, {:unsafe_turn_sandbox_policy, {:invalid_writable_roots, roots}}}
    end
  end

  defp validate_codex_approval_policy(value) do
    case Aiur.Codex.Config.validate_approval_policy(value) do
      {:ok, trimmed} -> {:ok, trimmed}
      {:error, _message} -> {:error, {:invalid_codex_approval_policy, value}}
    end
  end

  defp validate_semantics(settings) do
    with :ok <- validate_kinds_and_secrets(settings),
         :ok <- Schema.validate_turn_sandbox_policy(settings) do
      Aiur.Opencode.Config.validate!()
    end
  end

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp validate_kinds_and_secrets(settings) do
    cond do
      is_nil(settings.tracker.kind) ->
        {:error, :missing_tracker_kind}

      settings.tracker.kind not in ["linear", "github", "memory"] ->
        {:error, {:unsupported_tracker_kind, settings.tracker.kind}}

      settings.agent.kind not in Aiur.CodingAgent.dispatchable_backends(settings.agent.backend_configs) ->
        {:error, {:unsupported_agent_kind, settings.agent.kind}}

      settings.tracker.kind == "linear" and not is_binary(settings.tracker.linear.api_key) ->
        {:error, :missing_linear_api_token}

      settings.tracker.kind == "linear" and not is_binary(settings.tracker.linear.project_slug) ->
        {:error, :missing_linear_project_slug}

      settings.tracker.kind == "github" ->
        Aiur.GitHub.Config.validate!()

      settings.agent.kind == "claude" ->
        Aiur.Claude.Config.validate!()

      true ->
        :ok
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
