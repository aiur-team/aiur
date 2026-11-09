defmodule Aiur.Orchestrator.Cancellation.Client do
  @moduledoc false

  alias Aiur.Issue
  alias Aiur.Orchestrator.Cancellation.{Observation, OutboundEvents}
  alias Aiur.Orchestrator.TicketTransition

  @tracker_state "cancelled"

  @spec cancel_agent(GenServer.server(), String.t()) ::
          {:ok, Observation.result()} | {:error, term()}
  def cancel_agent(server, identifier), do: cancel_agent(server, identifier, [])

  @doc false
  @spec cancel_agent(GenServer.server(), String.t(), keyword()) ::
          {:ok, Observation.result()} | {:error, term()}
  def cancel_agent(server, identifier, opts)
      when is_binary(identifier) and identifier != "" and is_list(opts) do
    server
    |> call_server({:cancel_agent, identifier})
    |> finish_cancel_call(server, opts)
  end

  def cancel_agent(_server, _identifier, _opts), do: {:error, :invalid_identifier}

  defp finish_cancel_call({:cancel_tracker_io, identifier, stage, %Issue{} = issue}, server, opts) do
    issue_key = to_string(issue.identifier || issue.id)
    tracker_result = write_tracker_cancel(issue_key, issue)

    server
    |> finish_tracker_result(identifier, stage, tracker_result, opts)
    |> publish_result(issue, opts)
  end

  defp finish_cancel_call(reply, _server, _opts), do: reply

  defp publish_result({:ok, result} = reply, issue, opts) do
    publish_fun = Keyword.get(opts, :event_publish_fun, &OutboundEvents.publish/2)
    _ = safe_publish(publish_fun, result, issue)
    reply
  end

  defp publish_result(reply, _issue, _opts), do: reply

  defp finish_tracker_result(server, identifier, stage, :ok, opts) do
    monitor = Process.monitor(stage.pid)

    case call_server(server, {:cancel_tracker_result, identifier, stage, :ok}) do
      {:cancel_observe, ^identifier, ^stage, stop_result} ->
        outcome = Observation.observe_exit(monitor, stage.pid, stage, identifier, stop_result, opts)
        reconcile_observation(server, stage, outcome)

      reply ->
        Process.demonitor(monitor, [:flush])
        reply
    end
  end

  defp finish_tracker_result(server, identifier, stage, tracker_result, _opts),
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

  defp safe_publish(publish_fun, result, issue) do
    publish_fun.(result, issue)
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end
end
