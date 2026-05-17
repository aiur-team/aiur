defmodule SymphonyElixir do
  @moduledoc """
  Entry point for the Symphony orchestrator.
  """

  @doc """
  Start the orchestrator in the current BEAM node.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    SymphonyElixir.Orchestrator.start_link(opts)
  end
end

defmodule SymphonyElixir.Application do
  @moduledoc """
  OTP application entrypoint that starts core supervisors and workers.
  """

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    :ok = SymphonyElixir.LogFile.configure()
    maybe_start_distribution()

    interactive_cli? = Application.get_env(:symphony_elixir, :interactive_cli, false)
    pane_cli? = Application.get_env(:symphony_elixir, :pane_cli, false)

    cli_children =
      cond do
        pane_cli? ->
          [
            SymphonyElixir.Tmux,
            SymphonyElixir.PaneManager,
            SymphonyElixir.AgentList.App,
            SymphonyElixir.AgentList.Input
          ]

        interactive_cli? ->
          [{SymphonyElixir.StatusDashboard, selected_index: 0}, SymphonyElixir.TerminalInput]

        true ->
          [SymphonyElixir.StatusDashboard]
      end

    children =
      [
        {Phoenix.PubSub, name: SymphonyElixir.PubSub},
        {Task.Supervisor, name: SymphonyElixir.TaskSupervisor},
        SymphonyElixir.WorkflowStore,
        SymphonyElixir.Orchestrator,
        SymphonyElixir.HttpServer
      ] ++ cli_children

    Supervisor.start_link(
      children,
      strategy: :one_for_one,
      name: SymphonyElixir.Supervisor
    )
  end

  @impl true
  def stop(_state) do
    if Application.get_env(:symphony_elixir, :pane_cli, false) do
      :ok
    else
      SymphonyElixir.StatusDashboard.render_offline_status()
      :ok
    end
  end

  defp maybe_start_distribution do
    case SymphonyElixir.Distribution.start!() do
      :ok ->
        Logger.info("Distribution active as #{inspect(SymphonyElixir.Distribution.node_name())}")

      {:error, reason} ->
        Logger.debug("Distribution not active: #{inspect(reason)}; pane subcommand will not connect")
    end
  end
end
