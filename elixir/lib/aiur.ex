defmodule Aiur do
  @moduledoc """
  Entry point for the Aiur orchestrator.
  """

  @doc """
  Start the orchestrator in the current BEAM node.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    Aiur.Orchestrator.start_link(opts)
  end
end

defmodule Aiur.Application do
  @moduledoc """
  OTP application entrypoint that starts core supervisors and workers.
  """

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    :ok = Aiur.Boot.mark()
    :ok = Aiur.LogFile.configure()
    Logger.info("aiur_boot phase=start elapsed_ms=0")
    install_signal_handlers()
    maybe_start_distribution()

    interactive_cli? = Application.get_env(:aiur, :interactive_cli, false)

    cli_children =
      if interactive_cli? do
        [
          Aiur.Tmux,
          Aiur.PaneManager,
          Aiur.Opencode.PrewarmSupervisor,
          Aiur.AgentList.App,
          Aiur.AgentList.Input
        ]
      else
        []
      end

    children =
      [
        {Phoenix.PubSub, name: Aiur.PubSub},
        {Registry, keys: :unique, name: Aiur.IssueLog.Registry},
        {Registry, keys: :unique, name: Aiur.Opencode.PaneRegistry},
        {Registry, keys: :duplicate, name: Aiur.Opencode.SessionWriterRegistry.Registry},
        {Registry, keys: :unique, name: Aiur.Opencode.SlotRegistry.Registry},
        {DynamicSupervisor, strategy: :one_for_one, name: Aiur.IssueLog.Supervisor},
        {Task.Supervisor, name: Aiur.TaskSupervisor},
        Aiur.WorkflowStore,
        Aiur.Events.IdGenerator,
        Aiur.Events.Exchange,
        Aiur.Events.Publisher,
        {Registry, keys: :unique, name: Aiur.Events.SubscriptionStoreRegistry},
        Aiur.Events.SubscriptionStoreSupervisor,
        Aiur.Orchestrator,
        Aiur.HttpServer,
        Aiur.Opencode.TokenRegistry,
        Aiur.Opencode.ActiveTurns,
        Aiur.Opencode.PaneSupervisor,
        Aiur.Opencode.SessionSupervisor,
        Aiur.Opencode.BridgeSupervisor
      ] ++ cli_children

    Supervisor.start_link(
      children,
      strategy: :one_for_one,
      name: Aiur.Supervisor
    )
  end

  @impl true
  def stop(_state) do
    # SIGTERM / `:init.stop` path — OTP shuts down before `Aiur.Shutdown.shutdown/2`
    # would normally run, so make sure opencode sessions are still reaped.
    # `delete_all/1` is idempotent so re-entry from the `q`-key path is safe.
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

  # BEAM-level signal routing. The Erlang VM's default handlers already do
  # what we want for catchable signals:
  #   SIGINT  -> `init:stop()` -> Application.stop/1 -> Aiur.Shutdown.cleanup
  #   SIGTERM -> `init:stop()` -> same path
  # SIGHUP defaults to ignored on most VMs; we explicitly opt it into the
  # same graceful path so a terminal-close kills opencode sessions too.
  # Layer 2 (the bash trap in `scripts/aiur`) backstops these. Layer 3 is
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
end
