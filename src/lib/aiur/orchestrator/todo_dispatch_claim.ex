defmodule Aiur.Orchestrator.TodoDispatchClaim do
  @moduledoc false

  require Logger

  alias Aiur.{Issue, Orchestrator.State}
  alias Aiur.Orchestrator.{TicketTransition, TrackerTasks}

  @spec start(State.t(), Issue.t(), module()) :: State.t()
  def start(%State{} = state, %Issue{} = issue, tracker) when is_atom(tracker) do
    issue_key = to_string(issue.id || issue.identifier)

    TrackerTasks.run(
      state,
      {:todo_dispatch_claim, issue.id},
      fn ->
        TicketTransition.write_state(issue_key, "in-progress",
          writer: :dispatcher,
          expected_state: issue.state,
          identifier: issue.identifier,
          tracker: tracker
        )
      end,
      fn current, result ->
        if result != :ok do
          Logger.warning("Unable to mark dispatched ticket in-progress: #{State.issue_context(issue)} reason=#{inspect(result)}")
        end

        current
      end
    )
  end
end
