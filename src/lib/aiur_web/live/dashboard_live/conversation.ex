defmodule AiurWeb.DashboardLive.Conversation do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [push_patch: 2]

  alias Aiur.Agent.UsageSnapshotService
  alias Aiur.Conversation.History, as: ConversationHistory
  alias Aiur.TrackerIdentity
  alias AiurWeb.DashboardLive.Controls
  alias AiurWeb.DashboardLive.UnitsPanel
  alias AiurWeb.EndpointConfig
  alias AiurWeb.OperatorControlCenter.AgentLogModal
  alias AiurWeb.OperatorControlCenter.ConversationDrawer.Presenter, as: ConversationPresenter
  alias AiurWeb.OperatorControlCenter.OperatorSend
  alias AiurWeb.OperatorControlCenter.UnitsPresenter

  @doc false
  @spec maybe_open_conversation_route(Phoenix.LiveView.Socket.t(), term()) :: Phoenix.LiveView.Socket.t()
  def maybe_open_conversation_route(socket, %{"owner" => owner, "repository" => repository, "identifier" => identifier}) do
    catalog = Map.get(socket.assigns.payload, :units, %{})
    rows = get_in(catalog, [:snapshot, :rows]) || []

    case Enum.find(rows, &conversation_route_row?(&1, owner, repository, identifier)) do
      nil ->
        assign(socket, :conversation_notice, "Chat is unavailable for this ticket.")

      row ->
        with token when is_binary(token) <- UnitsPresenter.row_token(row),
             handle when is_binary(handle) <- conversation_handle(row),
             {:ok, %{state: state} = snapshot} when state in [:live, :stale, :ended, :known_empty] <-
               resolve_conversation(handle) do
          socket |> assign(:conversation_notice, nil) |> open_conversation(row, token, handle, snapshot)
        else
          _unavailable -> assign(socket, :conversation_notice, "Chat is unavailable for this ticket.")
        end
    end
  end

  def maybe_open_conversation_route(socket, _params), do: assign(socket, :conversation_notice, nil)

  defp conversation_route_row?(%{identity: %TrackerIdentity{} = identity}, owner, repository, identifier) do
    identity.owner == owner and identity.repository == repository and identity.identifier == identifier
  end

  defp conversation_route_row?(_row, _owner, _repository, _identifier), do: false

  @doc false
  @spec pause_agent_action(Phoenix.LiveView.Socket.t(), term()) :: term()
  def pause_agent_action(socket, modal) do
    key = agent_log_key(modal)

    if Map.get(modal, :writable_target?) == true do
      modal
      |> agent_log_target()
      |> Controls.pause_agent()
      |> pause_agent_result(socket, key)
    else
      {:noreply, put_chat_error(socket, key, :ambiguous_identifier)}
    end
  end

  defp pause_agent_result({:ok, _request_id}, socket, key),
    do: {:noreply, assign(socket, :chat_errors, Map.delete(socket.assigns.chat_errors, key))}

  defp pause_agent_result({:error, reason}, socket, key),
    do: {:noreply, put_chat_error(socket, key, reason)}

  defp open_conversation(socket, row, token, handle, snapshot) do
    composer = agent_log_composer(socket.assigns.payload, row)
    usage_opts = [ticket: Map.get(row, :identity)]
    attempt_id = Map.get(row, :telemetry_attempt_id)
    usage_opts = if is_binary(attempt_id), do: Keyword.put(usage_opts, :attempt_id, attempt_id), else: usage_opts

    {usage_snapshot, usage_error} =
      case Map.get(row, :identity) do
        %TrackerIdentity{} = identity ->
          usage_snapshot_fun = EndpointConfig.get(:usage_snapshot_fun) || (&UsageSnapshotService.current/2)

          case usage_snapshot_fun.(identity.identifier || "current agent", usage_opts) do
            {:ok, usage} -> {usage, nil}
            {:error, reason} -> {nil, reason}
          end

        _missing_identity ->
          {nil, :unable_to_resolve_scope}
      end

    socket
    |> replace_conversation_subscription(handle)
    |> assign(:conversation_handle, handle)
    |> assign(:conversation_identity, Map.get(row, :identity))
    |> assign(:conversation_row, row)
    |> assign(:conversation_origin_id, "units-conversation-#{token}")
    |> assign(:conversation_lifecycle, :active)
    |> assign(:conversation_snapshot, snapshot)
    |> assign(:conversation_usage_snapshot, usage_snapshot)
    |> assign(:conversation_usage_error, usage_error)
    |> assign(:conversation_log, log_for_drawer(composer))
    |> assign(:agent_log_modal, composer)
    |> present_conversation()
  end

  defp close_conversation(socket) do
    socket
    |> unsubscribe_conversation()
    |> assign(:conversation_drawer, nil)
    |> assign(:conversation_handle, nil)
    |> assign(:conversation_identity, nil)
    |> assign(:conversation_row, nil)
    |> assign(:conversation_origin_id, nil)
    |> assign(:conversation_lifecycle, :active)
    |> assign(:conversation_snapshot, nil)
    |> assign(:conversation_usage_snapshot, nil)
    |> assign(:conversation_usage_error, nil)
    |> assign(:conversation_log, nil)
    |> assign(:agent_log_modal, nil)
  end

  defp present_conversation(socket) do
    view =
      ConversationPresenter.present(
        socket.assigns.conversation_row,
        socket.assigns.conversation_snapshot,
        socket.assigns.conversation_lifecycle,
        socket.assigns.conversation_log
      )

    assign(socket, :conversation_drawer, view)
  end

  # The chat modal carries the running agent's workspace log and the writable
  # composer beneath the conversation. `agent_log_composer/2` builds the same
  # AgentLogModal payload (target key, writable target, parsed transcript) so the
  # existing composer handlers apply to the drawer; the drawer surfaces only the
  # parsed transcript, never the local path.
  defp agent_log_composer(payload, row) do
    case AgentLogModal.find_running_entry(payload, Map.get(row, :identity)) do
      %{} = entry -> AgentLogModal.build(entry, payload)
      _none -> nil
    end
  end

  defp log_for_drawer(%{messages: messages}) when is_list(messages), do: %{messages: messages}
  defp log_for_drawer(_composer), do: nil

  # Replace only the pinned generation's snapshot. A change for any other handle
  # is ignored so a replacement worker never appears under the old heading.
  @doc false
  @spec maybe_update_conversation(Phoenix.LiveView.Socket.t(), term()) :: Phoenix.LiveView.Socket.t()
  def maybe_update_conversation(
        %{assigns: %{conversation_handle: handle, conversation_lifecycle: :active}} = socket,
        %{generation_handle: handle} = snapshot
      )
      when is_binary(handle) do
    socket
    |> assign(:conversation_snapshot, snapshot)
    |> present_conversation()
  end

  def maybe_update_conversation(socket, _snapshot), do: socket

  @doc false
  @spec supersede_conversation(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def supersede_conversation(%{assigns: %{conversation_handle: handle}} = socket)
      when is_binary(handle) do
    socket
    |> assign(:conversation_lifecycle, :superseded)
    |> present_conversation()
  end

  def supersede_conversation(socket), do: socket

  # On payload reload, transition truthfully: the row leaving scope freezes the
  # drawer as out-of-scope, a changed generation handle freezes it as superseded,
  # and an in-scope same-generation row refreshes only its metadata.
  @doc false
  @spec refresh_conversation_row(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def refresh_conversation_row(%{assigns: %{conversation_lifecycle: :active, conversation_handle: handle}} = socket)
      when is_binary(handle) do
    rows = get_in(socket.assigns.payload, [:units, :snapshot, :rows]) || []
    identity = socket.assigns.conversation_identity

    case Enum.find(rows, &same_identity?(Map.get(&1, :identity), identity)) do
      nil ->
        socket
        |> assign(:conversation_lifecycle, :out_of_scope)
        |> present_conversation()

      row ->
        case conversation_handle(row) do
          ^handle ->
            socket
            |> assign(:conversation_row, row)
            |> present_conversation()

          _replaced ->
            socket
            |> assign(:conversation_lifecycle, :superseded)
            |> present_conversation()
        end
    end
  end

  def refresh_conversation_row(socket), do: socket

  defp replace_conversation_subscription(socket, handle) do
    if socket.assigns.conversation_handle == handle do
      socket
    else
      socket
      |> unsubscribe_conversation()
      |> subscribe_conversation(handle)
    end
  end

  defp subscribe_conversation(socket, handle) do
    _result = call_conversation(:live_conversation_subscribe_fun, &ConversationHistory.live_subscribe/1, handle)
    socket
  end

  defp unsubscribe_conversation(%{assigns: %{conversation_handle: handle}} = socket)
       when is_binary(handle) do
    _result = call_conversation(:live_conversation_unsubscribe_fun, &ConversationHistory.live_unsubscribe/1, handle)
    socket
  end

  defp unsubscribe_conversation(socket), do: socket

  defp resolve_conversation(handle) do
    call_conversation(:live_conversation_resolve_fun, &ConversationHistory.live_resolve/1, handle)
  end

  defp call_conversation(config_key, default, handle) do
    fun = EndpointConfig.get(config_key) || default
    fun.(handle)
  rescue
    _error -> {:error, :unavailable}
  catch
    :exit, _reason -> {:error, :unavailable}
    _kind, _reason -> {:error, :unavailable}
  end

  defp conversation_handle(%{live_conversation: %{generation_handle: handle}}) when is_binary(handle),
    do: handle

  defp conversation_handle(_row), do: nil

  @doc false
  @spec same_identity?(term(), term()) :: term()
  def same_identity?(%TrackerIdentity{} = left, %TrackerIdentity{} = right) do
    key = TrackerIdentity.github_key(left)
    not is_nil(key) and key == TrackerIdentity.github_key(right)
  end

  def same_identity?(_left, _right), do: false

  defp clear_chat_state(socket, identifier) do
    socket
    |> assign(:drafts, Map.delete(socket.assigns.drafts, identifier))
    |> assign(:pending_message_ids, Map.delete(socket.assigns.pending_message_ids, identifier))
    |> assign(:chat_errors, Map.delete(socket.assigns.chat_errors, identifier))
  end

  defp put_chat_error(socket, identifier, reason) do
    assign(socket, :chat_errors, Map.put(socket.assigns.chat_errors, identifier, AgentLogModal.format_error(reason)))
  end

  defp send_operator_message(socket, _modal, ""), do: socket

  # OperatorSend owns the #2717 rule; the drawer keeps the draft only when the
  # outcome is unknown, so a retry with the same text reuses the message id.
  defp send_operator_message(socket, modal, text) do
    key = agent_log_key(modal)

    case OperatorSend.send(modal, text, socket.assigns.pending_message_ids) do
      {:ok, _request_id, _message_id, pending} ->
        socket |> assign(:pending_message_ids, pending) |> clear_chat_state(key)

      {:error, {:outcome_unknown, _info} = reason, _message_id, pending} ->
        socket
        |> assign(:pending_message_ids, pending)
        |> assign(:drafts, Map.put(socket.assigns.drafts, key, text))
        |> put_chat_error(key, reason)

      {:error, reason, _message_id, pending} ->
        socket
        |> assign(:pending_message_ids, pending)
        |> put_chat_error(key, reason)
    end
  end

  defp agent_log_target(modal), do: OperatorSend.target(modal)
  defp agent_log_key(modal), do: OperatorSend.key(modal)

  @doc false
  @spec on_read_conversation(term(), term()) :: {:noreply, Phoenix.LiveView.Socket.t()}
  def on_read_conversation(token, socket) do
    catalog = Map.get(socket.assigns.payload, :units, %{})

    with {:ok, row} <- UnitsPresenter.lookup(catalog, token),
         handle when is_binary(handle) <- conversation_handle(row),
         {:ok, snapshot} <- resolve_conversation(handle) do
      {:noreply, open_conversation(socket, row, token, handle, snapshot)}
    else
      _not_available -> {:noreply, socket}
    end
  end

  @doc false
  @spec on_close_conversation(Phoenix.LiveView.Socket.t()) :: {:noreply, Phoenix.LiveView.Socket.t()}
  def on_close_conversation(socket) do
    socket = close_conversation(socket)

    if socket.assigns.conversation_from_route? do
      {:noreply,
       push_patch(socket,
         to: UnitsPanel.units_path(socket, socket.assigns.units_selection),
         replace: true
       )}
    else
      {:noreply, socket}
    end
  end

  @doc false
  @spec on_show_agent_log(term(), term()) :: {:noreply, Phoenix.LiveView.Socket.t()}
  def on_show_agent_log(token, socket) do
    catalog = Map.get(socket.assigns.payload, :units, %{})

    with {:ok, row} <- UnitsPresenter.lookup(catalog, token),
         %{} = entry <- AgentLogModal.find_running_entry(socket.assigns.payload, row.identity) do
      {:noreply, assign(socket, :agent_log_modal, AgentLogModal.build(entry, socket.assigns.payload))}
    else
      _not_found -> {:noreply, socket}
    end
  end

  @doc false
  @spec on_composer_change(term(), term(), term()) :: {:noreply, Phoenix.LiveView.Socket.t()}
  def on_composer_change(message, modal, socket) do
    key = agent_log_key(modal)

    {:noreply,
     socket
     |> assign(:drafts, Map.put(socket.assigns.drafts, key, message))
     |> assign(:chat_errors, Map.delete(socket.assigns.chat_errors, key))}
  end

  @doc false
  @spec on_send_operator_message(term(), term(), term()) :: {:noreply, Phoenix.LiveView.Socket.t()}
  def on_send_operator_message(message, modal, socket) do
    if Map.get(modal, :writable_target?) == true do
      {:noreply, send_operator_message(socket, modal, String.trim(message))}
    else
      {:noreply, put_chat_error(socket, agent_log_key(modal), :ambiguous_identifier)}
    end
  end
end
