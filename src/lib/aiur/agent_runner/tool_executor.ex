defmodule Aiur.AgentRunner.ToolExecutor do
  @moduledoc """
  Binds dynamic tool execution to an agent issue and worker context.

  The executor namespaces alerts and events, manages subscriptions, and keeps
  blocker declaration immediately subscribed for prompt resume behavior.
  """

  alias Aiur.{Alerts, DecisionAttention, DecisionStore, Issue}
  alias Aiur.AgentRunner.SessionLifecycle
  alias Aiur.Codex.DynamicTool
  alias Aiur.Events.{Publisher, SubscriptionStore}
  alias Aiur.GitHub.IssueDependencies
  alias Aiur.Orchestrator

  @spec build(Issue.t(), Path.t() | nil, String.t() | nil, map()) :: (String.t(), map() -> map())
  def build(issue, workspace, worker_host, app_session \\ %{}) do
    fn tool, arguments ->
      DynamicTool.execute(
        tool,
        arguments,
        alert_emitter: fn name, message, reason, needs_attention, severity ->
          # Agent-emitted alerts are always per-ticket — namespace under
          # `ticket.<id>.agent.<name>` so subscribers can bind by ticket
          # (and so the alert log lines a single ticket together).
          # Names that already start with `ticket.` or `system.` pass
          # through unchanged so orchestrator-side callsites (which
          # pre-build the full topic) aren't double-prefixed.
          topic = prefix_with_ticket_namespace(name, issue)

          Alerts.emit_custom(topic, message,
            issue: issue,
            workspace: workspace,
            worker_host: worker_host,
            reason: reason,
            needs_attention: needs_attention,
            severity: severity
          )
        end,
        event_publisher: fn name, message, payload ->
          emit_agent_event(issue, workspace, worker_host, app_session, name, message, payload)
        end,
        subscriber: fn pattern -> subscribe_for_issue(issue, pattern) end,
        unsubscriber: fn pattern -> unsubscribe_for_issue(issue, pattern) end,
        blocker_declarer: fn blocker_number ->
          declare_blocker_for_issue(issue, blocker_number)
        end,
        unblocker: fn blocker_number ->
          unblock_for_issue(issue, blocker_number)
        end
      )
    end
  end

  defp prefix_with_ticket_namespace(name, issue) when is_binary(name) do
    cond do
      String.starts_with?(name, "ticket.") ->
        name

      String.starts_with?(name, "system.") ->
        name

      true ->
        case issue_identifier(issue) do
          id when is_binary(id) and id != "" -> "ticket.#{id}.agent.#{name}"
          _ -> name
        end
    end
  end

  defp prefix_with_ticket_namespace(name, _issue), do: name

  defp declare_blocker_for_issue(issue, blocker_number) do
    case issue_number_of(issue) do
      nil ->
        {:error, :no_issue_number}

      current ->
        result = IssueDependencies.declare(current, blocker_number)

        # Add the SubscriptionStore subscription IMMEDIATELY on a
        # successful (or `:already_present`) declare, instead of
        # waiting for the orchestrator's poll-driven
        # `auto_subscribe_for_dependency`. GitHub state can lag, drop,
        # or already-present the dependency due to PR open/close
        # cycles; without the direct subscribe, the blockee's
        # SubscriptionStore never gets `ticket.<blocker>.branch.push`
        # and the blockee never auto-resumes. Idempotent.
        case result do
          {:ok, _} ->
            Orchestrator.subscribe_for_declared_blocker(current, blocker_number)
            result

          other ->
            other
        end
    end
  end

  defp unblock_for_issue(issue, blocker_number) do
    case issue_number_of(issue) do
      nil -> {:error, :no_issue_number}
      current -> IssueDependencies.unblock(current, blocker_number)
    end
  end

  defp issue_number_of(issue) do
    case Map.get(issue, :number) || Map.get(issue, :identifier) do
      n when is_integer(n) -> n
      n when is_binary(n) -> n
      _ -> nil
    end
  end

  defp subscribe_for_issue(issue, pattern) do
    case issue_identifier(issue) do
      nil ->
        {:error, :no_issue_identifier}

      id ->
        :ok = SubscriptionStore.attach(id)
        SubscriptionStore.add_subscription(id, pattern, "manual:agent")
    end
  end

  defp unsubscribe_for_issue(issue, pattern) do
    case issue_identifier(issue) do
      nil -> {:error, :no_issue_identifier}
      id -> SubscriptionStore.remove_subscription(id, pattern)
    end
  end

  defp issue_identifier(issue) do
    cond do
      is_binary(Map.get(issue, :id)) -> issue.id
      is_binary(Map.get(issue, :identifier)) -> issue.identifier
      true -> nil
    end
  end

  # The only structured request routed through the durable DecisionStore
  # service — everything else keeps the existing generic publish path
  # below unchanged. `Publisher.publish/3` itself also rejects this topic
  # family, so this is the sole production ingress, not just a preference.
  defp emit_agent_event(issue, _workspace, _worker_host, app_session, "decision.requested", message, payload) do
    request_decision(issue, app_session, message, payload)
  end

  defp emit_agent_event(issue, workspace, worker_host, _app_session, name, message, payload) do
    identifier = issue_identifier(issue)

    topic =
      case identifier do
        nil -> "agent.#{name}"
        id -> "ticket.#{id}.agent.#{name}"
      end

    event_payload =
      payload
      |> Map.put("message", message)
      |> Map.put("name", name)
      |> Map.put("issue", identifier)

    case Publisher.publish(topic, event_payload) do
      {:ok, id, _subscribers} ->
        sync_decision_attention(issue, workspace, worker_host, name, message, payload)
        {:ok, %{"id" => id, "topic" => topic}}

      :filtered ->
        {:error, :event_filtered}

      :deduped ->
        {:error, :event_deduped}
    end
  end

  defp request_decision(issue, app_session, message, payload) do
    case issue_identifier(issue) do
      nil ->
        {:error, :no_issue_identifier}

      identifier ->
        ticket = %{identifier: identifier, title: Map.get(issue, :title), url: Map.get(issue, :url)}

        source = %{
          agent_id: SessionLifecycle.session_backend(app_session),
          session_id: Map.get(app_session, :thread_id),
          event_id: nil
        }

        request_payload = Map.put_new(payload, "question", message)

        case DecisionStore.request(request_payload, ticket: ticket, source: source) do
          {:ok, %{status: status, decision: decision}} ->
            {:ok,
             %{
               "decision_id" => decision.decision_id,
               "version" => decision.version,
               "status" => Atom.to_string(status)
             }}

          {:error, reason} ->
            {:error, {:decision_rejected, reason}}
        end
    end
  end

  defp sync_decision_attention(issue, _workspace, _worker_host, "attention.resolved", _message, payload) do
    case Map.get(payload, "slug") do
      slug when is_binary(slug) -> DecisionAttention.resolve(issue, slug)
      _ -> :ok
    end
  end

  defp sync_decision_attention(issue, workspace, worker_host, "attention." <> slug, message, _payload) do
    DecisionAttention.open(issue, workspace, worker_host, slug, message)
  end

  defp sync_decision_attention(issue, workspace, worker_host, name, message, payload) when name in ["blocked", "pause.request"] do
    case operator_decision_question(message, payload) do
      nil -> :ok
      question -> DecisionAttention.open(issue, workspace, worker_host, "operator-decision", question)
    end
  end

  defp sync_decision_attention(_issue, _workspace, _worker_host, _name, _message, _payload), do: :ok

  defp operator_decision_question(message, payload) do
    if Map.get(payload, "reason") in ["operator_decision", "operator-decision"] do
      case Map.get(payload, "question") do
        question when is_binary(question) and question != "" -> question
        _ -> message
      end
    end
  end
end
