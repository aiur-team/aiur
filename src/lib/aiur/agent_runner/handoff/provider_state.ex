defmodule Aiur.AgentRunner.Handoff.ProviderState do
  @moduledoc false

  alias Aiur.AgentRunner.QueueDrain
  alias Aiur.AgentTools.Dispatch
  alias Aiur.Codex.SessionLifecycle, as: CodexSessionLifecycle

  @spec restore_session(map(), Aiur.Issue.t()) :: map()
  def restore_session(%{backend: backend} = session, issue) when backend in ["codex", "claude"] do
    server = Aiur.ProviderAccountGeneration
    binding = if backend == "codex", do: Aiur.Codex.AccountGeneration.new_binding(server), else: Aiur.Claude.AccountGeneration.new_binding(server)

    session =
      Map.merge(session, %{
        clock: &DateTime.utc_now/0,
        account_generation_binding: binding.binding,
        account_generation_authority: binding.authority,
        account_generation_context: binding.context,
        account_generation_topic: binding.topic,
        account_generation_server: server,
        provider_meter_ingester: &Aiur.ProviderMeters.ingest/1,
        provider_meter_failure_recorder: &Aiur.ProviderMeters.record_failure/1
      })

    if backend == "codex" do
      metadata = Map.get(session, :metadata, %{})

      session
      |> Map.put(:containment, CodexSessionLifecycle.register_pause_containment(issue.identifier, metadata, session.workspace))
      |> Map.put(:account_generation_notification_handler, CodexSessionLifecycle.notification_handler(session, fn _ -> :ok end))
    else
      session
    end
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
