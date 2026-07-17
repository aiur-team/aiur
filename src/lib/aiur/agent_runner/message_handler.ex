defmodule Aiur.AgentRunner.MessageHandler do
  @moduledoc """
  Handles one normalized backend message for an agent turn.

  It writes the agent event log, fans messages out to transcript and turn-event
  subscribers, and reports worker state to the orchestrator recipient.
  """

  require Logger

  alias Aiur.{
    AgentEventLog,
    AgentEvents,
    AgentPubSub,
    CodingAgent,
    Issue,
    LiveConversation,
    ModelAvailability,
    TrackerIdentity
  }

  alias Aiur.AgentRunner.QueueDrain
  alias Aiur.Protocol.MapAccess
  alias Aiur.RunTelemetry.Lifecycle

  @spec build(pid() | nil, Issue.t(), Path.t() | nil, String.t() | nil, String.t(), String.t() | nil) :: (map() -> :ok)
  def build(recipient, issue, workspace, worker_host, backend, turn_id \\ nil) do
    build(recipient, issue, workspace, worker_host, backend, turn_id, [])
  end

  @doc false
  @spec build(pid() | nil, Issue.t(), Path.t() | nil, String.t() | nil, String.t(), String.t() | nil, keyword()) ::
          (map() -> :ok)
  def build(recipient, issue, workspace, worker_host, backend, turn_id, lifecycle_opts)
      when is_list(lifecycle_opts) do
    lifecycle_opts =
      if Lifecycle.enabled?(lifecycle_opts) do
        Keyword.put_new(lifecycle_opts, :tracker, make_ref())
      else
        lifecycle_opts
      end

    lifecycle_opts =
      lifecycle_opts
      |> Keyword.put(:backend, backend)
      |> Keyword.put_new(:live_conversation_recipient, recipient)

    activate_live_conversation(issue, backend, lifecycle_opts)

    fn message ->
      message = CodingAgent.normalize_event(message, backend)
      transcript_event = transcript_event_from(message, backend, turn_id)
      observe_lifecycle(issue, backend, message, lifecycle_opts)
      observe_rate_limits(backend, message, lifecycle_opts)
      AgentEventLog.write(workspace, worker_host, message)
      maybe_broadcast_transcript(issue, transcript_event)
      maybe_observe_live_conversation(issue, transcript_event, lifecycle_opts)
      maybe_broadcast_turn_event(issue, message, turn_id)
      send_codex_update(recipient, issue, message)
    end
  end

  defp observe_lifecycle(%Issue{identifier: identifier}, backend, message, lifecycle_opts)
       when is_binary(identifier) and is_list(lifecycle_opts) do
    Lifecycle.observe_backend_message(
      identifier,
      Keyword.get(lifecycle_opts, :attempt_id),
      backend,
      message,
      lifecycle_opts
    )
  end

  defp observe_lifecycle(_issue, _backend, _message, _lifecycle_opts), do: :ok

  defp observe_rate_limits(backend, %{rate_limits: limits}, lifecycle_opts) when is_map(limits) do
    observer = Keyword.get(lifecycle_opts, :rate_limit_observer, &ModelAvailability.observe/2)
    observer.(backend, limits)
  end

  defp observe_rate_limits(_backend, _message, _lifecycle_opts), do: :ok

  defp maybe_broadcast_transcript(%Issue{identifier: identifier}, {:ok, event})
       when is_binary(identifier) do
    AgentPubSub.broadcast_transcript(identifier, event)
  end

  defp maybe_broadcast_transcript(_issue, _transcript_event), do: :ok

  # This sits beside, rather than behind, the existing pane transcript. The
  # pane is intentionally rich (reasoning, commands, tool I/O); the dashboard
  # projection admits only its own conservative allowlist.
  defp maybe_observe_live_conversation(%Issue{} = issue, {:ok, event}, opts) do
    if display_tailer_authority?(opts) do
      :ok
    else
      backend = Keyword.get(opts, :backend)

      with_live_source(issue, backend, opts, :observe, fn source ->
        observe_live_event(issue, source, event, opts)
      end)
    end
  end

  defp maybe_observe_live_conversation(_issue, _transcript_event, _opts), do: :ok

  defp observe_live_event(issue, source, %{role: :tool} = event, opts) do
    case safe_tool_summary(event) do
      {:ok, summary} ->
        safe_live_conversation(issue, :observe_tool, opts, fn ->
          LiveConversation.observe_tool_summary(source, summary, live_conversation_opts(opts))
        end)

      :skip ->
        :ok
    end
  end

  # Codex does not expose a stable fragment identity for replayed deltas. Keep
  # rich partials in the pane transcript, but admit only the matching completed
  # message to the bounded public projection.
  defp observe_live_event(_issue, _source, %{kind: :assistant_delta}, _opts), do: :ok

  defp observe_live_event(issue, source, event, opts) do
    safe_live_conversation(issue, :observe, opts, fn ->
      LiveConversation.observe(source, event, live_conversation_opts(opts))
    end)
  end

  # The rich transcript event contains tool inputs, output and paths. Reduce
  # only completed result shapes to fixed prose before crossing the projection
  # boundary; no provider-controlled tool content is retained.
  defp safe_tool_summary(%{payload: payload, msg_id: msg_id} = event)
       when is_map(payload) and (is_binary(msg_id) or is_integer(msg_id)) do
    case safe_tool_outcome(payload, event) do
      nil ->
        :skip

      outcome ->
        {:ok,
         %{
           msg_id: msg_id,
           title: "Tool result",
           body: outcome,
           timestamp: Map.get(event, :timestamp)
         }}
    end
  end

  defp safe_tool_summary(_event), do: :skip

  defp safe_tool_outcome(%{tool: "result"}, %{body: "tool result (error)"}),
    do: "Tool reported an error"

  defp safe_tool_outcome(%{tool: "result"}, _event), do: "Tool completed"
  defp safe_tool_outcome(%{success: true}, _event), do: "Tool completed"
  defp safe_tool_outcome(%{success: false}, _event), do: "Tool reported an error"
  defp safe_tool_outcome(_payload, _event), do: nil

  @doc false
  @spec observe_operator_delivery(Issue.t(), map(), String.t(), keyword()) ::
          :ok | {:error, term()}
  def observe_operator_delivery(
        %Issue{} = issue,
        %{id: request_id, category: :operator_message} = item,
        backend,
        opts
      )
      when is_integer(request_id) and is_binary(backend) and is_list(opts) do
    text = QueueDrain.queue_item_text(item)

    with {:ok, opts} <- operator_delivery_opts(issue, opts) do
      observe_operator_text(issue, request_id, text, backend, opts)
    end
  end

  def observe_operator_delivery(_issue, _item, _backend, _opts), do: :ok

  defp observe_operator_text(issue, request_id, text, backend, opts) do
    if text != "" do
      with_live_source(issue, backend, opts, :observe_operator, fn source ->
        event = %{
          role: :user,
          msg_id: "operator:#{request_id}",
          body: text,
          timestamp: DateTime.utc_now(),
          payload: %{source: :operator_delivery}
        }

        safe_live_conversation(issue, :observe_operator, opts, fn ->
          LiveConversation.observe_operator_message(source, event, live_conversation_opts(opts))
        end)
      end)
    else
      :ok
    end
  end

  @doc false
  @spec observe_display_transcript(Issue.t(), map(), String.t(), keyword()) :: :ok
  def observe_display_transcript(
        %Issue{} = issue,
        %{role: :user, payload: %{origin: :remote}} = event,
        backend,
        opts
      )
      when is_binary(backend) and is_list(opts) do
    with_live_source(issue, backend, opts, :observe_remote_operator, fn source ->
      safe_live_conversation(issue, :observe_remote_operator, opts, fn ->
        LiveConversation.observe_operator_message(source, event, live_conversation_opts(opts))
      end)
    end)
  end

  def observe_display_transcript(%Issue{} = issue, %{role: role} = event, backend, opts)
      when role in [:assistant, :tool] and is_binary(backend) and is_list(opts) do
    with_live_source(issue, backend, opts, :observe_display, fn source ->
      observe_live_event(issue, source, event, opts)
    end)
  end

  def observe_display_transcript(_issue, _event, _backend, _opts), do: :ok

  @doc false
  @spec end_live_conversation(Issue.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def end_live_conversation(%Issue{} = issue, backend, opts) when is_binary(backend) and is_list(opts) do
    with_live_source(issue, backend, opts, :end_generation, fn source ->
      safe_live_conversation(issue, :end_generation, opts, fn ->
        LiveConversation.end_generation(source, live_conversation_opts(opts))
      end)
    end)
  end

  def end_live_conversation(_issue, _backend, _opts), do: :ok

  @doc false
  @spec finish_live_conversation(Issue.t(), String.t(), term(), keyword()) ::
          :ok | {:error, term()}
  def finish_live_conversation(issue, backend, {:error, _reason}, opts),
    do: mark_live_conversation_degraded(issue, backend, opts)

  def finish_live_conversation(issue, backend, _result, opts),
    do: end_live_conversation(issue, backend, opts)

  @doc false
  @spec mark_live_conversation_degraded(Issue.t(), String.t(), keyword()) ::
          :ok | {:error, term()}
  def mark_live_conversation_degraded(%Issue{} = issue, backend, opts)
      when is_binary(backend) and is_list(opts) do
    with_live_source(issue, backend, opts, :mark_degraded, fn source ->
      safe_live_conversation(issue, :mark_degraded, opts, fn ->
        LiveConversation.mark_degraded(source, live_conversation_opts(opts))
      end)
    end)
  end

  def mark_live_conversation_degraded(_issue, _backend, _opts), do: :ok

  defp maybe_broadcast_turn_event(%Issue{identifier: identifier}, message, turn_id)
       when is_binary(identifier) and is_binary(turn_id) do
    case event_kind(message) do
      kind when kind in ["turn_completed", "turn_failed", "turn_cancelled", "turn_input_required"] ->
        payload = %{turn_id: turn_id, payload: message}
        AgentPubSub.broadcast_turn_event(identifier, String.to_existing_atom(kind), payload)

      _ ->
        :ok
    end
  end

  defp maybe_broadcast_turn_event(_issue, _message, _turn_id), do: :ok

  # Dispatch to the active backend's transcript extractor (codex or
  # Claude). Falls back to the universal legacy event-kind mapping for
  # non-notification shapes (older agent_message / task_finished events).
  defp transcript_event_from(message, backend, turn_id) when is_map(message) do
    case CodingAgent.transcript_module(backend).extract(message, turn_id) do
      {:ok, event} -> {:ok, event}
      :skip -> legacy_transcript_event(message, turn_id)
    end
  end

  defp legacy_transcript_event(message, turn_id) do
    role = role_for_event(message)
    body = body_for_event(message)

    cond do
      is_nil(role) -> :skip
      is_nil(body) -> :skip
      body == "" -> :skip
      true -> {:ok, AgentEvents.transcript_event(role, body, timestamp: timestamp_for(message), turn_id: turn_id)}
    end
  end

  defp role_for_event(message) do
    case event_kind(message) do
      kind when kind in ["agent_message", "assistant_message", "task_finished", "task_complete"] ->
        :assistant

      kind when kind in ["user_message", "operator_message"] ->
        :user

      _ ->
        nil
    end
  end

  defp event_kind(message) do
    case get(message, :event) do
      nil -> nil
      atom when is_atom(atom) -> Atom.to_string(atom)
      other -> to_string(other)
    end
  end

  defp body_for_event(message) do
    get(message, :last_message) ||
      get(message, :body) ||
      nil
  end

  # Look up `key` in `map` using both atom and binary forms so we tolerate
  # either shape (`%{event: "..."}` or `%{"event" => "..."}`) — codex events
  # arrive as string-keyed JSON, while internal messages stay atom-keyed.
  defp get(map, key), do: MapAccess.get(map, key)

  defp timestamp_for(message) do
    case Map.get(message, :timestamp) || Map.get(message, "timestamp") do
      %DateTime{} = ts -> ts
      _ -> DateTime.utc_now()
    end
  end

  @doc false
  @spec activate_live_conversation(Issue.t(), String.t(), keyword()) ::
          :ok | {:error, term()}
  def activate_live_conversation(%Issue{} = issue, backend, opts)
      when is_binary(backend) and is_list(opts) do
    if Keyword.get(opts, :live_conversation_authority) == :display_tailer do
      :ok
    else
      with_live_source(issue, backend, opts, :activate, fn source ->
        safe_live_conversation(issue, :activate, opts, fn ->
          LiveConversation.activate(source, live_conversation_opts(opts))
        end)
      end)
    end
  end

  def activate_live_conversation(_issue, _backend, _opts),
    do: {:error, {:live_conversation_context, :invalid_arguments}}

  @doc false
  @spec replace_live_conversation_source(
          Issue.t(),
          String.t(),
          String.t() | nil,
          String.t() | nil,
          keyword()
        ) :: :ok | {:error, term()}
  def replace_live_conversation_source(issue, backend, prior_session, next_session, opts)
      when is_binary(backend) and is_list(opts) do
    if prior_session != next_session do
      _ = end_live_conversation(issue, backend, Keyword.put(opts, :session_id, prior_session))
    end

    opts =
      opts
      |> Keyword.put(:session_id, next_session)
      |> Keyword.delete(:live_conversation_authority)

    activate_live_conversation(issue, backend, opts)
  end

  @doc false
  @spec live_source(Issue.t(), String.t(), keyword()) ::
          {:ok, map()} | {:skip, atom()} | {:error, atom()}
  def live_source(%Issue{} = issue, backend, opts)
      when is_binary(backend) and is_list(opts) do
    with :ok <- live_projection_enabled(opts),
         :ok <- valid_live_backend(backend),
         {:ok, identity} <- live_identity(issue),
         :ok <- joinable_live_identity(identity),
         {:ok, generation} <- live_worker_generation(opts),
         {:ok, attempt_id} <- live_source_attempt(opts) do
      {:ok,
       %{
         identity: identity,
         attempt_id: attempt_id,
         session_id: Keyword.get(opts, :session_id),
         backend: backend,
         worker_generation: generation
       }}
    end
  end

  def live_source(_issue, _backend, _opts), do: {:error, :invalid_arguments}

  defp live_projection_enabled(opts) do
    case Keyword.get(opts, :live_conversation) do
      :disabled -> {:skip, :disabled}
      _enabled -> :ok
    end
  end

  defp valid_live_backend(""), do: {:error, :invalid_backend}
  defp valid_live_backend(_backend), do: :ok

  defp live_identity(issue) do
    case Issue.tracker_identity(issue) do
      %TrackerIdentity{} = identity -> {:ok, identity}
      _missing -> {:error, :missing_identity}
    end
  end

  defp joinable_live_identity(identity) do
    case TrackerIdentity.joinable?(identity) do
      true -> :ok
      false -> {:error, :unjoinable_identity}
    end
  end

  defp live_worker_generation(opts) do
    case Keyword.get(opts, :worker_generation) do
      generation when is_integer(generation) and generation > 0 -> {:ok, generation}
      _missing -> {:error, :missing_worker_generation}
    end
  end

  defp live_source_attempt(opts) do
    case live_attempt_id(opts) do
      nil -> {:error, :missing_attempt_id}
      attempt_id -> {:ok, attempt_id}
    end
  end

  defp live_attempt_id(opts),
    do: Keyword.get(opts, :attempt_id) || Keyword.get(opts, :telemetry_attempt_id)

  defp live_conversation_opts(opts) do
    case Keyword.get(opts, :live_conversation_server) do
      nil -> []
      server -> [server: server]
    end
  end

  defp with_live_source(issue, backend, opts, operation, fun) do
    case live_source(issue, backend, opts) do
      {:ok, source} ->
        fun.(source)

      {:skip, _reason} ->
        :ok

      {:error, reason} ->
        log_projection_failure(issue, operation, reason)
        publish_projection_failure(issue, opts, reason)
        {:error, {:live_conversation_context, reason}}
    end
  end

  defp safe_live_conversation(issue, operation, opts, fun) do
    case fun.() do
      {:ok, snapshot} when is_map(snapshot) ->
        publish_projection_snapshot(issue, opts, snapshot)
        :ok

      {:error, reason} ->
        log_projection_failure(issue, operation, reason)
        publish_projection_failure(issue, opts, reason)
        {:error, {:live_conversation_projection, operation, reason}}
    end
  catch
    :exit, reason ->
      reason_class = Lifecycle.reason_class(reason)
      log_projection_failure(issue, operation, reason_class)
      publish_projection_failure(issue, opts, reason_class)
      {:error, {:live_conversation_unavailable, operation}}
  end

  defp publish_projection_snapshot(issue, opts, snapshot) do
    status =
      Map.take(snapshot, [
        :generation_handle,
        :state,
        :health,
        :freshness,
        :observed_at
      ])

    send_projection_runtime_info(issue, opts, status)
  end

  defp publish_projection_failure(issue, opts, reason) do
    send_projection_runtime_info(issue, opts, %{
      generation_handle: nil,
      state: :unavailable,
      health: :unavailable,
      freshness: :unknown,
      reason: normalize_projection_reason(reason),
      observed_at: DateTime.utc_now()
    })
  end

  defp send_projection_runtime_info(%Issue{id: issue_id}, opts, status)
       when is_binary(issue_id) and is_list(opts) and is_map(status) do
    recipient =
      Keyword.get(opts, :live_conversation_recipient) || Keyword.get(opts, :orchestrator)

    if is_pid(recipient) do
      send(recipient, {:worker_runtime_info, issue_id, %{live_conversation: status}})
    end

    :ok
  end

  defp send_projection_runtime_info(_issue, _opts, _status), do: :ok

  defp normalize_projection_reason(reason) when is_atom(reason), do: reason
  defp normalize_projection_reason(_reason), do: :projection_unavailable

  defp display_tailer_authority?(opts),
    do: Keyword.get(opts, :live_conversation_authority) == :display_tailer

  defp operator_delivery_opts(issue, opts) do
    if display_tailer_authority?(opts) do
      case resolve_source_session(Keyword.get(opts, :live_conversation_source_resolver)) do
        session_id when is_binary(session_id) and session_id != "" ->
          {:ok, Keyword.put(opts, :session_id, session_id)}

        _missing ->
          reason = :missing_source_session
          log_projection_failure(issue, :observe_operator, reason)
          publish_projection_failure(issue, opts, reason)
          {:error, {:live_conversation_context, reason}}
      end
    else
      {:ok, opts}
    end
  end

  defp resolve_source_session(resolver) when is_function(resolver, 0) do
    resolver.()
  rescue
    _error -> nil
  catch
    _kind, _reason -> nil
  end

  defp resolve_source_session(_resolver), do: nil

  defp log_projection_failure(issue, operation, reason) do
    Logger.warning(
      "Live conversation projection #{operation} failed for " <>
        "#{Aiur.AgentRunner.issue_context(issue)} " <>
        "reason_class=#{normalize_projection_reason(reason)}"
    )
  end

  defp send_codex_update(recipient, %Issue{id: issue_id}, message)
       when is_binary(issue_id) and is_pid(recipient) do
    send(recipient, {:codex_worker_update, issue_id, message})
    :ok
  end

  defp send_codex_update(_recipient, _issue, _message), do: :ok

  @doc false
  @spec send_worker_runtime_info(pid() | nil, Issue.t(), String.t() | nil, Path.t() | nil) :: :ok
  def send_worker_runtime_info(recipient, %Issue{id: issue_id}, worker_host, workspace)
      when is_binary(issue_id) and is_pid(recipient) and is_binary(workspace) do
    send(
      recipient,
      {:worker_runtime_info, issue_id,
       %{
         worker_host: worker_host,
         workspace_path: workspace
       }}
    )

    :ok
  end

  def send_worker_runtime_info(_recipient, _issue, _worker_host, _workspace), do: :ok

  @doc false
  @spec send_control_state(pid() | nil, Issue.t(), :completed | :paused | :working | term()) :: :ok
  def send_control_state(recipient, %Issue{id: issue_id}, status)
      when is_pid(recipient) and is_binary(issue_id) and status in [:completed, :paused, :working] do
    send(recipient, {:worker_control_state, issue_id, status})
    :ok
  end

  def send_control_state(_recipient, _issue, _status), do: :ok

  @doc false
  @spec send_control_state(pid() | nil, Issue.t(), :completed | :paused | :working, map()) :: :ok
  def send_control_state(recipient, %Issue{id: issue_id}, status, payload)
      when is_pid(recipient) and is_binary(issue_id) and status in [:completed, :paused, :working] and
             is_map(payload) do
    send(recipient, {:worker_control_state, issue_id, status, normalize_control_payload(status, payload)})
    :ok
  end

  def send_control_state(_recipient, _issue, _status, _payload), do: :ok

  defp normalize_control_payload(
         status,
         %{control: %{request_id: request_id, generation: generation} = control} = payload
       )
       when is_integer(request_id) and is_integer(generation) do
    payload
    |> Map.delete(:control)
    |> Map.merge(control)
    |> maybe_put_control_pause_kind(status)
  end

  defp normalize_control_payload(status, payload), do: maybe_put_control_pause_kind(payload, status)

  defp maybe_put_control_pause_kind(payload, :paused), do: Map.put_new(payload, :kind, :operator_pause)
  defp maybe_put_control_pause_kind(payload, _status), do: payload
end
