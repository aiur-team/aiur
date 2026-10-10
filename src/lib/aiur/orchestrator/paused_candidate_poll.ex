defmodule Aiur.Orchestrator.PausedCandidatePoll do
  @moduledoc false

  alias Aiur.Orchestrator.{State, TrackerTasks}

  @spec start(State.t(), (map() -> term()), (State.t(), map() -> State.t()), (State.t(), term() -> State.t()), (State.t() -> State.t()), (State.t() -> State.t())) :: State.t()
  def start(state, fetch, note_success, mark_unavailable, monitor, finish) do
    cache = state.ci_lifecycle |> Map.get(:poll_cache, %{}) |> Map.get(:candidate_list_cache, %{})

    TrackerTasks.start(state, :dispatch_poll, fn -> fetch.(cache) end, fn current, result ->
      current |> observe(result, note_success, mark_unavailable) |> monitor.() |> finish.()
    end)
  end

  defp observe(state, {:ok, _issues, cache}, note_success, _mark_unavailable), do: note_success.(state, cache)
  defp observe(state, {:error, reason}, _note_success, mark_unavailable), do: mark_unavailable.(state, reason)
end
