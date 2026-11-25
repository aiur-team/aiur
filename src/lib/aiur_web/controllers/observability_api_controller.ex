defmodule AiurWeb.ObservabilityApiController do
  @moduledoc """
  JSON API for Aiur observability data.
  """

  use Phoenix.Controller, formats: [:json]

  alias Aiur.Claude.HookEvents
  alias Aiur.Conversation.History
  alias Aiur.Orchestrator
  alias Aiur.PollCadence
  alias Aiur.Listener
  alias AiurWeb.{EndpointConfig, MessageInbox, Presenter}
  alias Plug.Conn

  # The handlers that read an Orchestrator answer "pick a project" when projects mode has none for this request.
  plug(AiurWeb.ProjectScope, :required when action in [:state, :issue, :refresh, :send_message, :message_receipt, :pause, :resume])

  @spec state(Conn.t(), map()) :: Conn.t()
  def state(conn, _params) do
    json(conn, Presenter.state_payload(orchestrator(), snapshot_timeout_ms()) |> legacy_snapshot_error())
  end

  @spec issue(Conn.t(), map()) :: Conn.t()
  def issue(conn, %{"issue_identifier" => issue_identifier}) do
    case Presenter.issue_payload(issue_identifier, orchestrator(), snapshot_timeout_ms()) do
      {:ok, payload} ->
        json(conn, payload)

      {:error, :issue_not_found} ->
        error_response(conn, 404, "issue_not_found", "Issue not found")
    end
  end

  @spec events(Conn.t(), map()) :: Conn.t()
  def events(conn, %{"issue_identifier" => issue_identifier} = params) do
    case History.transcript(issue_identifier, Map.drop(params, ["issue_identifier"])) do
      {:ok, payload} -> json(conn, payload)
      {:error, :invalid_limit} -> error_response(conn, 422, "invalid_limit", "limit must be an integer from 1 to 50")
      {:error, :invalid_cursor} -> error_response(conn, 422, "invalid_cursor", "cursor must be a non-negative integer")
      {:error, _reason} -> error_response(conn, 503, "events_unavailable", "Event feed is unavailable")
    end
  end

  @spec refresh(Conn.t(), map()) :: Conn.t()
  def refresh(conn, _params) do
    case Presenter.refresh_payload(orchestrator()) do
      {:ok, payload} ->
        conn
        |> put_status(202)
        |> json(payload)

      {:error, :unavailable} ->
        error_response(conn, 503, "orchestrator_unavailable", "Orchestrator is unavailable")
    end
  end

  @spec send_message(Conn.t(), map()) :: Conn.t()
  def send_message(conn, %{"issue_identifier" => issue_identifier} = params) do
    text = Map.get(params, "text") || Map.get(params, "message") || ""
    message_id = Map.get(params, "message_id")

    with {:ok, delivery} <- delivery_mode(Map.get(params, "delivery")),
         {:ok, text} <- with_attachments(issue_identifier, text, message_id, Map.get(params, "attachments")) do
      issue_identifier
      |> send_operator_message(text, message_id, conn.assigns[:auth_actor], delivery)
      |> render_send_message_response(conn, issue_identifier)
    else
      {:error, reason} -> send_refused(conn, reason)
    end
  end

  @doc """
  The delivery receipt of one message sent to this ticket: its queue status
  (pending, delivered, consumed, failed), the receipt class, the listen mode it
  was delivered under and when. 404 when the request belongs to another ticket.
  """
  @spec message_receipt(Conn.t(), map()) :: Conn.t()
  def message_receipt(conn, %{"issue_identifier" => issue_identifier, "request_id" => request_id}) do
    with {id, ""} <- Integer.parse(request_id),
         {:ok, receipt} <- Listener.ticket_receipt(issue_identifier, id) do
      json(conn, receipt)
    else
      {:error, :not_found} -> error_response(conn, 404, "message_not_found", "No message with that request_id was sent to this ticket")
      {:error, _reason} -> error_response(conn, 503, "receipt_unavailable", "The message queue is unavailable")
      _invalid -> error_response(conn, 422, "invalid_request_id", "request_id must be an integer")
    end
  end

  defp delivery_mode(nil), do: {:ok, nil}
  defp delivery_mode("steer"), do: {:ok, :steer}
  defp delivery_mode("sync"), do: {:ok, :sync}
  defp delivery_mode(_other), do: {:error, :invalid_delivery}

  # Attachments are written straight into the worker's workspace, so they need a
  # running worker whose workspace is on this host.
  defp with_attachments(_issue_identifier, text, _message_id, attachments) when attachments in [nil, []], do: {:ok, text}

  defp with_attachments(issue_identifier, text, message_id, attachments) do
    folder = if is_binary(message_id) and message_id != "", do: message_id, else: "msg-#{System.os_time(:millisecond)}"

    with {:ok, %{running: running, workspace: %{path: path, host: nil}}} when not is_nil(running) <-
           Presenter.issue_payload(issue_identifier, orchestrator(), snapshot_timeout_ms()),
         {:ok, lines} <- MessageInbox.write(path, folder, attachments) do
      {:ok, MessageInbox.append(text, lines)}
    else
      {:error, reason} when reason != :issue_not_found -> {:error, reason}
      _not_local -> {:error, :attachments_need_local_worker}
    end
  end

  defp send_refused(conn, :invalid_delivery), do: error_response(conn, 422, "invalid_delivery", "delivery must be steer or sync")

  defp send_refused(conn, :attachments_need_local_worker),
    do: error_response(conn, 409, "attachments_need_local_worker", "Attachments need a running worker whose workspace is on this host")

  defp send_refused(conn, reason), do: error_response(conn, 422, Atom.to_string(reason), "Attachments are invalid: #{reason}")

  @doc """
  Pause or resume an agent through the orchestrator control API.

  Prioritizing an agent is intentionally out of scope: Aiur has no
  server-side queue-priority state to expose or mutate.
  """
  @spec pause(Conn.t(), map()) :: Conn.t()
  def pause(conn, %{"issue_identifier" => issue_identifier}) do
    issue_identifier
    |> pause_agent()
    |> render_control_response(conn, issue_identifier, :pause)
  end

  @spec resume(Conn.t(), map()) :: Conn.t()
  def resume(conn, %{"issue_identifier" => issue_identifier}) do
    issue_identifier
    |> resume_agent()
    |> render_control_response(conn, issue_identifier, :resume)
  end

  # Opencode Ctrl+C bridge. The tmux key binding POSTs the pane id here;
  # the orchestrator derives the 3-state action from the agent's live
  # state. Any error degrades to `close_pane` so a failed bridge call
  # never leaves the Executor unable to close the pane (the binding's
  # fallback behaviour).
  @spec pane_interrupt(Conn.t(), map()) :: Conn.t()
  def pane_interrupt(conn, %{"pane_id" => pane_id}) when is_binary(pane_id) and pane_id != "" do
    action =
      case Aiur.AgentChat.pane_interrupt(pane_id) do
        {:ok, action} -> action
        {:error, _reason} -> :close_pane
      end

    json(conn, %{action: action})
  end

  def pane_interrupt(conn, _params) do
    error_response(conn, 422, "missing_pane_id", "pane_id is required")
  end

  @doc """
  Hide a chat pane without touching agent or slot state: the pane moves to
  the hidden warm window (opencode-attach process intact) and reopening
  swaps the same pane back instantly. Callers (Ctrl+Q / the Ctrl+C bridge's
  close branch) fall back to a plain kill-pane on any non-200.
  """
  @spec pane_hide(Conn.t(), map()) :: Conn.t()
  def pane_hide(conn, %{"pane_id" => pane_id}) when is_binary(pane_id) and pane_id != "" do
    case Aiur.PaneManager.hide_by_pane_id(pane_id) do
      :ok -> json(conn, %{action: :hidden})
      {:error, reason} -> error_response(conn, 409, "hide_failed", inspect(reason))
    end
  end

  def pane_hide(conn, _params) do
    error_response(conn, 422, "missing_pane_id", "pane_id is required")
  end

  # Claude Code lifecycle-hook sink for the RC-claude backend. The agent's
  # `claude --remote-control` session is configured (via `--settings`) to POST
  # each UserPromptSubmit/PostToolUse/Stop event here; `HookEvents` fans it out on
  # the agent's PubSub topic so `ReplAgent` can drive turn detection without the
  # (lazily-flushed, unreliable) transcript file. ALWAYS replies 200: a non-2xx or
  # any stderr from claude's hook command could disrupt the live session.
  @spec claude_hook(Conn.t(), map()) :: Conn.t()
  def claude_hook(conn, %{"issue_identifier" => identifier} = params) when is_binary(identifier) do
    _ = HookEvents.dispatch(identifier, Map.drop(params, ["issue_identifier"]))
    json(conn, %{ok: true})
  end

  def claude_hook(conn, _params) do
    json(conn, %{ok: true})
  end

  @spec method_not_allowed(Conn.t(), map()) :: Conn.t()
  def method_not_allowed(conn, _params) do
    error_response(conn, 405, "method_not_allowed", "Method not allowed")
  end

  @spec not_found(Conn.t(), map()) :: Conn.t()
  def not_found(conn, _params) do
    error_response(conn, 404, "not_found", "Route not found")
  end

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end

  defp orchestrator do
    EndpointConfig.get(:orchestrator) || Aiur.Orchestrator.server()
  end

  # The configured value is the floor, not the tolerance: a fixed 15s window
  # against a 120s poll marks a healthy fleet stale for most of every cycle.
  # See `Aiur.PollCadence.snapshot_tolerance_ms/1`.
  defp snapshot_timeout_ms do
    PollCadence.snapshot_tolerance_ms(EndpointConfig.get(:snapshot_timeout_ms) || 15_000, class: :dispatch)
  end

  # The dashboard distinguishes a stopped Orchestrator from an empty read model,
  # while the long-standing machine endpoint exposes both as a snapshot-unavailable
  # response. Keep that wire contract stable for existing API consumers.
  defp legacy_snapshot_error(%{error: %{code: "orchestrator_unavailable"}} = payload) do
    put_in(payload, [:error], %{code: "snapshot_unavailable", message: "Snapshot unavailable"})
  end

  defp legacy_snapshot_error(%{error: %{code: "snapshot_unpublished"}} = payload) do
    put_in(payload, [:error], %{code: "snapshot_timeout", message: "Snapshot timed out"})
  end

  defp legacy_snapshot_error(payload), do: payload

  # `message_id` is optional (#2717). A client that sends one gets its retry
  # deduplicated: the same id, target and text return the first item. Without
  # one, every request is a new message.
  # `delivery` (steer or sync) overrides the ticket's listen mode for this one
  # message; steer falls back to sync when the worker cannot steer.
  defp send_operator_message(issue_identifier, text, message_id, auth_actor, delivery) do
    payload = %{kind: :text, body: text, delivery_policy: :listener, origin: :http}
    payload = if delivery, do: Map.put(payload, :delivery_mode, delivery), else: payload

    payload =
      case auth_actor do
        {:device, id} when is_binary(id) -> Map.put(payload, :actor, "device:" <> id)
        _ -> payload
      end

    payload =
      if is_binary(message_id) and message_id != "", do: Map.put(payload, :message_id, message_id), else: payload

    Orchestrator.send_operator_message(orchestrator(), issue_identifier, payload)
  end

  defp pause_agent(issue_identifier),
    do: Orchestrator.pause_agent(orchestrator(), issue_identifier)

  defp resume_agent(issue_identifier),
    do: Orchestrator.resume_agent(orchestrator(), issue_identifier)

  defp render_send_message_response({:ok, request_id}, conn, issue_identifier) do
    conn
    |> put_status(202)
    |> json(%{request_id: request_id, issue_identifier: issue_identifier})
  end

  # A timeout is an unknown outcome, not a failure: the daemon may still queue
  # the message (#2717). 202 tells the client the send may be in progress. A
  # retry is safe only with the same `message_id`, so `retry_safe` says if the
  # request carried one.
  defp render_send_message_response({:error, {:outcome_unknown, info}}, conn, issue_identifier) do
    message_id = Map.get(info, :message_id)

    conn
    |> put_status(202)
    |> json(%{
      outcome: "unknown",
      request_id: Map.get(info, :item_id),
      message_id: message_id,
      issue_identifier: issue_identifier,
      retry_safe: is_binary(message_id)
    })
  end

  defp render_send_message_response({:error, {:message_id_conflict, _item_id}}, conn, _issue_identifier) do
    error_response(conn, 409, "message_id_conflict", "message_id was already used for a different message")
  end

  defp render_send_message_response({:error, :no_running_agent}, conn, _issue_identifier) do
    error_response(conn, 409, "agent_not_running", "Agent is not currently running")
  end

  defp render_send_message_response({:error, :empty_message}, conn, _issue_identifier) do
    error_response(conn, 422, "empty_message", "Message is empty")
  end

  defp render_send_message_response({:error, :message_too_long}, conn, _issue_identifier) do
    error_response(conn, 422, "message_too_long", "Message is too long")
  end

  defp render_send_message_response({:error, reason}, conn, _issue_identifier) do
    error_response(conn, 503, "send_failed", inspect(reason))
  end

  defp render_control_response({:ok, result}, conn, issue_identifier, action) do
    conn
    |> put_status(202)
    |> json(%{
      action: Atom.to_string(action),
      issue_identifier: issue_identifier,
      result: control_result(result)
    })
  end

  defp render_control_response({:error, :no_running_agent}, conn, _issue_identifier, _action) do
    error_response(conn, 409, "agent_not_running", "Agent is not currently running")
  end

  defp render_control_response({:error, :invalid_identifier}, conn, _issue_identifier, _action) do
    error_response(conn, 422, "invalid_identifier", "Issue identifier is invalid")
  end

  defp render_control_response({:error, {:stale_tracker_state, _reason, _details} = reason}, conn, _issue_identifier, _action) do
    error_response(conn, 409, "control_conflict", inspect(reason))
  end

  defp render_control_response({:error, {:tracker_state_not_resumable, _state} = reason}, conn, _issue_identifier, _action) do
    error_response(conn, 409, "control_conflict", inspect(reason))
  end

  defp render_control_response({:error, {:state_concurrency_limit_reached, _state} = reason}, conn, _issue_identifier, _action) do
    error_response(conn, 409, "control_conflict", inspect(reason))
  end

  defp render_control_response({:error, {:blocked_on_decision, _detail} = reason}, conn, _issue_identifier, _action) do
    error_response(conn, 409, "control_conflict", inspect(reason))
  end

  defp render_control_response({:error, {tag, _detail} = reason}, conn, _issue_identifier, _action)
       when tag in [:worker_startup_failed, :not_resumable_control_status, :max_concurrent_agents_reached] do
    error_response(conn, 409, "control_conflict", inspect(reason))
  end

  defp render_control_response({:error, reason}, conn, _issue_identifier, _action)
       when reason in [
              :already_inactive,
              :already_claimed,
              :all_model_backends_limited,
              :auto_resume_pending,
              :contradictory_tracker_state_labels,
              :control_request_conflict,
              :dispatch_not_authorized,
              :dispatch_retry_scheduled,
              :invalid_tracker_issue,
              :max_concurrent_agents_reached,
              :no_worker_capacity,
              :not_routable_to_worker,
              :not_resumable,
              :pause_override_still_present,
              :ticket_parked,
              :globally_paused,
              :stale_generation,
              :tracker_issue_not_found,
              :waiting_for_dependencies,
              :worker_not_running,
              :worker_not_started,
              :workspace_ownership_waiting
            ] do
    error_response(conn, 409, "control_conflict", inspect(reason))
  end

  defp render_control_response({:error, reason}, conn, _issue_identifier, _action) do
    error_response(conn, 503, "control_failed", inspect(reason))
  end

  defp control_result(result) when is_atom(result), do: Atom.to_string(result)
  defp control_result(result), do: result
end
