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

  @impl true
  def start(_type, _args) do
    :ok = SymphonyElixir.LogFile.configure()

    children = [
      {Phoenix.PubSub, name: SymphonyElixir.PubSub},
      {Task.Supervisor, name: SymphonyElixir.TaskSupervisor},
      SymphonyElixir.WorkflowStore,
      SymphonyElixir.Orchestrator,
      SymphonyElixir.HttpServer,
      status_dashboard_child()
    ]

    Supervisor.start_link(
      children,
      strategy: :one_for_one,
      name: SymphonyElixir.Supervisor
    )
  end

  @impl true
  def stop(_state) do
    if passive_status_dashboard_enabled?() do
      SymphonyElixir.StatusDashboard.render_offline_status()
    end

    :ok
  end

  defp passive_status_dashboard_enabled? do
    Application.get_env(:symphony_elixir, :passive_status_dashboard_enabled, true)
  end

  defp status_dashboard_child do
    if passive_status_dashboard_enabled?() do
      SymphonyElixir.StatusDashboard
    else
      {SymphonyElixir.StatusDashboard, enabled: false}
    end
  end
end
