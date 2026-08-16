defmodule Aiur do
  @moduledoc """
  Entry point for the Aiur orchestrator.
  """

  @doc """
  Start the orchestrator in the current BEAM node.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    Aiur.Orchestrator.start_link(Keyword.put_new(opts, :name, Aiur.Orchestrator))
  end
end

defmodule Aiur.Application do
  @moduledoc """
  OTP application entrypoint that starts core supervisors and workers.
  """

  use Application

  require Logger

  alias Aiur.{AgentGitHubGuard, GitHub.Budget}
  alias Aiur.Config, as: AiurConfig
  alias Aiur.Config.RoutingValue
  alias Aiur.GitHub.Config

  @impl true
  def start(_type, _args) do
    :ok = Aiur.Boot.mark()
    :ok = Aiur.LogFile.ensure_session_log_file()
    :ok = Aiur.LogFile.apply_config_debug()
    :ok = Aiur.LogFile.configure()
    settings = Aiur.Config.settings_uncached()
    telemetry? = Aiur.Config.telemetry_enabled?(settings)
    Aiur.RunTelemetry.start_boot()
    Logger.info("aiur_boot phase=start elapsed_ms=0")
    :ok = log_base_branch(settings)
    log_process_identity()
    Aiur.Shutdown.record_workspace_root()
    install_signal_handlers()
    maybe_start_distribution()
    if Application.get_env(:aiur, :resolve_github_token_on_boot, true), do: resolve_github_token()
    if Budget.enabled?(), do: AgentGitHubGuard.install_host()

    no_dashboard? = Application.get_env(:aiur, :no_dashboard, false)

    with :ok <- validate_dashboard_compatibility(no_dashboard?) do
      headless? = Application.get_env(:aiur, :headless, false)
      # Headless is authoritative: if both flags somehow end up set (e.g. a
      # hand-run `aiur --headless` that also injected `--interactive`), the lean
      # path wins rather than booting a half-built interactive tree.
      interactive_cli? = Application.get_env(:aiur, :interactive_cli, false) and not headless?

      children =
        child_specs(
          interactive_cli?: interactive_cli?,
          headless?: headless?,
          dashboard?: not no_dashboard?,
          telemetry?: telemetry?
        )

      Supervisor.start_link(
        children ++ [supervision_health_child(children)],
        strategy: :one_for_one,
        name: Aiur.Supervisor
      )
    end
  end

  @doc false
  @spec log_base_branch() :: :ok
  @spec log_base_branch(term()) :: :ok
  def log_base_branch(settings \\ AiurConfig.settings_uncached()) do
    Logger.info("aiur_boot phase=config base_branch=#{inspect(AiurConfig.base_branch(settings))}")
    :ok
  end

  @doc """
  Reject a no-dashboard launch when configured Remote Control sessions would
  lose the HTTP lifecycle-hook endpoint they require.

  The optional inputs keep this check pure in tests; production resolves both
  values from the active workflow config.
  """
  @spec validate_dashboard_compatibility(boolean(), keyword()) :: :ok | {:error, String.t()}
  def validate_dashboard_compatibility(no_dashboard?, opts \\ [])

  def validate_dashboard_compatibility(false, _opts), do: :ok

  def validate_dashboard_compatibility(true, opts) do
    remote_control? = Keyword.get_lazy(opts, :remote_control?, &AiurConfig.agent_remote_control?/0)
    routing = Keyword.get_lazy(opts, :routing, &AiurConfig.agent_routing/0)

    sources =
      []
      |> maybe_add_remote_control_source(remote_control?, "agent.remote_control")
      |> maybe_add_remote_control_source(remote_routing?(routing), "agent.routing +remote")

    case sources do
      [] ->
        :ok

      configured_sources ->
        {:error,
         "--no-dashboard cannot be used with Claude Remote Control configured by " <>
           "#{Enum.join(configured_sources, " and ")}; Remote Control lifecycle hooks require " <>
           "Aiur.HttpServer. Remove --no-dashboard or disable the Remote Control setting."}
    end
  end

  @doc """
  Build the supervision children for the given run shape.

  `--bg`/headless runs (`headless?: true`) skip terminal-only work — the
  opencode chat-pane machinery and the whole interactive CLI block (tmux,
  pane manager, opencode pre-warm, agent-list panes). Dashboard supervision
  is independent and remains enabled unless `--no-dashboard` is supplied.
  The agent **backends** that
  actually run agents (session writers, the opencode bridge, token
  registry) are kept so a headless node still does real work; an Executor
  drives it over the control RPC (`status` / `agents` / `message` /
  `pause` / `set max-agents`) instead of attaching to panes.

  Pure so the gating is unit-testable without booting the application —
  pass the resolved booleans and assert which children appear.
  """
  @spec child_specs(keyword()) :: [Supervisor.child_spec() | {module(), term()} | module()]
  def child_specs(opts) do
    interactive_cli? = Keyword.fetch!(opts, :interactive_cli?)
    headless? = Keyword.fetch!(opts, :headless?)
    dashboard? = Keyword.fetch!(opts, :dashboard?)
    telemetry? = Keyword.get(opts, :telemetry?, true)

    cli_children =
      if interactive_cli? do
        [
          {Aiur.Tmux, name: Aiur.Tmux},
          {Aiur.PaneManager, name: Aiur.PaneManager},
          Aiur.Opencode.PrewarmSupervisor,
          Aiur.AgentList.App,
          Aiur.AgentList.Input,
          Aiur.LauncherWatchdog
        ]
      else
        []
      end

    [
      {Phoenix.PubSub, name: Aiur.PubSub},
      {Registry, keys: :unique, name: Aiur.IssueLog.Registry},
      {Registry, keys: :unique, name: Aiur.Opencode.PaneRegistry},
      {Registry, keys: :duplicate, name: Aiur.Opencode.SessionWriterRegistry.Registry},
      {Registry, keys: :unique, name: Aiur.Opencode.SlotRegistry.Registry},
      {DynamicSupervisor, strategy: :one_for_one, name: Aiur.IssueLog.Supervisor},
      # Before Task.Supervisor: children stop in reverse order, so the
      # reaper outlives the runner tasks/ports whose OS processes it must
      # sweep in its terminate/2 backstop.
      Aiur.ProcessReaper,
      Aiur.PauseContainment,
      Aiur.AgentResourceGuard,
      Aiur.SaturationSentinel,
      Aiur.AppServer.ToolCallLedger,
      Aiur.Workspace.Ownership.Store,
      {Registry, keys: :unique, name: Aiur.Workspace.Ownership.Registry},
      Aiur.Workspace.Ownership.Reconciler,
      {Task.Supervisor, name: Aiur.TaskSupervisor},
      Aiur.AlertFeed.Backfill,
      Aiur.CoordinationTasks,
      Aiur.WorkflowStore,
      Aiur.RepoBase,
      Aiur.GitHub.AppTokenRefresher,
      Aiur.GitHub.Quota,
      {Aiur.BuildOrder.TicketDetailCache, runtime_config?: true},
      {Aiur.BuildOrder.GraphProjection, runtime_config?: true},
      Aiur.Events.IdGenerator,
      {Aiur.Events.Exchange, name: Aiur.Events.Exchange},
      Aiur.Events.BranchRefStore,
      if(telemetry?, do: Aiur.RunTelemetry.Supervisor),
      Aiur.Events.Publisher,
      # Per-repo delivery mode. Starts before anything that polls or receives
      # so a repo always has a mode to read; with no configured repos every
      # lookup answers "polling", which is exactly the pre-webhook behavior.
      Aiur.Webhooks.ModeRegistry,
      Aiur.ProviderAccountGeneration,
      Aiur.ProviderMeters.Store,
      # Reads the store's observations and serves them to consumer surfaces
      # without a binding. Starts after the store so no accepted observation
      # is broadcast before there is anything retaining it.
      Aiur.ProviderMeterProjection,
      # Decides when usage is observed: one baseline after boot, then only
      # while agents are running. Starts after the projection so a baseline
      # observation always has somewhere to land.
      Aiur.ProviderMeterRefresh,
      Aiur.UsageLedger,
      # Owns the one destructive storage seam: retention/compaction of retired
      # raw usage. Starts after the raw ledger it reads but before the aggregate,
      # so its boot reconciliation resolves any in-flight destructive phase into
      # a consistent ledger + compacted-floor state before the aggregate rebuilds
      # over it.
      Aiur.UsageCompaction.Coordinator,
      Aiur.UsageAggregate.Store,
      {Aiur.DecisionStore, name: Aiur.DecisionStore},
      {Aiur.DecisionMetrics.Writer, path: Aiur.DecisionMetrics.metrics_file()},
      Aiur.DecisionMetrics,
      Aiur.RecentMergeStore,
      # Webhook deduplication state must be replayed before any receiver can
      # admit a delivery.
      Aiur.Webhooks.DeliveryLog,
      Aiur.GitHub.CodeOwners,
      {Registry, keys: :unique, name: Aiur.Events.SubscriptionStoreRegistry},
      Aiur.Events.SubscriptionStoreSupervisor,
      Aiur.DecisionAttention,
      Aiur.OperatorWaitLog,
      Aiur.Orchestrator.TrackedSet,
      Aiur.Orchestrator.SnapshotStore,
      Aiur.Orchestrator.SnapshotPublisher,
      Aiur.CurrentRunMembership.Store,
      # LiveConversation is projection-only: it never replays workspace logs
      # after restart, so a missing key truthfully reports :restart_unknown.
      Aiur.LiveConversation,
      Aiur.TicketActivity,
      # Claude telemetry owns an independent loopback listener and must be
      # available before the Orchestrator starts owned Claude workers.
      Aiur.Claude.Telemetry,
      {Aiur.BuildOrder.TicketHistoryProvider, runtime_config?: true},
      {Aiur.BuildOrder.AdHocSource, poll_on_start: Application.get_env(:aiur, :build_order_adhoc_poll?, true)},
      {Aiur.BuildOrder.PackStatus, poll_on_start: Application.get_env(:aiur, :build_order_pack_status_poll?, true)},
      {Aiur.OpenTicketSource, poll_on_start: Application.get_env(:aiur, :open_ticket_poll?, dashboard?)},
      {Aiur.Orchestrator, name: Aiur.Orchestrator, initial_poll?: Application.get_env(:aiur, :orchestrator_initial_poll?, true)},
      Aiur.DecisionExpiry,
      Aiur.CurrentRunMembership.Reconciler,
      Aiur.CurrentRunProjections,
      Aiur.Events.LsRemoteTicker,
      Aiur.ProgressCheckin.Worker,
      Aiur.Logs.Retention,
      # Dashboard supervision is independent of terminal attachment/headless
      # mode. Aiur.HttpServer retains its own bind and credential guards.
      if(dashboard?, do: AiurWeb.ControlCenterCache),
      if(dashboard?, do: AiurWeb.FinancialData.Supervisor),
      if(dashboard?, do: Aiur.HttpServer),
      Aiur.Opencode.TokenRegistry,
      Aiur.Opencode.ActiveTurns,
      # Chat-pane machinery — UI-only, never read by a headless run.
      unless(headless?, do: Aiur.Opencode.PaneSupervisor),
      Aiur.Opencode.SessionSupervisor,
      Aiur.Opencode.BridgeSupervisor
    ]
    |> Enum.reject(&is_nil/1)
    |> Kernel.++(cli_children)
  end

  defp supervision_health_child(children) do
    {Aiur.SupervisionHealth, supervisor: Aiur.Supervisor, expected_children: children}
  end

  defp remote_routing?(routing) when is_map(routing) do
    Enum.any?(routing, fn {_level, value} -> RoutingValue.routing_remote_flag?(value) end)
  end

  defp remote_routing?(_routing), do: false

  defp maybe_add_remote_control_source(sources, true, source), do: sources ++ [source]
  defp maybe_add_remote_control_source(sources, false, _source), do: sources

  @impl true
  def prep_stop(state) do
    # SIGTERM / `:init.stop` path, BEFORE the supervision tree comes down —
    # the only point on that path where the ProcessReaper and the opencode
    # serves are still alive, so the kind-ordered cleanup (reap agents →
    # delete sessions over HTTP → reap serves) can actually hold.
    Aiur.Shutdown.cleanup()
    state
  end

  @impl true
  def stop(_state) do
    # Post-teardown best-effort re-entry. The reaper is gone by now (its own
    # terminate/2 already swept leftovers); `cleanup/1` phases are idempotent
    # and individually error-wrapped, so this is harmless after prep_stop.
    Aiur.Shutdown.cleanup()
    :ok
  end

  @doc """
  Run the distribution bring-up step and log the outcome. Public so
  tests can inject a stub `distribution_module` and exercise both
  success and failure branches without needing the actual BEAM to be
  distributed in the test environment.
  """
  @spec start_distribution(module()) :: :ok
  def start_distribution(distribution_module \\ Aiur.Distribution) do
    case distribution_module.start!() do
      :ok ->
        Logger.info("Distribution active as #{inspect(distribution_module.node_name())}")

      {:error, reason} ->
        Logger.debug("Distribution not active: #{inspect(reason)}; pane subcommand will not connect")
    end

    :ok
  end

  defp maybe_start_distribution, do: start_distribution()

  # Resolve the GitHub token once at boot — before the Orchestrator /
  # GithubFirehose children that need GitHub auth start — preferring a valid
  # GITHUB_TOKEN env var but falling back to the gh keyring when the env token
  # is stale/invalid. Best-effort: a resolution error must not crash boot.
  defp resolve_github_token do
    Config.resolve_token()
    :ok
  rescue
    error ->
      Logger.warning("aiur_boot phase=github_token_resolve_failed error=#{inspect(error)}")
      :ok
  end

  # BEAM-level signal routing. The Erlang VM's default handlers already do
  # what we want for catchable signals:
  #   SIGINT  -> `init:stop()` -> Application.stop/1 -> Aiur.Shutdown.cleanup
  #   SIGTERM -> `init:stop()` -> same path
  # SIGHUP defaults to ignored on most VMs; we explicitly opt it into the
  # same graceful path so a terminal-close kills opencode sessions too.
  # Layer 2 (the bash trap in `scripts/aiurdev`) backstops these. Layer 3 is
  # boot-time GC in `Aiur.Opencode.SessionGC` for uncatchable signals (SIGKILL, OOM).
  defp install_signal_handlers do
    try do
      :ok = :os.set_signal(:sighup, :handle)
    catch
      kind, reason ->
        Logger.warning("aiur_signal phase=sighup_install_failed kind=#{kind} reason=#{inspect(reason)}")
    end

    :ok
  end

  # One-shot at boot: log the BEAM's OS pid + parent pid + parent comm
  # so when the wrapper trap fires and writes `wrapper_pid=N` to
  # `/tmp/aiur-trap.N.log`, the pair tells you which wrapper invocation
  # owned which BEAM. Without this, post-mortems have to guess.
  defp log_process_identity do
    os_pid = System.pid()
    {ppid, ppid_comm} = read_parent_identity()
    Logger.info("aiur_boot phase=pids os_pid=#{os_pid} ppid=#{ppid} ppid_comm=#{ppid_comm}")
  end

  defp read_parent_identity do
    ppid =
      case File.read("/proc/self/status") do
        {:ok, contents} ->
          case Regex.run(~r/^PPid:\s+(\d+)/m, contents) do
            [_, pid_str] -> pid_str
            _ -> "unknown"
          end

        _ ->
          "unknown"
      end

    ppid_comm =
      case File.read("/proc/#{ppid}/comm") do
        {:ok, comm} -> String.trim(comm)
        _ -> "unknown"
      end

    {ppid, ppid_comm}
  end
end
