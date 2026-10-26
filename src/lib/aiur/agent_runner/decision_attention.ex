defmodule Aiur.AgentRunner.DecisionAttention do
  @moduledoc false

  require Logger
  alias Aiur.AgentRunner.{DecisionLifecycleFailureAlert, SessionLifecycle, ToolCoordination, ToolExecutor}
  alias Aiur.{Boot, CodingAgent, Commands}
  alias Aiur.Protocol.MapAccess

  @spec request_decision(map(), map(), map(), String.t(), map()) :: term()
  def request_decision(issue, app_session, handlers, message, payload) do
    case ToolCoordination.issue_identifier(issue) do
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
        case Commands.attention_correlation(issue, slug) do
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

  @spec record_decision_lifecycle(map(), map(), fun(), String.t(), String.t(), map()) :: term()
  def record_decision_lifecycle(issue, app_session, lifecycle_recorder, name, message, payload) do
    case ToolCoordination.issue_identifier(issue) do
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
            DecisionLifecycleFailureAlert.recording_failed(issue, payload, name, reason)
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
        agent_id: stringify_identity(SessionLifecycle.session_backend_label(app_session)),
        session_id: stringify_identity(Map.get(app_session, :thread_id)),
        invocation_id: stringify_invocation_id(ToolExecutor.invocation_id())
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
      ToolExecutor.invocation_id() || {:request_payload, request_payload}
    }

    "tool_" <> digest_term(material, 32)
  end

  @spec stringify_invocation_id(term()) :: String.t() | nil
  def stringify_invocation_id(nil), do: nil
  def stringify_invocation_id(value) when is_binary(value), do: value
  def stringify_invocation_id(value) when is_integer(value), do: Integer.to_string(value)

  def stringify_invocation_id(value) do
    "opaque_" <> digest_term(value, 24)
  end

  defp digest_term(value, length) do
    value
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> String.slice(0, length)
  end

  @spec prepare_decision_attention(map(), Path.t() | nil, String.t() | nil, map(), fun(), String.t(), String.t(), map()) :: term()
  def prepare_decision_attention(
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

  def prepare_decision_attention(
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

  def prepare_decision_attention(issue, workspace, worker_host, source, opener, name, message, payload)
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

  def prepare_decision_attention(
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

  @spec sync_decision_resolution(map(), String.t(), map(), fun()) :: term()
  def sync_decision_resolution(issue, "attention.resolved", payload, resolver) do
    case MapAccess.get(payload, :slug) do
      slug when is_binary(slug) -> safely_resolve_attention(resolver, issue, slug)
      _ -> :ok
    end
  end

  def sync_decision_resolution(_issue, _name, _payload, _resolver), do: :ok

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
        "issue=#{inspect(ToolCoordination.issue_identifier(issue))} slug=#{inspect(slug)} reason=#{inspect(reason)}"
    )

    :ok
  end

  @spec trusted_source(map()) :: map()
  def trusted_source(app_session) do
    %{
      agent_id: SessionLifecycle.session_backend_label(app_session),
      session_id: Map.get(app_session, :thread_id),
      event_id: stringify_invocation_id(ToolExecutor.invocation_id())
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

  @spec observation_provenance(map(), term()) :: map()
  def observation_provenance(app_session, attempt_id) do
    %{
      run_id: Boot.run_id(),
      attempt: attempt_id,
      session_id: Map.get(app_session, :thread_id),
      source_event_id: stringify_invocation_id(ToolExecutor.invocation_id())
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
