defmodule AiurWeb.ObservabilityApiController do
  @moduledoc """
  JSON API for Aiur observability data.
  """

  use Phoenix.Controller, formats: [:json]

  alias Aiur.AgentEventFeed
  alias Aiur.Claude.HookEvents
  alias Aiur.Orchestrator
  alias AiurWeb.{Endpoint, Presenter, StreamDeckGrid}
  alias Plug.Conn

  @spec state(Conn.t(), map()) :: Conn.t()
  def state(conn, _params) do
    conn
    |> json(Presenter.state_payload(orchestrator(), snapshot_timeout_ms()) |> legacy_snapshot_error())
  end

  @spec streamdeck_grid(Conn.t(), map()) :: Conn.t()
  def streamdeck_grid(conn, _params) do
    json(conn, StreamDeckGrid.payload(orchestrator(), snapshot_timeout_ms()))
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
    case AgentEventFeed.list(issue_identifier, Map.drop(params, ["issue_identifier"])) do
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

    issue_identifier
    |> send_operator_message(text)
    |> render_send_message_response(conn, issue_identifier)
  end

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
    Endpoint.config(:orchestrator) || Aiur.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
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

  defp send_operator_message(issue_identifier, text) do
    Orchestrator.send_operator_message(orchestrator(), issue_identifier, %{kind: :text, body: text})
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
              :globally_paused,
              :stale_generation,
              :tracker_issue_not_found,
              :waiting_for_dependencies,
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
