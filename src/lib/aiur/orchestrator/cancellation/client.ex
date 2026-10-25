defmodule Aiur.Orchestrator.Cancellation.Client do
  @moduledoc false

  alias Aiur.Issue
  alias Aiur.Orchestrator.Cancellation.Observation
  alias Aiur.Orchestrator.TicketTransition

  @tracker_state "cancelled"

  @spec cancel_agent(GenServer.server(), String.t()) ::
          {:ok, Observation.result()} | {:error, term()}
  def cancel_agent(server, identifier) when is_binary(identifier) and identifier != "" do
    server
    |> call_server({:cancel_agent, identifier})
    |> finish_cancel_call(server)
  end

  def cancel_agent(_server, _identifier), do: {:error, :invalid_identifier}

  defp finish_cancel_call({:cancel_tracker_io, identifier, stage, %Issue{} = issue}, server) do
    issue_key = to_string(issue.identifier || issue.id)
    tracker_result = write_tracker_cancel(issue_key, issue)

    finish_tracker_result(server, identifier, stage, tracker_result)
  end

  defp finish_cancel_call(reply, _server), do: reply

  defp finish_tracker_result(server, identifier, stage, :ok) do
    monitor = Process.monitor(stage.pid)

    case call_server(server, {:cancel_tracker_result, identifier, stage, :ok}) do
      {:cancel_observe, ^identifier, ^stage, stop_result} ->
        outcome = Observation.observe_exit(monitor, stage.pid, stage.handle, identifier, stop_result, [])
        reconcile_observation(server, stage, outcome)

      reply ->
        Process.demonitor(monitor, [:flush])
        reply
    end
  end

  defp finish_tracker_result(server, identifier, stage, tracker_result),
    do: call_server(server, {:cancel_tracker_result, identifier, stage, tracker_result})

  defp reconcile_observation(server, stage, outcome) do
    case call_server(server, {:cancel_observation_result, stage, outcome}) do
      {:ok, _result} = reply -> reply
      {:error, _reason} -> {:ok, outcome}
    end
  end

  defp write_tracker_cancel(issue_key, %Issue{} = issue) do
    TicketTransition.write_state(issue_key, @tracker_state,
      writer: :usage_api_cancel,
      identifier: issue.identifier,
      expected_state: issue.state
    )
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp call_server(server, request) do
    timeout_ms = Application.get_env(:aiur, :control_api_call_timeout_ms, 5_000)
    GenServer.call(server, request, timeout_ms)
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, {:noproc, _} -> {:error, :unavailable}
    :exit, {{:nodedown, _node}, _} -> {:error, :unavailable}
    :exit, reason -> {:error, {:orchestrator_call_failed, reason}}
  end
end
