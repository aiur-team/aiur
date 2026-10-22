defmodule Aiur.AgentRunner.ToolExecutor do
  @moduledoc """
  Binds dynamic tool execution to an agent issue and worker context.
  The executor namespaces alerts and events, manages subscriptions, and keeps
  blocker declaration immediately subscribed for prompt resume behavior.
  """

  alias Aiur.AgentRunner.{DecisionAttention, EpicSetter, FeatureWriter, ToolCoordination, ToolEvents}
  alias Aiur.AgentRunner.ToolExecutor.TicketStateSetter

  alias Aiur.{Commands, CoordinationTasks, EventPublicationLog, Issue, Signal}

  alias Aiur.AgentTools.Dispatch
  alias Aiur.Events
  alias Aiur.GitHub.IssueDependencies
  alias Aiur.{Orchestrator, Orchestrator.TicketTransition}

  @invocation_key {__MODULE__, :invocation_id}

  @doc false
  @spec execute((String.t(), term() -> map()), String.t() | nil, term(), term()) :: map()
  def execute(executor, tool, arguments, invocation_id)
      when is_function(executor, 2) do
    previous = Process.get(@invocation_key, :unset)
    Process.put(@invocation_key, invocation_id)

    try do
      executor.(tool, arguments)
    after
      restore_invocation(previous)
    end
  end

  @doc false
  @spec invocation_id() :: term()
  def invocation_id, do: Process.get(@invocation_key)

  @spec build(Issue.t(), Path.t() | nil, String.t() | nil, map(), keyword()) :: (String.t(), map() -> map())
  def build(issue, workspace, worker_host, app_session \\ %{}, opts \\ []) do
    attempt_id = Keyword.get(opts, :attempt_id)

    coordination = %{
      enqueue:
        Keyword.get(opts, :coordination_enqueuer, fn key, operation, enqueue_opts ->
          CoordinationTasks.enqueue(key, operation, CoordinationTasks, enqueue_opts)
        end),
      run:
        Keyword.get(opts, :coordination_runner, fn key, operation, run_opts ->
          CoordinationTasks.run(key, operation, CoordinationTasks, run_opts)
        end),
      declare_dependency: Keyword.get(opts, :dependency_declarer, &IssueDependencies.declare/2),
      unblock_dependency: Keyword.get(opts, :dependency_unblocker, &IssueDependencies.unblock/2),
      dependency_present: Keyword.get(opts, :dependency_present, &IssueDependencies.declared?/2),
      subscribe_blocker: Keyword.get(opts, :blocker_subscriber, &Orchestrator.subscribe_for_declared_blocker/2),
      unsubscribe_blocker: Keyword.get(opts, :blocker_unsubscriber, &Orchestrator.unsubscribe_for_declared_blocker/2),
      # `aiur_set_ticket_state` (#2805) re-reads the issue and makes the target the sole `agent:*` state label —
      # Agents need not guess the label to remove.
      set_ticket_state: Keyword.get(opts, :ticket_state_writer, &TicketTransition.write_state(&1, &2, writer: :agent_tool)),
      ci_wait_pr_fetcher: Keyword.get(opts, :ci_wait_pr_fetcher, &Aiur.CodeHost.fetch_open_pull_request_for_branch/1)
    }

    event_handlers = %{
      decision_requester: Keyword.get(opts, :decision_requester, &Commands.request/2),
      decision_lifecycle_recorder: Keyword.get(opts, :decision_lifecycle_recorder, &Commands.agent_lifecycle/3),
      attention_enricher: Keyword.get(opts, :attention_enricher, &Commands.enrich_attention/2),
      attention_opener: Keyword.get(opts, :attention_opener, &Commands.open_attention_with_decision/6),
      attention_resolver: Keyword.get(opts, :attention_resolver, &Commands.resolve_attention/2)
    }

    event_context = %{
      app_session: app_session,
      attempt_id: attempt_id,
      event_handlers: event_handlers,
      dependency_declarer: coordination.declare_dependency,
      dependency_subscriber: coordination.subscribe_blocker,
      enqueue: coordination.enqueue,
      run: coordination.run,
      issue: issue,
      ticket_state_writer:
        Keyword.get(opts, :dependency_state_writer, fn issue_id, state_name ->
          TicketTransition.write_state(issue_id, state_name, writer: :agent_tool, identifier: ToolCoordination.issue_identifier(issue))
        end),
      publish: Keyword.get(opts, :event_bus_publisher, &Events.publish/3),
      publication_recorder:
        Keyword.get(opts, :event_publication_recorder, fn record ->
          EventPublicationLog.write(workspace, record)
        end),
      worker_host: worker_host,
      workspace: workspace
    }

    fn tool, arguments ->
      Dispatch.execute(
        tool,
        arguments,
        alert_emitter: fn name, message, reason, needs_attention, severity ->
          # Agent-emitted alerts are always per-ticket — namespace under
          # `ticket.<id>.agent.<name>` so subscribers can bind by ticket
          # (and so the alert log lines a single ticket together).
          # Names that already start with `ticket.` or `system.` pass
          # through unchanged so orchestrator-side callsites (which
          # pre-build the full topic) aren't double-prefixed.
          topic = ToolEvents.prefix_with_ticket_namespace(name, issue)

          Signal.agent_alert(topic, message,
            issue: issue,
            workspace: workspace,
            worker_host: worker_host,
            reason: reason,
            needs_attention: needs_attention,
            severity: severity,
            observation_identity: Issue.tracker_identity(issue),
            observation_source: %{kind: :agent_alert, name: name},
            observation_provenance: DecisionAttention.observation_provenance(app_session, attempt_id),
            occurred_at: DateTime.utc_now()
          )
        end,
        event_publisher: fn name, message, payload ->
          ToolEvents.emit_agent_event(event_context, name, message, payload)
        end,
        subscriber: fn pattern -> ToolCoordination.subscribe_for_issue(issue, pattern) end,
        unsubscriber: fn pattern -> ToolCoordination.unsubscribe_for_issue(issue, pattern) end,
        blocker_declarer: fn blocker_number ->
          ToolCoordination.declare_blocker_for_issue(issue, blocker_number, coordination)
        end,
        unblocker: fn blocker_number ->
          ToolCoordination.unblock_for_issue(issue, blocker_number, coordination)
        end,
        feature_writer: fn args -> FeatureWriter.write(issue, args, Keyword.get(opts, :feature_opts, [])) end,
        epic_setter: fn args -> EpicSetter.set(issue, args, Keyword.get(opts, :epic_opts, [])) end,
        ticket_state_setter: fn state_name, review_findings ->
          TicketStateSetter.write(
            issue,
            state_name,
            coordination,
            workspace,
            worker_host,
            Keyword.put(opts, :review_findings, review_findings),
            &ToolCoordination.ticket_coordination_key/1,
            &ToolCoordination.coordination_operation_opts/1
          )
        end
      )
    end
  end

  defp restore_invocation(:unset), do: Process.delete(@invocation_key)
  defp restore_invocation(value), do: Process.put(@invocation_key, value)
end
