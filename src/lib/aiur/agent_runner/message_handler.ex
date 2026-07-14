defmodule Aiur.AgentRunner.MessageHandler do
  @moduledoc """
  Handles one normalized backend message for an agent turn.

  It writes the agent event log, fans messages out to transcript and turn-event
  subscribers, and reports worker state to the orchestrator recipient.
  """

  alias Aiur.{AgentEventLog, AgentEvents, AgentPubSub, CodingAgent, Issue, ModelAvailability}
  alias Aiur.GitHub.AgentCommentOrigins
  alias Aiur.Protocol.MapAccess
  alias Aiur.RunTelemetry.Lifecycle

  @spec build(pid() | nil, Issue.t(), Path.t() | nil, String.t() | nil, String.t(), String.t() | nil) :: (map() -> :ok)
  def build(recipient, issue, workspace, worker_host, backend, turn_id \\ nil) do
    build(recipient, issue, workspace, worker_host, backend, turn_id, [])
  end

  @doc false
  @spec build(pid() | nil, Issue.t(), Path.t() | nil, String.t() | nil, String.t(), String.t() | nil, keyword()) ::
          (map() -> :ok)
  def build(recipient, issue, workspace, worker_host, backend, turn_id, nil) do
    build(recipient, issue, workspace, worker_host, backend, turn_id, [])
  end

  def build(recipient, issue, workspace, worker_host, backend, turn_id, lifecycle_opts)
      when is_list(lifecycle_opts) do
    lifecycle_opts =
      if Lifecycle.enabled?(lifecycle_opts) do
        Keyword.put_new(lifecycle_opts, :tracker, make_ref())
      end

    origin_recorder =
      Keyword.get(lifecycle_opts, :agent_comment_origin_recorder, &AgentCommentOrigins.record_gh_pr_comment/4)

    fn message ->
      message = CodingAgent.normalize_event(message, backend)
      observe_lifecycle(issue, backend, message, lifecycle_opts)
      observe_rate_limits(backend, message)
      observe_agent_comment_origin(issue, backend, message, origin_recorder)
      AgentEventLog.write(workspace, worker_host, message)
      maybe_broadcast_transcript(issue, message, backend, turn_id)
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

  defp observe_rate_limits(backend, %{rate_limits: limits}) when is_map(limits), do: ModelAvailability.observe(backend, limits)
  defp observe_rate_limits(_backend, _message), do: :ok

  defp observe_agent_comment_origin(%Issue{identifier: identifier}, backend, message, recorder)
       when is_binary(identifier) and is_function(recorder, 4) do
    case transcript_event_from(message, backend, nil) do
      {:ok, %{role: :command, payload: %{command: command, output: output, exit_code: exit_code}}} ->
        _ = recorder.(identifier, command, output, exit_code)
        :ok

      _ ->
        :ok
    end
  end

  defp observe_agent_comment_origin(_issue, _backend, _message, _recorder), do: :ok

  defp maybe_broadcast_transcript(%Issue{identifier: identifier}, message, backend, turn_id)
       when is_binary(identifier) do
    case transcript_event_from(message, backend, turn_id) do
      {:ok, event} -> AgentPubSub.broadcast_transcript(identifier, event)
      :skip -> :ok
    end
  end

  defp maybe_broadcast_transcript(_issue, _message, _backend, _turn_id), do: :ok

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
  @spec send_control_state(pid() | nil, Issue.t(), :paused, map()) :: :ok
  def send_control_state(recipient, %Issue{id: issue_id}, :paused, pause_payload)
      when is_pid(recipient) and is_binary(issue_id) and is_map(pause_payload) do
    send(recipient, {:worker_control_state, issue_id, :paused, pause_payload})
    :ok
  end

  def send_control_state(_recipient, _issue, :paused, _pause_payload), do: :ok
end
