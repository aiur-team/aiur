defmodule AiurWeb.EventsChannel do
  @moduledoc false
  use Phoenix.Channel
  alias Aiur.Events.Export
  alias AiurWeb.{EventsQuery, FinancialDataAccess}

  @impl true
  def join("events:feed", payload, %{assigns: %{events_authenticated: true}} = socket) do
    with true <- Export.enabled?(),
         {:ok, query} <- EventsQuery.join(payload),
         :ok <- subscribe(),
         :ok <- authorize(socket) do
      schedule_auth(socket.assigns.events_expires_at_ms)
      send(self(), :backlog)
      {:ok, assign(socket, replaying: true, query: query, last_pushed_seq: query.after, epoch: Keyword.get(query.opts, :epoch))}
    else
      false -> {:error, %{reason: "feature_disabled"}}
      {:error, reason} -> {:error, %{reason: Atom.to_string(reason)}}
    end
  end

  def join("events:feed", _payload, _socket), do: {:error, %{reason: "unauthorized"}}

  @impl true
  def handle_in(_event, _payload, socket), do: {:reply, {:error, %{reason: "read_only"}}, socket}

  @impl true
  def handle_info(:backlog, socket) do
    Process.send_after(self(), :heartbeat, 25_000)
    drain(socket)
  end

  def handle_info(:replay, socket), do: drain(socket)

  def handle_info({:export_appended, _head, _epoch}, socket), do: live(socket)

  def handle_info(:heartbeat, socket) do
    case live(socket) do
      {:noreply, socket} ->
        push(socket, "heartbeat", %{head_seq: Export.status().head_seq, observed_at: DateTime.to_iso8601(DateTime.utc_now())})
        Process.send_after(self(), :heartbeat, 25_000)
        {:noreply, socket}

      stopped ->
        stopped
    end
  end

  def handle_info(:auth_expiring, socket) do
    push(socket, "record", %{type: "auth_expiring", in_ms: max(socket.assigns.events_expires_at_ms - System.system_time(:millisecond), 0)})
    {:noreply, socket}
  end

  def handle_info(:auth_expired, socket), do: {:stop, :normal, socket}
  def handle_info({FinancialDataAccess, :configuration_changed, generation}, %{assigns: %{events_generation: generation}} = socket), do: {:noreply, socket}
  def handle_info({FinancialDataAccess, :configuration_changed, _generation}, socket), do: {:stop, :normal, socket}
  def handle_info(_message, socket), do: {:noreply, socket}

  defp subscribe do
    :ok = Phoenix.PubSub.subscribe(Aiur.PubSub, "events:export")
    FinancialDataAccess.subscribe_to_configuration_changes()
  end

  defp authorize(socket) do
    generation = socket.assigns.events_generation

    with {:ok, ^generation} <- FinancialDataAccess.current_configuration_generation(),
         true <- socket.assigns.events_expires_at_ms > System.system_time(:millisecond) do
      :ok
    else
      _ -> {:error, :unauthorized}
    end
  end

  defp schedule_auth(expires_at) do
    remaining = max(expires_at - System.system_time(:millisecond), 0)
    Process.send_after(self(), :auth_expired, remaining)
    Process.send_after(self(), :auth_expiring, max(remaining - 30_000, 0))
  end

  defp live(socket) do
    status = Export.status()

    cond do
      not Export.enabled?() -> stop_error(socket, "feature_disabled")
      status.state != :available -> stop_error(socket, "events_unavailable")
      socket.assigns.replaying -> {:noreply, socket}
      status.head_seq - socket.assigns.last_pushed_seq > 2_000 -> reset(socket, status)
      true -> drain(socket)
    end
  end

  defp drain(socket) do
    opts = if socket.assigns.epoch, do: [epoch: socket.assigns.epoch], else: []

    case Export.read(socket.assigns.last_pushed_seq, 500, socket.assigns.query.patterns, opts) do
      {:ok, page} -> push_page(socket, page)
      {:reset, meta} -> reset(socket, meta)
      {:error, :events_unavailable} -> stop_error(socket, "events_unavailable")
    end
  end

  defp push_page(socket, page) do
    Enum.each(page.records, &push(socket, "record", &1))
    more? = length(page.records) == 500
    cursor = if more?, do: List.last(page.records)["seq"], else: page.head_seq
    socket = assign(socket, last_pushed_seq: cursor, epoch: page.epoch, replaying: more?)
    if more?, do: send(self(), :replay)
    {:noreply, socket}
  end

  defp reset(socket, meta) do
    push(socket, "record", Map.take(meta, [:oldest_seq, :head_seq, :epoch]) |> Map.put(:type, "reset"))
    {:noreply, assign(socket, last_pushed_seq: meta.head_seq, epoch: meta.epoch, replaying: false)}
  end

  defp stop_error(socket, code) do
    push(socket, "record", %{type: "error", code: code})
    {:stop, :normal, socket}
  end
end
