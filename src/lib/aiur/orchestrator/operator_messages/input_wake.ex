defmodule Aiur.Orchestrator.OperatorMessages.InputWake do
  @moduledoc """
  Gives a parked ticket a turn when a person or the Executor queues input for it.

  A Command answer or an operator message for a ticket in `human-review` or
  `ci-wait` was queued and then sat there: neither state takes agent turns, so
  no worker ever read it. An `in-progress` ticket whose worker is gone (an
  orphaned claim) waited the same way. This writes `rework`, which makes the
  ticket dispatchable; the dispatcher starts a worker and that worker reads
  the queued input before anything else. The pull request is left as it is.

  The write is conditional on the state just read from the tracker, so a
  second input for the same ticket, or a concurrent move, is a no-op.
  """

  require Logger

  alias Aiur.Issue
  alias Aiur.Orchestrator.{DispatchPolicy, State, TicketTransition, TrackerTasks}
  alias Aiur.Tracker

  @parked_states ["human-review", "ci-wait"]

  @doc "Wakes the ticket an accepted input was queued for, when that ticket would otherwise never take a turn."
  @spec maybe_wake(State.t(), String.t(), map(), term()) :: State.t()
  def maybe_wake(%State{} = state, identifier, request, {:ok, _queued}) when is_binary(identifier) and identifier != "executor" do
    if waking_input?(request), do: wake(state, identifier), else: state
  end

  def maybe_wake(state, _identifier, _request, _result), do: state

  # Command answers arrive correlated and without an origin; every plain message
  # with an origin was sent by a person or the Executor. Internal notes never wake.
  defp waking_input?(%{mode: :correlated}), do: true
  defp waking_input?(%{origin: origin}), do: origin != :internal
  defp waking_input?(_request), do: false

  defp wake(state, identifier) do
    issue_id = issue_id(state, identifier)
    worker_live? = live_worker?(State.find_running_by_identifier(state.running, identifier))

    TrackerTasks.run(state, {:input_wake, issue_id}, fn -> write_rework(issue_id, identifier, worker_live?) end, fn current, _result -> current end)
  end

  @doc false
  @spec write_rework(String.t(), String.t(), boolean()) :: :ok | :skipped | {:error, term()}
  def write_rework(issue_id, identifier, worker_live?) do
    with {:ok, [%Issue{state: observed} | _]} <- Tracker.fetch_issue_states_by_ids([issue_id]),
         slug when is_binary(slug) <- DispatchPolicy.state_slug(observed),
         true <- wakes_from?(slug, worker_live?) do
      result = TicketTransition.write_state(issue_id, "rework", writer: :input_wake, expected_state: slug)
      Logger.info("Input queued for #{identifier} in #{slug}; wrote rework so a worker reads it: #{inspect(result)}")
      result
    else
      _not_parked -> :skipped
    end
  end

  defp wakes_from?(slug, _worker_live?) when slug in @parked_states, do: true
  defp wakes_from?("in-progress", worker_live?), do: not worker_live?
  defp wakes_from?(_slug, _worker_live?), do: false

  defp live_worker?(nil), do: false

  defp live_worker?(entry) do
    is_pid(Map.get(entry, :pid)) and State.alive?(entry.pid) and not State.deactivated_running_entry?(entry) and
      not State.completed_running_entry?(entry)
  end

  defp issue_id(state, identifier) do
    State.find_running_key_by_identifier(state.running, identifier) ||
      Enum.find_value(state.last_polled_issues, identifier, fn {id, issue} -> if issue.identifier == identifier, do: id end)
  end
end
