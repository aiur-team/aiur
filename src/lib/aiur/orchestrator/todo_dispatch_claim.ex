defmodule Aiur.Orchestrator.TodoDispatchClaim do
  @moduledoc false

  require Logger

  alias Aiur.GitHub.Errors
  alias Aiur.{Issue, Orchestrator.State}
  alias Aiur.Orchestrator.{TicketTransition, TrackerTasks}

  @write_attempts 3

  @spec start(State.t(), Issue.t(), module()) :: State.t()
  def start(%State{} = state, %Issue{} = issue, tracker) when is_atom(tracker) do
    issue_key = to_string(issue.id || issue.identifier)

    write_claim = fn ->
      result =
        try do
          write_state_with_retry(issue_key, issue, tracker)
        rescue
          exception -> {:error, {:exception, exception}}
        catch
          kind, reason -> {:error, {kind, reason}}
        end

      case result do
        :ok ->
          :ok

        result ->
          Logger.warning("Unable to mark dispatched ticket in-progress: #{State.issue_context(issue)} reason=#{inspect(result)}")
      end
    end

    if TrackerTasks.owner?(state) do
      case Task.Supervisor.start_child(Aiur.TaskSupervisor, write_claim) do
        {:ok, _pid} ->
          :ok

        {:error, reason} ->
          Logger.warning("Unable to schedule dispatched ticket state write: #{State.issue_context(issue)} reason=#{inspect(reason)}")
      end

      state
    else
      write_claim.()
      state
    end
  end

  defp write_state_with_retry(issue_key, issue, tracker, attempt \\ 1) do
    case TicketTransition.write_state(issue_key, "in-progress",
           writer: :dispatcher,
           expected_state: issue.state,
           identifier: issue.identifier,
           tracker: tracker
         ) do
      {:error, reason} = error when attempt < @write_attempts ->
        if retryable?(reason) do
          Process.sleep(100 * attempt)
          write_state_with_retry(issue_key, issue, tracker, attempt + 1)
        else
          error
        end

      result ->
        result
    end
  end

  defp retryable?({:github, kind, _detail}) when kind in [:local_hold, :rate_limited], do: false

  defp retryable?({:github, :transport, %{reason: {:aiur, :locally_held, _hold}}}), do: false

  defp retryable?(reason), do: Errors.retryable_github_error?(reason)
end
