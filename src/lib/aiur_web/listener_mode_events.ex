defmodule AiurWeb.ListenerModeEvents do
  @moduledoc "Dashboard mode writes, event confirmation and bounded message receipts."
  require Phoenix.LiveView
  import Phoenix.Component, only: [assign: 3]
  alias Aiur.{AgentEvents, AgentPubSub, Listener}
  alias AiurWeb.DashboardLive.Session
  alias AiurWeb.OperatorControlCenter.OperatorSend

  @spec open(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def open(socket) do
    socket = close(socket)
    id = socket.assigns.conversation_identity.identifier
    AgentPubSub.subscribe_listen_mode(id)
    token = make_ref()
    Process.send_after(self(), {:listener_refresh, id, token}, 1_000)
    socket |> assign(:listener_identifier, id) |> assign(:listener_timer, token) |> refresh()
  end

  @spec close(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def close(socket) do
    if id = socket.assigns[:listener_identifier], do: Phoenix.PubSub.unsubscribe(Aiur.PubSub, AgentEvents.listen_mode_topic(id))
    socket |> assign(:listener_identifier, nil) |> assign(:listener_view, :unavailable) |> assign(:listener_feedback, %{}) |> assign(:listener_receipts, []) |> assign(:listener_receipts_busy, false)
  end

  @spec refresh(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def refresh(socket) do
    incoming = Map.get(socket.assigns[:conversation_row] || %{}, :listener, :unavailable)
    current = socket.assigns[:listener_view]
    assign(socket, :listener_view, reconcile_view(current, incoming))
  end

  defp reconcile_view(%{version: current_version} = current, %{version: incoming_version} = incoming) do
    if current_version > incoming_version || (current_version == incoming_version && older_observation?(incoming[:observed_at], current[:mode_observed_at])) do
      Map.merge(incoming, Map.take(current, [:requested, :effective, :effective_reason, :version, :actor, :support, :mode_observed_at]))
    else
      incoming
    end
  end

  defp reconcile_view(_current, incoming), do: incoming

  defp older_observation?(%DateTime{} = incoming, %DateTime{} = event), do: DateTime.before?(incoming, event)
  defp older_observation?(_incoming, %DateTime{}), do: true
  defp older_observation?(_incoming, _event), do: false

  @spec change(map(), Phoenix.LiveView.Socket.t()) :: {:noreply, Phoenix.LiveView.Socket.t()}
  def change(params, socket) do
    with true <- socket.assigns.writable && Session.dashboard_writable?(),
         %{writable_target?: true} = composer <- socket.assigns.agent_log_modal,
         %{routing: :listener} = view <- socket.assigns[:listener_view],
         true <- view[:freshness] not in [:stale, :offline],
         false <- socket.assigns[:listener_feedback][:state] == :pending,
         {version, ""} <- parse_version(params["expected_version"]),
         mode when mode in [:sync, :steer, :async] <- parse_mode(params["mode"]) do
      key = "dashboard-mode-" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
      result = safe(fn -> Listener.set_mode(OperatorSend.target(composer), mode, expected_version: version, idempotency_key: key, actor: :human) end)
      {:noreply, changed(socket, result, mode)}
    else
      _denied -> {:noreply, socket}
    end
  end

  @spec retry(Phoenix.LiveView.Socket.t()) :: {:noreply, Phoenix.LiveView.Socket.t()}
  def retry(socket) do
    case socket.assigns[:agent_log_modal] do
      %{writable_target?: true} = composer ->
        refreshed(socket, safe(fn -> Listener.get_mode(OperatorSend.target(composer)) end))

      _none ->
        {:noreply, socket}
    end
  end

  defp refreshed(socket, {:ok, record}), do: {:noreply, socket |> put_record(record) |> assign(:listener_feedback, %{})}
  defp refreshed(socket, _error), do: {:noreply, assign(socket, :listener_feedback, %{state: :error})}

  defp changed(socket, {:ok, record}, mode) do
    Process.send_after(self(), {:listener_timeout, socket.assigns.listener_identifier, record.version}, 5_000)
    left = socket.assigns.listener_view[:requested] == :async && mode != :async
    assign(socket, :listener_feedback, %{state: :pending, version: record.version, choice: mode, left_async: left})
  end

  defp changed(socket, {:error, {:mode_conflict, winner}}, mode),
    do: socket |> put_record(winner) |> assign(:listener_feedback, %{state: :conflict, choice: mode})

  defp changed(socket, _error, _mode), do: assign(socket, :listener_feedback, %{state: :error})
  defp parse_version(value) when is_binary(value), do: Integer.parse(value)
  defp parse_version(_invalid), do: :error

  defp parse_mode("sync"), do: :sync
  defp parse_mode("async"), do: :async
  defp parse_mode("steer"), do: :steer
  defp parse_mode(_invalid), do: nil

  @spec info(term(), Phoenix.LiveView.Socket.t()) :: {:noreply, Phoenix.LiveView.Socket.t()}
  def info({:listen_mode_changed, id, record}, %{assigns: %{listener_identifier: id}} = socket) do
    current = socket.assigns[:listener_view]

    if is_map(current) && record.version < current.version do
      {:noreply, socket}
    else
      feedback = socket.assigns.listener_feedback
      confirmed = feedback[:state] == :pending && record.version >= feedback.version
      next = if confirmed, do: %{left_async: feedback[:left_async]}, else: feedback
      {:noreply, socket |> put_record(record) |> assign(:listener_feedback, next)}
    end
  end

  def info({:listener_timeout, id, version}, %{assigns: %{listener_identifier: id, listener_feedback: %{state: :pending, version: version}}} = socket),
    do: {:noreply, assign(socket, :listener_feedback, %{state: :error})}

  def info({:listener_refresh, id, token}, %{assigns: %{listener_identifier: id, listener_timer: token}} = socket) do
    Process.send_after(self(), {:listener_refresh, id, token}, 1_000)
    {:noreply, socket |> assign(:now, DateTime.utc_now()) |> start_receipt_read(id, token)}
  end

  def info(_old, socket), do: {:noreply, socket}

  defp start_receipt_read(%{assigns: %{listener_receipts_busy: true}} = socket, _id, _token), do: socket

  defp start_receipt_read(socket, id, token) do
    receipts = socket.assigns.listener_receipts

    socket
    |> assign(:listener_receipts_busy, true)
    |> Phoenix.LiveView.start_async({:listener_receipts, id, token}, fn -> Enum.map(receipts, &observe_receipt/1) end)
  end

  @spec finish(term(), term(), Phoenix.LiveView.Socket.t()) :: {:noreply, Phoenix.LiveView.Socket.t()}
  def finish({:listener_receipts, id, token}, result, %{assigns: %{listener_identifier: id, listener_timer: token}} = socket) do
    observed =
      case result do
        {:ok, receipts} -> receipts |> Enum.filter(&is_integer(&1.request_id)) |> Map.new(&{&1.request_id, &1})
        _error -> %{}
      end

    receipts = Enum.map(socket.assigns.listener_receipts, &Map.get(observed, &1.request_id, &1))
    {:noreply, socket |> assign(:listener_receipts, receipts) |> assign(:listener_receipts_busy, false)}
  end

  def finish(_key, _result, socket), do: {:noreply, socket}

  @spec sent(Phoenix.LiveView.Socket.t(), term()) :: Phoenix.LiveView.Socket.t()
  def sent(socket, result) do
    receipt = %{request_id: request_id(result), receipt: Listener.receipt_for_send_result(result)}
    assign(socket, :listener_receipts, Enum.take([receipt | socket.assigns[:listener_receipts] || []], 20))
  end

  defp request_id({:ok, id}), do: id
  defp request_id(_error), do: nil

  defp observe_receipt(%{receipt: state} = receipt) when state in [:read, :failed], do: receipt

  defp observe_receipt(%{request_id: id} = receipt) when is_integer(id) do
    case safe(fn -> Listener.receipt(id, 100) end) do
      {:ok, record} -> Map.merge(receipt, record)
      _unavailable -> Map.put(receipt, :receipt, :unknown)
    end
  end

  defp observe_receipt(receipt), do: receipt

  defp put_record(socket, record) do
    base = if is_map(socket.assigns[:listener_view]), do: socket.assigns.listener_view, else: %{}
    assign(socket, :listener_view, Map.merge(base, Map.put(record, :mode_observed_at, DateTime.utc_now())))
  end

  defp safe(fun) do
    fun.()
  rescue
    _error -> {:error, :unavailable}
  catch
    :exit, _reason -> {:error, :unavailable}
  end
end
