defmodule Aiur.AgentRunner.ToolExecutor do
  @moduledoc """
  Binds dynamic tool execution to an agent issue and worker context.

  The executor namespaces alerts and events, manages subscriptions, and keeps
  blocker declaration immediately subscribed for prompt resume behavior.
  """

  require Logger

  alias Aiur.AgentRunner.SessionLifecycle
  alias Aiur.{Alerts, Boot, CodingAgent, CoordinationTasks, DecisionAttention, DecisionStore, Issue}
  alias Aiur.Codex.DynamicTool
  alias Aiur.Events.{Publisher, SubscriptionStore}
  alias Aiur.GitHub.IssueDependencies
  alias Aiur.Orchestrator
  alias Aiur.Protocol.MapAccess

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
      unsubscribe_blocker: Keyword.get(opts, :blocker_unsubscriber, &Orchestrator.unsubscribe_for_declared_blocker/2)
    }

    event_handlers = %{
      decision_requester: Keyword.get(opts, :decision_requester, &DecisionStore.request/2),
      decision_lifecycle_recorder: Keyword.get(opts, :decision_lifecycle_recorder, &DecisionStore.agent_lifecycle/3),
      attention_enricher: Keyword.get(opts, :attention_enricher, &DecisionStore.enrich_attention/2),
      attention_opener: Keyword.get(opts, :attention_opener, &DecisionAttention.open_with_decision/6),
      attention_resolver: Keyword.get(opts, :attention_resolver, &DecisionAttention.resolve/2)
    }

    event_context = %{
      app_session: app_session,
      attempt_id: attempt_id,
      event_handlers: event_handlers,
      enqueue: coordination.enqueue,
      issue: issue,
      worker_host: worker_host,
      workspace: workspace
    }

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
            severity: severity,
            observation_identity: Issue.tracker_identity(issue),
            observation_source: %{kind: :agent_alert, name: name},
            observation_provenance: observation_provenance(app_session, attempt_id),
            occurred_at: DateTime.utc_now()
          )
        end,
        event_publisher: fn name, message, payload ->
          emit_agent_event(event_context, name, message, payload)
        end,
        subscriber: fn pattern -> subscribe_for_issue(issue, pattern) end,
        unsubscriber: fn pattern -> unsubscribe_for_issue(issue, pattern) end,
        blocker_declarer: fn blocker_number ->
          declare_blocker_for_issue(issue, blocker_number, coordination)
        end,
        unblocker: fn blocker_number ->
          unblock_for_issue(issue, blocker_number, coordination)
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

  defp declare_blocker_for_issue(issue, blocker_number, coordination) do
    case issue_number_of(issue) do
      nil ->
        {:error, :no_issue_number}

      current ->
        admit(
          coordination.enqueue,
          dependency_key(current, blocker_number),
          fn -> declare_and_reconcile(current, blocker_number, coordination) end,
          operation_timeout: :infinity
        )
    end
  end

  defp unblock_for_issue(issue, blocker_number, coordination) do
    case issue_number_of(issue) do
      nil ->
        {:error, :no_issue_number}

      current ->
        coordination.run.(
          dependency_key(current, blocker_number),
          fn -> coordination.unblock_dependency.(current, blocker_number) end,
          operation_timeout: :infinity
        )
    end
  end

  defp dependency_key(current, blocker), do: {:dependency, current, blocker}

  defp admit(enqueue, key, operation, opts) do
    case enqueue.(key, operation, opts) do
      :pending -> {:ok, :pending}
      {:error, reason} -> {:error, reason}
    end
  end

  defp declare_and_reconcile(current, blocker, coordination) do
    case safe_coordination_call(coordination.subscribe_blocker, [current, blocker]) do
      :ok ->
        case safe_coordination_call(coordination.declare_dependency, [current, blocker]) do
          {:ok, _result} -> :ok
          {:error, reason} -> reconcile_declaration(current, blocker, reason, coordination)
          other -> reconcile_declaration(current, blocker, {:unexpected, other}, coordination)
        end

      {:error, reason} ->
        reconcile_subscription_failure(current, blocker, reason, coordination)

      other ->
        reconcile_subscription_failure(current, blocker, {:unexpected, other}, coordination)
    end
  end

  defp safe_coordination_call(function, arguments) do
    apply(function, arguments)
  rescue
    error -> {:error, {:coordination_call_error, Exception.message(error)}}
  catch
    :exit, reason -> {:error, {:coordination_call_exit, reason}}
  end

  defp reconcile_declaration(current, blocker, declaration_error, coordination) do
    coordination.dependency_present
    |> safe_coordination_call([current, blocker])
    |> reconcile_declaration_state(current, blocker, declaration_error, coordination)
  end

  defp reconcile_subscription_failure(current, blocker, subscription_error, coordination) do
    coordination.dependency_present
    |> safe_coordination_call([current, blocker])
    |> reconcile_subscription_state(current, blocker, subscription_error, coordination)
  end

  defp reconcile_declaration_state({:ok, true}, current, blocker, error, coordination) do
    result = safe_coordination_call(coordination.subscribe_blocker, [current, blocker])
    normalize_reconcile_result(result, :blocker_reconcile_subscription_failed, error)
  end

  defp reconcile_declaration_state({:ok, false}, current, blocker, error, coordination) do
    result = safe_coordination_call(coordination.unsubscribe_blocker, [current, blocker])
    normalize_cleanup_result(result, :blocker_declaration_failed, :blocker_declaration_cleanup_failed, error)
  end

  defp reconcile_declaration_state({:error, reason}, _current, _blocker, error, _coordination),
    do: {:error, {:blocker_reconcile_inconclusive, error, reason}}

  defp reconcile_subscription_state({:ok, true}, current, blocker, error, coordination) do
    result = safe_coordination_call(coordination.subscribe_blocker, [current, blocker])
    normalize_reconcile_result(result, :blocker_subscription_retry_failed, error)
  end

  defp reconcile_subscription_state({:ok, false}, current, blocker, error, coordination) do
    result = safe_coordination_call(coordination.unsubscribe_blocker, [current, blocker])
    normalize_cleanup_result(result, :blocker_subscription_failed, :blocker_subscription_cleanup_failed, error)
  end

  defp reconcile_subscription_state({:error, reason}, _current, _blocker, error, _coordination),
    do: {:error, {:blocker_subscription_reconcile_inconclusive, error, reason}}

  defp normalize_reconcile_result(:ok, _failure, _original_error), do: :ok

  defp normalize_reconcile_result({:error, reason}, failure, original_error),
    do: {:error, {failure, original_error, reason}}

  defp normalize_reconcile_result(other, failure, original_error),
    do: {:error, {failure, original_error, {:unexpected, other}}}

  defp normalize_cleanup_result(:ok, failure, _cleanup_failure, original_error),
    do: {:error, {failure, original_error}}

  defp normalize_cleanup_result({:error, reason}, _failure, cleanup_failure, original_error),
    do: {:error, {cleanup_failure, original_error, reason}}

  defp normalize_cleanup_result(other, _failure, cleanup_failure, original_error),
    do: {:error, {cleanup_failure, original_error, {:unexpected, other}}}

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
  defp emit_agent_event(
         %{app_session: app_session, event_handlers: handlers, issue: issue},
         "decision.requested",
         message,
         payload
       ) do
    request_decision(issue, app_session, handlers, message, payload)
  end

  defp emit_agent_event(
         %{app_session: app_session, event_handlers: handlers, issue: issue},
         name,
         message,
         payload
       )
       when name in ["decision.acknowledged", "decision.resolved"] do
    record_decision_lifecycle(issue, app_session, handlers.decision_lifecycle_recorder, name, message, payload)
  end

  defp emit_agent_event(event_context, name, message, payload) do
    %{issue: issue} = event_context
    identifier = issue_identifier(issue)

    topic =
      case identifier do
        nil -> "agent.#{name}"
        id -> "ticket.#{id}.agent.#{name}"
      end

    if durable_decision_topic?(topic) do
      {:error, :decision_requires_durable_publish}
    else
      enqueue_agent_event(event_context, name, message, payload, identifier, topic)
    end
  end

  defp enqueue_agent_event(context, name, message, payload, identifier, topic) do
    event_payload =
      payload
      |> Map.put("message", message)
      |> Map.put("name", name)
      |> Map.put("issue", identifier)

    %{app_session: app_session, attempt_id: attempt_id, event_handlers: handlers, issue: issue} = context
    source = trusted_source(app_session)
    provenance = observation_provenance(app_session, attempt_id)
    occurred_at = DateTime.utc_now()

    operation = fn ->
      decision_projection =
        prepare_decision_attention(
          context.issue,
          context.workspace,
          context.worker_host,
          source,
          handlers.attention_opener,
          name,
          message,
          payload
        )

      log_decision_projection_failure(decision_projection, topic)

      case Publisher.publish(
             topic,
             event_payload,
             identity: Issue.tracker_identity(issue),
             observation_source: %{kind: :agent_event, name: name},
             observation_provenance: provenance,
             occurred_at: occurred_at
           ) do
        {:ok, _id, _subscribers} ->
          sync_decision_resolution(issue, name, payload, handlers.attention_resolver)

        result ->
          Logger.error("coordination event publish failed topic=#{topic} reason=#{inspect(result)}")
      end
    end

    case context.enqueue.({:event, identifier}, operation, operation_timeout: :infinity) do
      :pending -> {:ok, %{"status" => "pending", "topic" => topic}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp durable_decision_topic?(topic) do
    Enum.any?(["decision.requested", "decision.acknowledged", "decision.resolved"], &String.ends_with?(topic, &1))
  end

  defp request_decision(issue, app_session, handlers, message, payload) do
    case issue_identifier(issue) do
      nil ->
        {:error, :no_issue_identifier}

      identifier ->
        ticket = %{identifier: identifier, title: Map.get(issue, :title), url: Map.get(issue, :url)}

        request_payload =
          payload
          |> Map.put_new("question", message)
          |> remove_untrusted_decision_identity()

        source = trusted_source(app_session)
        provenance = trusted_provenance(app_session)

        request_decision_by_correlation(
          issue,
          identifier,
          request_payload,
          ticket,
          source,
          provenance,
          handlers
        )
    end
  end

  defp request_decision_by_correlation(issue, identifier, request_payload, ticket, source, provenance, handlers) do
    case MapAccess.get(request_payload, :attention_slug) do
      nil ->
        payload =
          request_payload
          |> remove_attention_slug()
          |> Map.put("source_id", trusted_source_id(identifier, source.session_id, request_payload))

        request_and_format(handlers.decision_requester, payload, ticket: ticket, source: source, provenance: provenance)

      slug when is_binary(slug) ->
        case DecisionAttention.correlation(issue, slug) do
          {:ok, correlation} ->
            payload =
              request_payload
              |> remove_attention_slug()
              |> Map.put("source_id", correlation.source_id)

            request_and_format(handlers.attention_enricher, payload,
              ticket: ticket,
              source: source,
              legacy_attention: correlation.legacy_attention,
              provenance: provenance
            )

          {:error, reason} ->
            {:error, {:decision_rejected, reason}}
        end

      _invalid ->
        {:error, {:decision_rejected, {:legacy_attention_slug, :invalid_type}}}
    end
  end

  defp request_and_format(requester, payload, opts) do
    case safely_request_decision(requester, payload, opts) do
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

  defp safely_request_decision(decision_requester, payload, opts) do
    decision_requester.(payload, opts)
  catch
    :exit, reason -> {:error, {:decision_store_exit, reason}}
  end

  defp record_decision_lifecycle(issue, app_session, lifecycle_recorder, name, message, payload) do
    case issue_identifier(issue) do
      nil ->
        {:error, :no_issue_identifier}

      identifier ->
        type = if name == "decision.acknowledged", do: :acknowledged, else: :resolved
        lifecycle_payload = Map.put_new(payload, "detail", message)
        trusted_context = trusted_lifecycle_context(app_session)

        opts = [
          ticket_identifier: identifier,
          actor: trusted_context.actor,
          source: trusted_context.source
        ]

        case safely_record_lifecycle(lifecycle_recorder, type, lifecycle_payload, opts) do
          {:ok, result} ->
            {:ok,
             result
             |> Map.take([:decision_id, :version, :answered_version, :action_id, :status, :decision_status])
             |> Map.new(fn {key, value} -> {Atom.to_string(key), stringify_lifecycle_value(value)} end)}

          {:error, reason} ->
            {:error, {:decision_lifecycle_rejected, reason}}
        end
    end
  end

  defp safely_record_lifecycle(recorder, type, payload, opts) do
    recorder.(type, payload, opts)
  catch
    :exit, reason -> {:error, {:decision_store_exit, reason}}
  end

  defp trusted_lifecycle_context(app_session) do
    %{
      actor: %{kind: :agent, id: "ticket-agent"},
      source: %{
        agent_id: stringify_identity(SessionLifecycle.session_backend(app_session)),
        session_id: stringify_identity(Map.get(app_session, :thread_id)),
        invocation_id: stringify_invocation_id(invocation_id())
      }
    }
  end

  defp stringify_identity(nil), do: nil
  defp stringify_identity(value) when is_binary(value), do: value
  defp stringify_identity(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify_identity(value), do: stringify_invocation_id(value)

  defp stringify_lifecycle_value(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify_lifecycle_value(value), do: value

  defp trusted_source_id(identifier, session_id, request_payload) do
    material = {
      identifier,
      session_id,
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

  defp prepare_decision_attention(
         _issue,
         _workspace,
         _worker_host,
         _source,
         _opener,
         "attention.resolved",
         _message,
         _payload
       ) do
    {:ok, nil}
  end

  defp prepare_decision_attention(
         issue,
         workspace,
         worker_host,
         source,
         opener,
         "attention." <> slug,
         message,
         _payload
       ) do
    open_decision_attention(opener, issue, workspace, worker_host, slug, message, source)
  end

  defp prepare_decision_attention(issue, workspace, worker_host, source, opener, name, message, payload)
       when name in ["blocked", "pause.request"] do
    case operator_decision_question(message, payload) do
      nil ->
        {:ok, nil}

      question ->
        open_decision_attention(
          opener,
          issue,
          workspace,
          worker_host,
          "operator-decision",
          question,
          source
        )
    end
  end

  defp prepare_decision_attention(
         _issue,
         _workspace,
         _worker_host,
         _source,
         _opener,
         _name,
         _message,
         _payload
       ) do
    {:ok, nil}
  end

  defp open_decision_attention(opener, issue, workspace, worker_host, slug, question, source) do
    case safely_open_attention(opener, issue, workspace, worker_host, slug, question, source: source) do
      {:ok, result} -> {:ok, result}
      :ok -> {:ok, nil}
      {:error, reason} -> {:error, {:decision_rejected, reason}}
    end
  end

  defp safely_open_attention(opener, issue, workspace, worker_host, slug, question, opts) do
    opener.(issue, workspace, worker_host, slug, question, opts)
  catch
    :exit, reason -> {:error, {:decision_store_exit, reason}}
  end

  defp sync_decision_resolution(issue, "attention.resolved", payload, resolver) do
    case MapAccess.get(payload, :slug) do
      slug when is_binary(slug) -> safely_resolve_attention(resolver, issue, slug)
      _ -> :ok
    end
  end

  defp sync_decision_resolution(_issue, _name, _payload, _resolver), do: :ok

  defp safely_resolve_attention(resolver, issue, slug) do
    case resolver.(issue, slug) do
      :ok -> :ok
      {:error, reason} -> log_decision_resolution_failure(issue, slug, reason)
      other -> log_decision_resolution_failure(issue, slug, {:unexpected_result, other})
    end
  rescue
    error -> log_decision_resolution_failure(issue, slug, {:decision_attention_error, Exception.message(error)})
  catch
    :exit, reason -> log_decision_resolution_failure(issue, slug, {:decision_attention_exit, reason})
  end

  defp log_decision_resolution_failure(issue, slug, reason) do
    Logger.warning(
      "aiur_tool_executor phase=decision_attention_resolution_failed " <>
        "issue=#{inspect(issue_identifier(issue))} slug=#{inspect(slug)} reason=#{inspect(reason)}"
    )

    :ok
  end

  defp log_decision_projection_failure({:error, reason}, topic) do
    Logger.warning(
      "aiur_tool_executor phase=decision_attention_projection_failed " <>
        "topic=#{inspect(topic)} reason=#{inspect(reason)}"
    )
  end

  defp log_decision_projection_failure({:ok, _result}, _topic), do: :ok

  defp trusted_source(app_session) do
    %{
      agent_id: SessionLifecycle.session_backend(app_session),
      session_id: Map.get(app_session, :thread_id),
      event_id: stringify_invocation_id(invocation_id())
    }
  end

  # This is deliberately built from the runner-owned session, not from the
  # agent tool payload. `resolved_model` stays absent because the current
  # adapters do not expose an authoritative resolved-model fact.
  defp trusted_provenance(app_session) when is_map(app_session) do
    backend = Map.get(app_session, :backend)
    requested_model = Map.get(app_session, :model)
    session_id = Map.get(app_session, :thread_id)
    attempt_id = Map.get(app_session, :attempt_id)

    if Enum.any?([backend, requested_model, session_id, attempt_id], &is_binary/1) do
      %{
        agent_family: CodingAgent.family_for(backend),
        backend: backend,
        requested_model: requested_model,
        session_id: session_id,
        attempt_id: attempt_id,
        source: "agent_runner"
      }
    else
      nil
    end
  end

  defp observation_provenance(app_session, attempt_id) do
    %{
      run_id: Boot.run_id(),
      attempt: attempt_id,
      session_id: Map.get(app_session, :thread_id),
      source_event_id: stringify_invocation_id(invocation_id())
    }
  end

  defp remove_untrusted_decision_identity(payload) do
    Map.drop(payload, [
      :source_id,
      "source_id",
      :decision_id,
      "decision_id",
      :legacy_attention,
      "legacy_attention",
      :provenance,
      "provenance"
    ])
  end

  defp remove_attention_slug(payload), do: Map.drop(payload, [:attention_slug, "attention_slug"])

  defp operator_decision_question(message, payload) do
    if MapAccess.get(payload, :reason) in ["operator_decision", "operator-decision"] do
      case MapAccess.get(payload, :question) do
        question when is_binary(question) and question != "" -> question
        _ -> message
      end
    end
  end
end
