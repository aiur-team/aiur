defmodule Aiur.AgentRunner.ToolExecutor do
  @moduledoc """
  Binds dynamic tool execution to an agent issue and worker context.

  The executor namespaces alerts and events, manages subscriptions, and keeps
  blocker declaration immediately subscribed for prompt resume behavior.
  """

  alias Aiur.AgentRunner.SessionLifecycle
  alias Aiur.{Alerts, DecisionAttention, DecisionStore, Issue}
  alias Aiur.Codex.DynamicTool
  alias Aiur.Events.{Publisher, SubscriptionStore}
  alias Aiur.GitHub.IssueDependencies
  alias Aiur.Orchestrator

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
    decision_requester = Keyword.get(opts, :decision_requester, &DecisionStore.request/2)

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
          emit_agent_event(issue, workspace, worker_host, app_session, decision_requester, name, message, payload)
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
  defp emit_agent_event(issue, _workspace, _worker_host, app_session, decision_requester, "decision.requested", message, payload) do
    request_decision(issue, app_session, decision_requester, message, payload)
  end

  defp emit_agent_event(issue, workspace, worker_host, _app_session, _decision_requester, name, message, payload) do
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

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp request_decision(issue, app_session, decision_requester, message, payload) do
    case issue_identifier(issue) do
      nil ->
        {:error, :no_issue_identifier}

      identifier ->
        ticket = %{identifier: identifier, title: Map.get(issue, :title), url: Map.get(issue, :url)}

        request_payload =
          payload
          |> Map.put_new("question", message)
          |> Map.delete(:source_id)
          |> Map.delete("source_id")

        source_id = trusted_source_id(identifier, app_session, request_payload)

        source = %{
          agent_id: SessionLifecycle.session_backend(app_session),
          session_id: Map.get(app_session, :thread_id),
          event_id: stringify_invocation_id(invocation_id())
        }

        request_payload = Map.put(request_payload, "source_id", source_id)

        case safely_request_decision(decision_requester, request_payload, ticket: ticket, source: source) do
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

  defp safely_request_decision(decision_requester, payload, opts) do
    decision_requester.(payload, opts)
  catch
    :exit, reason -> {:error, {:decision_store_exit, reason}}
  end

  defp trusted_source_id(identifier, app_session, request_payload) do
    material = {
      identifier,
      Map.get(app_session, :thread_id),
      invocation_id() || {:request_payload, request_payload}
    }

    "tool_" <> digest_term(material, 32)
  end

  defp stringify_invocation_id(nil), do: nil
  defp stringify_invocation_id(value) when is_binary(value), do: value
  defp stringify_invocation_id(value) when is_integer(value), do: Integer.to_string(value)

  defp stringify_invocation_id(value) do
    "opaque_" <> digest_term(value, 24)
  end

  defp digest_term(value, length) do
    value
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> String.slice(0, length)
  end

  defp restore_invocation(:unset), do: Process.delete(@invocation_key)
  defp restore_invocation(value), do: Process.put(@invocation_key, value)

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
