defmodule Aiur.AgentRunner.Handoff.ProviderState do
  @moduledoc false

  alias Aiur.AgentRunner.QueueDrain
  alias Aiur.AgentTools.Dispatch

  @spec restore_session(map(), Aiur.Issue.t()) :: map()
  def restore_session(%{backend: backend} = session, issue) when backend in ["codex", "claude"] do
    server = Aiur.ProviderAccountGeneration
    adapter = Aiur.CodingAgent.adapter(backend)
    session = adapter.restore_handoff_session(session, issue, server)

    Map.merge(session, %{
      clock: &DateTime.utc_now/0,
      account_generation_server: server,
      provider_meter_ingester: &Aiur.ProviderMeters.ingest/1,
      provider_meter_failure_recorder: &Aiur.ProviderMeters.record_failure/1
    })
  end

  def restore_session(session, _issue), do: session

  @spec restore(map(), keyword()) :: map()
  def restore(state, opts) do
    pending =
      Map.new(state.pending_operator_requests, fn {id, request} ->
        {id, Map.merge(request, callbacks(request, opts))}
      end)

    state
    |> Map.put(:on_message, Keyword.get(opts, :on_message, fn _ -> :ok end))
    |> Map.put(:on_safe_checkpoint, Keyword.get(opts, :on_safe_checkpoint, fn _ -> :noop end))
    |> Map.put(:tool_executor, Keyword.get(opts, :tool_executor, &Dispatch.execute/2))
    |> Map.put(:pending_operator_requests, pending)
    |> Map.put(:timeout_ms, Aiur.Config.agent_turn_timeout_ms())
  end

  defp callbacks(%{on_success: %{handoff_item: item, handoff_issue: issue}}, opts) do
    orchestrator = Keyword.get(opts, :handoff_orchestrator, Aiur.Orchestrator)

    %{
      on_success: fn metadata ->
        :ok = QueueDrain.record_provider_delivery(item, issue, Aiur.Commands.default_store())
        QueueDrain.acknowledge_provider_delivery(orchestrator, item, metadata)
      end,
      on_failure: fn _reason -> Aiur.Orchestrator.restore_queue_item_pending(orchestrator, item.id) end
    }
  end

  defp callbacks(_request, _opts), do: %{on_success: fn _ -> :ok end, on_failure: fn _ -> :ok end}
end
