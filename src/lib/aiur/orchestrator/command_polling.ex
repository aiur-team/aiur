defmodule Aiur.Orchestrator.CommandPolling do
  @moduledoc false
  require Logger
  alias Aiur.GitHub.Listeners
  alias Aiur.Orchestrator.{State, TrackerTasks}

  @spec scan(State.t(), keyword()) :: State.t()
  def scan(state, opts \\ []) do
    if Aiur.Config.tracker_kind() == "github" and Aiur.GitHub.Config.pr_watch_enabled?(), do: run(state, opts), else: state
  end

  defp run(state, opts) do
    TrackerTasks.run(state, :command_scan, fn -> Listeners.scan_commands(opts) end, fn current, result ->
      if result != :ok, do: Logger.warning("PR command scan task failed: #{inspect(result)}")
      current
    end)
  end
end
