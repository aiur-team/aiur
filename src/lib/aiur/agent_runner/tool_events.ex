defmodule Aiur.AgentRunner.ToolEvents do
  @moduledoc false

  require Logger
  alias Aiur.AgentRunner.{DecisionAttention, ToolCoordination, ToolExecutor}
  alias Aiur.AgentTools.EmitEvent
  alias Aiur.Issue
  alias Aiur.Protocol.MapAccess
  alias Aiur.SecretRedactor
  @max_failure_chars 500

  @spec prefix_with_ticket_namespace(term(), map()) :: term()
  def prefix_with_ticket_namespace(name, issue) when is_binary(name) do
    cond do
      String.starts_with?(name, "ticket.") ->
        name

      String.starts_with?(name, "system.") ->
        name

      true ->
        case ToolCoordination.issue_identifier(issue) do
          id when is_binary(id) and id != "" -> "ticket.#{id}.agent.#{name}"
          _ -> name
        end
    end
  end

  def prefix_with_ticket_namespace(name, _issue), do: name

  # The only structured request routed through the durable DecisionStore
  # service — everything else keeps the existing generic publish path
  # below unchanged. `Events.publish/3` itself also rejects this topic
  # family, so this is the sole production ingress, not just a preference.
  @spec emit_agent_event(map(), String.t(), String.t(), map()) :: term()
  def emit_agent_event(
        %{app_session: app_session, event_handlers: handlers, issue: issue} = context,
        "decision.requested",
        message,
        payload
      ) do
    case MapAccess.get(payload, :attention_slug) do
      slug when is_binary(slug) ->
        context.run.(
          ToolCoordination.ticket_coordination_key(issue),
          fn -> DecisionAttention.request_decision(issue, app_session, handlers, message, payload) end,
          ToolCoordination.coordination_operation_opts(issue)
        )

      _uncorrelated_or_invalid ->
        DecisionAttention.request_decision(issue, app_session, handlers, message, payload)
    end
  end

  def emit_agent_event(
        %{app_session: app_session, event_handlers: handlers, issue: issue},
        name,
        message,
        payload
      )
      when name in ["decision.acknowledged", "decision.resolved"] do
    DecisionAttention.record_decision_lifecycle(issue, app_session, handlers.decision_lifecycle_recorder, name, message, payload)
  end

  def emit_agent_event(event_context, name, message, payload) do
    %{issue: issue} = event_context
    identifier = ToolCoordination.issue_identifier(issue)

    topic = EmitEvent.topic(identifier, name)

    if durable_decision_topic?(topic) do
      {:error, :decision_requires_durable_publish}
    else
      case prepare_dependency_pause(event_context, name, message, payload) do
        :ok ->
          enqueue_agent_event(event_context, name, message, payload, identifier, topic)

        {:ok, {prepared_message, prepared_payload}} ->
          enqueue_agent_event(event_context, name, prepared_message, prepared_payload, identifier, topic)

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp prepare_dependency_pause(_context, name, _message, _payload) when name != "pause.request", do: :ok

  defp prepare_dependency_pause(context, "pause.request", message, payload) do
    case MapAccess.get(payload, :reason) do
      reason when reason in ["dependency", :dependency] ->
        prepare_dependency_target(context, message, payload)

      _other ->
        :ok
    end
  end

  defp prepare_dependency_target(_context, _message, payload) when not is_map(payload), do: {:error, :invalid_pause_payload}

  defp prepare_dependency_target(context, message, payload) do
    case MapAccess.get(payload, :blocker_identifier) do
      nil ->
        {:error, :blocker_identifier_required}

      blocker_identifier ->
        case github_issue_number(blocker_identifier) do
          {:ok, blocker_number} ->
            prepare_ticket_dependency(context, blocker_number, message, payload)

          {:error, _reason} ->
            external_dependency_question(context, blocker_identifier, message, payload)
        end
    end
  end

  defp prepare_ticket_dependency(context, blocker_number, message, payload) do
    issue = context.issue
    current_number = ToolCoordination.issue_number_of(issue)

    with {:ok, current_number} <- github_issue_number(current_number),
         :ok <- declare_and_queue_dependency(context, current_number, blocker_number) do
      {:ok, {"Waiting for prerequisite ticket ##{blocker_number}: #{message}", payload}}
    end
  end

  defp external_dependency_question(context, blocker_identifier, message, payload) do
    prepared_payload = payload |> Map.put("reason", "operator_decision") |> Map.put("question", "Waiting for non-ticket prerequisite #{blocker_identifier}: #{message}")
    question = Map.get(prepared_payload, "question")

    case DecisionAttention.prepare_decision_attention(
           context.issue,
           context.workspace,
           context.worker_host,
           DecisionAttention.trusted_source(context.app_session),
           context.event_handlers.attention_opener,
           "pause.request",
           question,
           prepared_payload
         ) do
      {:ok, %{decision: %{decision_id: decision_id}}} when is_binary(decision_id) ->
        prepared_payload = Map.put(prepared_payload, "decision_id", decision_id)
        {:ok, {question, prepared_payload}}

      {:ok, %{decision: %{"decision_id" => decision_id}}} when is_binary(decision_id) ->
        prepared_payload = Map.put(prepared_payload, "decision_id", decision_id)
        {:ok, {question, prepared_payload}}

      {:error, reason} ->
        {:error, {:dependency_decision_required, reason}}

      _other ->
        {:error, :dependency_decision_id_unavailable}
    end
  end

  defp declare_and_queue_dependency(context, current_number, blocker_number) do
    issue = context.issue
    identifier = ToolCoordination.issue_identifier(issue)
    issue_id = Map.get(issue, :id) || to_string(current_number)

    context.run.(
      ToolCoordination.ticket_coordination_key(issue),
      fn ->
        declare_queue_dependency(context, current_number, blocker_number, identifier || to_string(current_number), issue_id)
      end,
      ToolCoordination.coordination_operation_opts(issue)
    )
  end

  defp declare_queue_dependency(context, current_number, blocker_number, identifier, issue_id) do
    case context.dependency_declarer.(current_number, blocker_number) do
      {:ok, _result} ->
        case context.dependency_subscriber.(identifier, blocker_number) do
          :ok -> context.ticket_state_writer.(to_string(issue_id), "todo")
          {:error, _reason} = error -> error
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp github_issue_number(number) when is_integer(number) and number > 0, do: {:ok, Integer.to_string(number)}

  defp github_issue_number(number) when is_binary(number) do
    case Integer.parse(number) do
      {parsed, ""} when parsed > 0 -> {:ok, Integer.to_string(parsed)}
      _ -> {:error, :blocker_must_be_github_issue_number}
    end
  end

  defp github_issue_number(_number), do: {:error, :blocker_must_be_github_issue_number}

  defp enqueue_agent_event(context, name, message, payload, identifier, topic) do
    event_payload =
      payload
      |> Map.put(:source, :agent)
      |> Map.put("message", message)
      |> Map.put("name", name)
      |> Map.put("issue", identifier)

    %{app_session: app_session, attempt_id: attempt_id, event_handlers: handlers, issue: issue} = context
    source = DecisionAttention.trusted_source(app_session)
    provenance = DecisionAttention.observation_provenance(app_session, attempt_id)
    occurred_at = DateTime.utc_now()
    tool_call_id = DecisionAttention.stringify_invocation_id(ToolExecutor.invocation_id())

    operation = fn ->
      decision_projection =
        DecisionAttention.prepare_decision_attention(
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
      event_payload = add_decision_id(event_payload, decision_projection)

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

    case context.enqueue.(ToolCoordination.ticket_coordination_key(issue), operation, ToolCoordination.coordination_operation_opts(issue)) do
      :pending -> {:ok, %{"status" => "pending", "topic" => topic}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp add_decision_id(event_payload, {:ok, %{decision: %{decision_id: decision_id}}}) when is_binary(decision_id),
    do: Map.put(event_payload, "decision_id", decision_id)

  defp add_decision_id(event_payload, {:ok, %{decision: %{"decision_id" => decision_id}}}) when is_binary(decision_id),
    do: Map.put(event_payload, "decision_id", decision_id)

  defp add_decision_id(event_payload, _projection), do: event_payload

  defp record_completed_publication(context, issue, tool_call_id, topic, event_id, name, payload, handlers) do
    _ = DecisionAttention.sync_decision_resolution(issue, name, payload, handlers.attention_resolver)

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
      issue_number: ToolCoordination.issue_number_of(issue),
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
    ticket = ToolCoordination.issue_identifier(issue)

    "key=#{safe_failure_detail(ToolCoordination.ticket_coordination_key(issue))} ticket=#{safe_failure_detail(ticket)} " <>
      "issue_id=#{safe_failure_detail(Map.get(issue, :id))} " <>
      "issue_identifier=#{safe_failure_detail(Map.get(issue, :identifier))} " <>
      "tool_call_id=#{safe_failure_detail(tool_call_id)} topic=#{safe_failure_detail(topic)} timeout_ms=infinity"
  end

  defp safe_failure_detail(reason) do
    SecretRedactor.safe_inspect(reason, @max_failure_chars)
  end

  defp log_decision_projection_failure({:error, reason}, topic) do
    Logger.warning(
      "aiur_tool_executor phase=decision_attention_projection_failed " <>
        "topic=#{inspect(topic)} reason=#{inspect(reason)}"
    )
  end

  defp log_decision_projection_failure({:ok, _result}, _topic), do: :ok
end
