defmodule Aiur.AgentRunner.Supervisor do
  @moduledoc false

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      Aiur.Opencode.ActiveTurns,
      {Task.Supervisor, name: Aiur.TaskSupervisor}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
