defmodule Aiur.AgentRunner.ToolExecutor do
  @moduledoc """
  Binds dynamic tool execution to an agent issue and worker context.

  The executor namespaces alerts and events, manages subscriptions, and keeps
  blocker declaration immediately subscribed for prompt resume behavior.
  """

  require Logger

  alias Aiur.AgentRunner.SessionLifecycle

  alias Aiur.{
    Alerts,
    Boot,
    CodingAgent,
    CoordinationTasks,
    DecisionAttention,
    DecisionStore,
    EventPublicationLog,
    HardwareVerification,
    Issue,
    Tracker
  }

  alias Aiur.Codex.DynamicTool
  alias Aiur.Events.{Publisher, SubscriptionStore}
  alias Aiur.GitHub.{Config, IssueDependencies}
  alias Aiur.Orchestrator
  alias Aiur.Protocol.MapAccess
  alias Aiur.SecretRedactor

  @invocation_key {__MODULE__, :invocation_id}
  @max_failure_chars 500

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
      run: coordination.run,
      issue: issue,
      publish: Keyword.get(opts, :event_bus_publisher, &Publisher.publish/3),
      publication_recorder:
        Keyword.get(opts, :event_publication_recorder, fn record ->
          EventPublicationLog.write(workspace, record)
        end),
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
        untestable_reporter: fn criterion, reason ->
          report_untestable(event_context, criterion, reason)
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
          ticket_coordination_key(issue),
          fn -> declare_and_reconcile(current, blocker_number, coordination) end,
          coordination_operation_opts(issue)
        )
    end
  end

  defp unblock_for_issue(issue, blocker_number, coordination) do
    case issue_number_of(issue) do
      nil ->
        {:error, :no_issue_number}

      current ->
        coordination.run.(
          ticket_coordination_key(issue),
          fn -> coordination.unblock_dependency.(current, blocker_number) end,
          coordination_operation_opts(issue)
        )
    end
  end

  defp ticket_coordination_key(issue), do: {:ticket, issue_identifier(issue) || issue_number_of(issue)}

  defp coordination_operation_opts(issue) do
    [
      operation_timeout: :infinity,
      log_context: %{
        issue_id: Map.get(issue, :id),
        issue_identifier: Map.get(issue, :identifier)
      }
    ]
  end

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
         %{app_session: app_session, event_handlers: handlers, issue: issue} = context,
         "decision.requested",
         message,
         payload
       ) do
    case MapAccess.get(payload, :attention_slug) do
      slug when is_binary(slug) ->
        context.run.(
          ticket_coordination_key(issue),
          fn -> request_decision(issue, app_session, handlers, message, payload) end,
          coordination_operation_opts(issue)
        )

      _uncorrelated_or_invalid ->
        request_decision(issue, app_session, handlers, message, payload)
    end
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

  defp report_untestable(%{issue: issue} = event_context, criterion, reason) do
    prefix = Config.label_prefix()
    required_label = HardwareVerification.required_label(prefix)
    identifier = issue_identifier(issue)
    issue_id = to_string(Map.get(issue, :id) || identifier)
    message = "Unverifiable criterion: #{criterion}"

    with :ok <- HardwareVerification.invalidate_operator_signoff(issue_id, prefix),
         :ok <- Tracker.add_label(issue_id, required_label),
         :ok <-
           Alerts.emit_custom("ticket.#{identifier}.agent.hardware.untestable", message,
             issue: issue,
             workspace: event_context.workspace,
             worker_host: event_context.worker_host,
             reason: reason,
             needs_attention: true,
             severity: "warning",
             observation_identity: Issue.tracker_identity(issue),
             observation_source: %{kind: :agent_hardware_untestable},
             observation_provenance: observation_provenance(event_context.app_session, event_context.attempt_id),
             occurred_at: DateTime.utc_now()
           ) do
      _ =
        emit_agent_event(
          event_context,
          "custom.hardware-untestable",
          message,
          %{"criterion" => criterion, "reason" => reason, "required_label" => required_label}
        )

      :ok
    else
      {:error, reason} -> {:error, {:operator_verification_mark_failed, reason}}
      other -> {:error, {:operator_verification_mark_failed, other}}
    end
  end

  defp enqueue_agent_event(context, name, message, payload, identifier, topic) do
    event_payload =
      payload
      |> Map.put(:source, :agent)
      |> Map.put("message", message)
      |> Map.put("name", name)
      |> Map.put("issue", identifier)

    %{app_session: app_session, attempt_id: attempt_id, event_handlers: handlers, issue: issue} = context
    source = trusted_source(app_session)
    provenance = observation_provenance(app_session, attempt_id)
    occurred_at = DateTime.utc_now()
    tool_call_id = stringify_invocation_id(invocation_id())

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

      publish_opts = [
        identity: Issue.tracker_identity(issue),
        observation_source: %{kind: :agent_event, name: name},
        observation_provenance: provenance,
        occurred_at: occurred_at
      ]

      case safe_publish(context.publish, topic, event_payload, publish_opts) do
        {:ok, id} ->
          record_completed_publication(context, issue, tool_call_id, topic, id, name, payload, handlers)

        {:error, reason} ->
          failure = safe_failure_detail(reason)
          _ = record_event_publication(context.publication_recorder, :failed, issue, tool_call_id, topic, nil, failure)
          {:error, {:event_publication_failed, failure}}
      end
    end

    case context.enqueue.(ticket_coordination_key(issue), operation, coordination_operation_opts(issue)) do
      :pending -> {:ok, %{"status" => "pending", "topic" => topic}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp record_completed_publication(context, issue, tool_call_id, topic, event_id, name, payload, handlers) do
    _ = sync_decision_resolution(issue, name, payload, handlers.attention_resolver)

    record_event_publication(
      context.publication_recorder,
      :completed,
      issue,
      tool_call_id,
      topic,
      event_id
    )
  end

  defp safe_publish(publisher, topic, payload, opts) do
    case publisher.(topic, payload, opts) do
      {:ok, id, _subscribers} -> {:ok, id}
      result -> {:error, {:publisher_returned, result}}
    end
  rescue
    error -> {:error, {:publisher_exception, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:publisher_failure, kind, reason}}
  end

  defp durable_decision_topic?(topic) do
    Enum.any?(["decision.requested", "decision.acknowledged", "decision.resolved"], &String.ends_with?(topic, &1))
  end

  defp record_event_publication(recorder, status, issue, tool_call_id, topic, event_id, reason \\ nil) do
    log_context = event_publication_log_context(issue, tool_call_id, topic)

    record = %{
      event: "event_publication_#{status}",
      event_id: event_id,
      issue_id: Map.get(issue, :id),
      issue_identifier: Map.get(issue, :identifier),
      issue_number: issue_number_of(issue),
      reason: reason,
      timestamp: DateTime.utc_now(),
      tool_call_id: tool_call_id,
      topic: topic
    }

    case recorder.(record) do
      :ok ->
        :ok

      {:error, reason} ->
        failure = safe_failure_detail(reason)

        Logger.warning(
          "aiur_tool_executor phase=event_publication_record_failed " <>
            "#{log_context} failure=#{failure}"
        )

        {:error, {:event_publication_record_failed, failure}}

      other ->
        failure = safe_failure_detail({:unexpected_result, other})

        Logger.warning(
          "aiur_tool_executor phase=event_publication_record_failed " <>
            "#{log_context} failure=#{failure}"
        )

        {:error, {:event_publication_record_failed, failure}}
    end
  rescue
    error ->
      failure = safe_failure_detail({:exception, Exception.message(error)})

      Logger.warning(
        "aiur_tool_executor phase=event_publication_record_failed " <>
          "#{event_publication_log_context(issue, tool_call_id, topic)} " <>
          "failure=#{failure}"
      )

      {:error, {:event_publication_record_failed, failure}}
  catch
    kind, reason ->
      failure = safe_failure_detail({kind, reason})

      Logger.warning(
        "aiur_tool_executor phase=event_publication_record_failed " <>
          "#{event_publication_log_context(issue, tool_call_id, topic)} " <>
          "failure=#{failure}"
      )

      {:error, {:event_publication_record_failed, failure}}
  end

  defp event_publication_log_context(issue, tool_call_id, topic) do
    ticket = issue_identifier(issue)

    "key=#{safe_failure_detail(ticket_coordination_key(issue))} ticket=#{safe_failure_detail(ticket)} " <>
      "issue_id=#{safe_failure_detail(Map.get(issue, :id))} " <>
      "issue_identifier=#{safe_failure_detail(Map.get(issue, :identifier))} " <>
      "tool_call_id=#{safe_failure_detail(tool_call_id)} topic=#{safe_failure_detail(topic)} timeout_ms=infinity"
  end

  defp safe_failure_detail(reason) do
    SecretRedactor.safe_inspect(reason, @max_failure_chars)
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
