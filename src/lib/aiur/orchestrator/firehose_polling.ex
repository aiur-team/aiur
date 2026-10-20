defmodule Aiur.Orchestrator.FirehosePolling do
  @moduledoc false
  alias Aiur.GitHub.Listeners
  alias Aiur.Orchestrator.{State, TrackerHealth}

  @spec poll(State.t(), keyword()) :: State.t()
  def poll(state, opts \\ []), do: apply_outcome(state, Listeners.poll_firehose(opts))

  @spec start(State.t(), (State.t() -> State.t()), function(), keyword()) :: State.t()
  def start(state, continue, start_task, opts \\ []) do
    start_task.(state, :dispatch_poll, fn -> Listeners.poll_firehose(opts) end, fn current, outcome ->
      current |> apply_outcome(outcome) |> continue.()
    end)
  end

  @spec apply_outcome(State.t(), Listeners.outcome() | {:error, term()}) :: State.t()
  def apply_outcome(state, {:error, reason}), do: TrackerHealth.note_github_connectivity_failure(state, :firehose, reason)

  def apply_outcome(state, %{connectivity: connectivity, poll_interval: interval}) do
    Enum.reduce(connectivity, state, fn
      {:firehose, :ok}, current ->
        current |> TrackerHealth.note_github_connectivity_success(:firehose) |> TrackerHealth.note_github_poll_interval(:firehose, interval)

      {source, :ok}, current ->
        TrackerHealth.note_github_connectivity_success(current, source)

      {source, {:error, reason}}, current ->
        TrackerHealth.note_github_connectivity_failure(current, source, reason)
    end)
  end
end
