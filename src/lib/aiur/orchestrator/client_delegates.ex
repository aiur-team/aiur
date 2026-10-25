defmodule Aiur.Orchestrator.ClientDelegates do
  @moduledoc false

  defmacro __using__(_opts) do
    quote do
      defdelegate request_refresh(), to: Aiur.Orchestrator.Client
      defdelegate request_refresh(server), to: Aiur.Orchestrator.Client
      defdelegate note_queued_demand(identifiers), to: Aiur.Orchestrator.Client
      defdelegate note_queued_demand(server, identifiers), to: Aiur.Orchestrator.Client
      defdelegate send_operator_message(identifier, payload), to: Aiur.Orchestrator.Client
      defdelegate send_operator_message(server, identifier, payload), to: Aiur.Orchestrator.Client
      defdelegate send_correlated_operator_message(identifier, payload), to: Aiur.Orchestrator.Client
      defdelegate send_correlated_operator_message(server, identifier, payload), to: Aiur.Orchestrator.Client
      defdelegate pause_agent(identifier), to: Aiur.Orchestrator.Client
      defdelegate pause_agent(server, identifier), to: Aiur.Orchestrator.Client
      defdelegate request_control(identifier, action, request_id), to: Aiur.Orchestrator.Client
      defdelegate request_control(server, identifier, action, request_id), to: Aiur.Orchestrator.Client
      defdelegate mark_sleeping(identifier), to: Aiur.Orchestrator.Client
      defdelegate mark_sleeping(server, identifier), to: Aiur.Orchestrator.Client
      defdelegate interrupt_agent(identifier), to: Aiur.Orchestrator.Client
      defdelegate interrupt_agent(server, identifier), to: Aiur.Orchestrator.Client
      defdelegate pane_interrupt(identifier), to: Aiur.Orchestrator.Client
      defdelegate pane_interrupt(server, identifier), to: Aiur.Orchestrator.Client
      defdelegate pane_interrupt_by_pane_id(pane_id), to: Aiur.Orchestrator.Client
      defdelegate pane_interrupt_by_pane_id(server, pane_id), to: Aiur.Orchestrator.Client
      defdelegate resume_agent(identifier), to: Aiur.Orchestrator.Client
      defdelegate resume_agent(server, identifier), to: Aiur.Orchestrator.Client
      defdelegate resume_agent_with_receipt(identifier), to: Aiur.Orchestrator.Client
      defdelegate resume_agent_with_receipt(server, identifier), to: Aiur.Orchestrator.Client
      defdelegate prioritize_agent(identifier), to: Aiur.Orchestrator.Client
      defdelegate prioritize_agent(server, identifier), to: Aiur.Orchestrator.Client
      defdelegate deprioritize_agent(identifier), to: Aiur.Orchestrator.Client
      defdelegate deprioritize_agent(server, identifier), to: Aiur.Orchestrator.Client
      defdelegate control_lifecycle(identifier), to: Aiur.Orchestrator.Client
      defdelegate control_lifecycle(server, identifier), to: Aiur.Orchestrator.Client
      defdelegate reset_dispatch_budget(identifier), to: Aiur.Orchestrator.Client
      defdelegate reset_dispatch_budget(server, identifier), to: Aiur.Orchestrator.Client
      defdelegate max_concurrent_agents(), to: Aiur.Orchestrator.Client
      defdelegate max_concurrent_agents(server), to: Aiur.Orchestrator.Client
      defdelegate adjust_max_concurrent_agents(delta), to: Aiur.Orchestrator.Client
      defdelegate adjust_max_concurrent_agents(server, delta), to: Aiur.Orchestrator.Client
      defdelegate set_max_concurrent_agents(next), to: Aiur.Orchestrator.Client
      defdelegate set_max_concurrent_agents(server, next), to: Aiur.Orchestrator.Client
      defdelegate globally_paused?(), to: Aiur.Orchestrator.Client
      defdelegate global_pause_status(), to: Aiur.Orchestrator.Client
      defdelegate global_pause_status(server, timeout_ms), to: Aiur.Orchestrator.Client
      defdelegate set_global_pause(on?), to: Aiur.Orchestrator.Client
      defdelegate set_global_pause(on?, source), to: Aiur.Orchestrator.Client
      defdelegate control_capabilities(identifier), to: Aiur.Orchestrator.Client
      defdelegate control_capabilities(server, identifier), to: Aiur.Orchestrator.Client
      defdelegate set_remote_control(identifier, on?), to: Aiur.Orchestrator.Client
      defdelegate set_remote_control(server, identifier, on?), to: Aiur.Orchestrator.Client
      defdelegate ensure_remote_control_trust(workspace), to: Aiur.Orchestrator.Client
      defdelegate ensure_remote_control_trust(server, workspace), to: Aiur.Orchestrator.Client

      defdelegate operator_message_status(server \\ Aiur.Orchestrator, item_id, timeout \\ 5_000),
        to: Aiur.Orchestrator.Client

      defdelegate claim_next_queue_item(server, identifier), to: Aiur.Orchestrator.Client
      defdelegate claim_next_checkpoint_queue_item(server, identifier), to: Aiur.Orchestrator.Client
      defdelegate claim_blocker_critical_events_digest(server, identifier), to: Aiur.Orchestrator.Client
      defdelegate claim_next_operator_queue_item(server, identifier), to: Aiur.Orchestrator.Client
      defdelegate claim_operator_response(server, identifier, command), to: Aiur.Orchestrator.Client
      defdelegate mark_queue_item_consumed(server, item_id), to: Aiur.Orchestrator.Client
      defdelegate restore_queue_item_pending(server, item_id), to: Aiur.Orchestrator.Client
      defdelegate mark_queue_item_failed(server, item_id, reason), to: Aiur.Orchestrator.Client
      defdelegate acknowledge_queue_item_delivery(server, item_id, provider_metadata), to: Aiur.Orchestrator.Client
      defdelegate consume_delivered_queue_items(server, identifier), to: Aiur.Orchestrator.Client
      defdelegate restore_delivered_queue_items(server, identifier), to: Aiur.Orchestrator.Client
      defdelegate fail_delivered_queue_items(server, identifier, reason), to: Aiur.Orchestrator.Client
      defdelegate snapshot(), to: Aiur.Orchestrator.Client

      defdelegate list_active_identifiers(server \\ Aiur.Orchestrator, timeout \\ 1_000),
        to: Aiur.Orchestrator.Client

      defdelegate list_running_active_identifiers(server \\ Aiur.Orchestrator, timeout \\ 1_000),
        to: Aiur.Orchestrator.Client

      defdelegate poll_status(), to: Aiur.Orchestrator.Client
      defdelegate poll_status(server, timeout), to: Aiur.Orchestrator.Client
      defdelegate status(), to: Aiur.Orchestrator.Client
      defdelegate status(server, timeout), to: Aiur.Orchestrator.Client
      defdelegate status_with_capacity(server, timeout), to: Aiur.Orchestrator.Client
      defdelegate snapshot(server, timeout), to: Aiur.Orchestrator.Client

      defdelegate dashboard_snapshot(server \\ Aiur.Orchestrator, timeout \\ 15_000),
        to: Aiur.Orchestrator.Client

      defdelegate fleet_view(server \\ Aiur.Orchestrator, timeout, opts \\ []),
        to: Aiur.Orchestrator.Client
    end
  end
end
