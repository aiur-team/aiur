defmodule AiurWeb.Conversation.ComposerEvents do
  @moduledoc false
  import Phoenix.Component, only: [assign: 2, assign: 3]
  alias Aiur.Conversation.History
  alias Aiur.Listener
  alias AiurWeb.Conversation.DeliveryOverlay
  alias AiurWeb.Endpoint

  @spec init(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def init(socket) do
    target =
      case History.worker_identity(socket.assigns.id) do
        {:ok, identity} -> identity
        _ -> nil
      end

    socket
    |> assign(writable: writable?(), composer_target: target, draft: "", delivery_overlay: %{}, composer_retry: nil, delivery_timer: nil)
    |> refresh_mode()
  end

  @spec draft(Phoenix.LiveView.Socket.t(), String.t()) :: Phoenix.LiveView.Socket.t()
  def draft(socket, text), do: assign(socket, :draft, text)

  @spec send_message(Phoenix.LiveView.Socket.t(), String.t()) :: Phoenix.LiveView.Socket.t()
  def send_message(socket, text) do
    if (writable?() and socket.assigns.composer_target) && String.trim(text) != "" do
      do_send(socket, text)
    else
      socket
    end
  end

  defp do_send(socket, text) do
    retry = socket.assigns.composer_retry
    id = if retry && retry.text == text, do: retry.id, else: "conversation-" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    fun = Endpoint.config(:conversation_send_fun) || (&Listener.send/3)
    result = safe(fn -> fun.(socket.assigns.composer_target, text, origin: :agent_chat, client_request_id: id) end)
    unknown? = Listener.receipt_for_send_result(result) == :outcome_unknown
    overlay = DeliveryOverlay.put_send(socket.assigns.delivery_overlay, id, text, result, now())

    socket
    |> assign(delivery_overlay: overlay, draft: if(match?({:ok, _}, result), do: "", else: text), composer_retry: if(unknown?, do: %{text: text, id: id}))
    |> refresh_mode()
    |> schedule()
  end

  @spec reconcile(Phoenix.LiveView.Socket.t(), [map()]) :: Phoenix.LiveView.Socket.t()
  def reconcile(socket, entries), do: assign(socket, :delivery_overlay, DeliveryOverlay.reconcile(socket.assigns.delivery_overlay, entries))

  @spec poll(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def poll(socket) do
    fun = Endpoint.config(:conversation_receipt_fun) || (&Listener.receipt(&1, 100))
    old = socket.assigns.delivery_overlay
    overlay = DeliveryOverlay.poll(old, fn id -> safe(fn -> fun.(id) end) end, now())
    failed = Enum.find(Map.values(overlay), fn item -> item.state == :failed && old[item.delivery_id] && old[item.delivery_id].state != :failed end)
    draft = if failed && socket.assigns.draft == "", do: failed.text, else: socket.assigns.draft
    socket |> assign(delivery_overlay: overlay, draft: draft, delivery_timer: nil) |> refresh_mode() |> schedule()
  end

  @spec refresh_mode(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def refresh_mode(socket) do
    fun = Endpoint.config(:conversation_mode_fun) || (&Listener.get_mode/1)
    result = if socket.assigns.composer_target, do: safe(fn -> fun.(socket.assigns.composer_target) end)

    listener =
      case result do
        {:ok, view} -> Map.put(view, :routing, Application.get_env(:aiur, :listener_send_routing, :legacy))
        _ -> nil
      end

    assign(socket, :composer_listener, listener)
  end

  defp schedule(socket) do
    if is_nil(socket.assigns.delivery_timer) && DeliveryOverlay.pending?(socket.assigns.delivery_overlay) do
      assign(socket, :delivery_timer, Process.send_after(self(), :delivery_tick, 2_000))
    else
      socket
    end
  end

  defp writable?, do: Endpoint.config(:dashboard_writable) == true
  defp now, do: System.monotonic_time(:millisecond)

  defp safe(fun) do
    fun.()
  rescue
    _ -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, {:outcome_unknown, %{reason: :unavailable}}}
  end
end
