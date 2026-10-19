defmodule Aiur.AgentRunner.MessageHandler do
  @moduledoc """
  Handles one normalized backend message for an agent turn.

  It writes the agent event log, fans messages out to transcript and turn-event
  subscribers, and reports worker state to the orchestrator recipient.
  """

  alias Aiur.{
    AgentEventLog,
    AgentEvents,
    AgentPubSub,
    CodingAgent,
    Issue,
    ModelAvailability
  }

  alias Aiur.AgentRunner.CodexUpdateRelay
  alias Aiur.AgentRunner.LiveObserver
  alias Aiur.AgentRunner.TurnProgress
  alias Aiur.Protocol.MapAccess
  alias Aiur.RunTelemetry.Lifecycle
  alias Aiur.Signal
  alias Aiur.Usage.Headless.Emitter

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
      observe_usage(issue, backend, message, turn_id, lifecycle_opts)
      AgentEventLog.write(workspace, worker_host, message)
      maybe_broadcast_transcript(issue, transcript_event)
      LiveObserver.maybe_observe_live_conversation(issue, transcript_event, lifecycle_opts)
      maybe_broadcast_turn_event(issue, message, turn_id)
      send_codex_update(recipient, issue, message)
    end
  end

  defp observe_lifecycle(%Issue{identifier: identifier}, backend, message, lifecycle_opts)
       when is_binary(identifier) and is_list(lifecycle_opts) do
    Signal.backend_message(
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

  # Emit a DASH-008 usage envelope for each supported headless usage event. This
  # runs on the unconditional per-message path, so emission is independent of
  # dashboard clients, TUI mode, or --debug. The emitter fails closed and never
  # propagates a fault into the worker turn.
  defp observe_usage(issue, backend, message, turn_id, lifecycle_opts) do
    Emitter.observe(issue, backend, message, Keyword.put(lifecycle_opts, :turn_id, turn_id))
    :ok
  end

  defp maybe_broadcast_transcript(%Issue{identifier: identifier}, {:ok, event})
       when is_binary(identifier) do
    AgentPubSub.broadcast_transcript(identifier, event)
  end

  defp maybe_broadcast_transcript(_issue, _transcript_event), do: :ok

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
  @spec observe_operator_delivery(Issue.t(), map(), String.t(), keyword()) ::
          :ok | {:error, term()}
  defdelegate observe_operator_delivery(issue, item, backend, opts), to: LiveObserver

  @doc false
  @spec observe_display_transcript(Issue.t(), map(), String.t(), keyword()) :: :ok
  defdelegate observe_display_transcript(issue, event, backend, opts), to: LiveObserver

  @doc false
  @spec end_live_conversation(Issue.t(), String.t(), keyword()) :: :ok | {:error, term()}
  defdelegate end_live_conversation(issue, backend, opts), to: LiveObserver

  @doc false
  @spec finish_live_conversation(Issue.t(), String.t(), term(), keyword()) ::
          :ok | {:error, term()}
  defdelegate finish_live_conversation(issue, backend, result, opts), to: LiveObserver

  @doc false
  @spec mark_live_conversation_degraded(Issue.t(), String.t(), keyword()) ::
          :ok | {:error, term()}
  defdelegate mark_live_conversation_degraded(issue, backend, opts), to: LiveObserver

  @doc false
  @spec activate_live_conversation(Issue.t(), String.t(), keyword()) ::
          :ok | {:error, term()}
  defdelegate activate_live_conversation(issue, backend, opts), to: LiveObserver

  @doc false
  @spec replace_live_conversation_source(
          Issue.t(),
          String.t(),
          String.t() | nil,
          String.t() | nil,
          keyword()
        ) :: :ok | {:error, term()}
  defdelegate replace_live_conversation_source(issue, backend, prior_session, next_session, opts), to: LiveObserver

  @doc false
  @spec live_source(Issue.t(), String.t(), keyword()) ::
          {:ok, map()} | {:skip, atom()} | {:error, atom()}
  defdelegate live_source(issue, backend, opts), to: LiveObserver

  # Streaming deltas are coalesced here rather than dropped downstream: the
  # orchestrator cannot filter what is already in its mailbox, and the mailbox
  # is exactly what #1731 buried. See `CodexUpdateRelay`.
  defp send_codex_update(recipient, %Issue{id: issue_id}, message)
       when is_binary(issue_id) and is_pid(recipient) do
    _decision = CodexUpdateRelay.relay(recipient, issue_id, message)
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
         workspace_path: workspace,
         duration_cap_progress_baseline: workspace_fingerprint(workspace, worker_host)
       }}
    )

    :ok
  end

  def send_worker_runtime_info(_recipient, _issue, _worker_host, _workspace), do: :ok

  defp workspace_fingerprint(workspace, worker_host) do
    case TurnProgress.workspace_digest(workspace, worker_host) do
      {:ok, digest} -> digest
      {:error, _reason} -> nil
    end
  end

  @doc false
  # Signals the orchestrator that this dispatch attempt has survived
  # provisioning (workspace created, session about to start). The orchestrator
  # bills exactly one lifetime dispatch unit here — the only point a dispatch
  # is counted as real work — so a preflight/prewarm/tracker-auth failure
  # (which never reaches this call) leaves the budget unchanged (#1453).
  @spec send_dispatch_committed(pid() | nil, Issue.t()) :: :ok
  def send_dispatch_committed(recipient, %Issue{id: issue_id})
      when is_binary(issue_id) and is_pid(recipient) do
    send(recipient, {:dispatch_committed, issue_id})
    :ok
  end

  def send_dispatch_committed(_recipient, _issue), do: :ok

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

  @doc false
  @spec send_control_rejection(pid() | nil, Issue.t(), pos_integer(), non_neg_integer(), atom()) :: :ok
  def send_control_rejection(recipient, %Issue{id: issue_id}, request_id, generation, class)
      when is_pid(recipient) and is_binary(issue_id) and is_integer(request_id) and request_id > 0 and
             is_integer(generation) and generation >= 0 and is_atom(class) do
    send(recipient, {:worker_control_rejected, issue_id, request_id, generation, class})
    :ok
  end

  def send_control_rejection(_recipient, _issue, _request_id, _generation, _class), do: :ok

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

  defp maybe_put_control_pause_kind(payload, :paused), do: Map.put_new(payload, :kind, :worker_pause_unknown)
  defp maybe_put_control_pause_kind(payload, _status), do: payload
end
