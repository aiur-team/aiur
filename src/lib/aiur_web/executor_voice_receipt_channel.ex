defmodule AiurWeb.ExecutorVoiceReceiptChannel do
  @moduledoc "Authenticated acknowledgement updates that outlive microphone sessions."
  use Phoenix.Channel

  alias Aiur.VoiceConversation.{Receipts, Selection}
  alias AiurWeb.{EndpointConfig, FinancialDataAccess}

  @interval_ms 1_000
  @max_watches 20

  @impl true
  def join("voice:executor_receipts", payload, %{assigns: %{voice_authority: authority}} = socket) do
    with true <- EndpointConfig.get(:dashboard_writable) == true,
         {:ok, generation} <- FinancialDataAccess.current_configuration_generation(),
         true <- generation == authority.configuration_generation,
         {:ok, ids} <- event_ids(payload) do
      :ok = FinancialDataAccess.subscribe_to_configuration_changes()
      {:ok, socket |> assign(:generation, generation) |> assign(:event_ids, ids) |> assign(:timer, nil) |> schedule()}
    else
      _invalid -> {:error, %{reason: "Receipt access is unavailable. Reload and sign in again."}}
    end
  end

  def join(_topic, _payload, _socket), do: {:error, %{reason: "Unauthorized receipt access."}}

  @impl true
  def handle_in("comparison_list", _payload, socket), do: comparison_snapshot(socket)

  def handle_in("comparison_rate", %{"id" => id, "rating" => rating, "note" => note}, socket) do
    case Selection.rate(id, rating, note) do
      :ok ->
        comparison_snapshot(socket)

      _ ->
        push(socket, "comparison_error", %{reason: "Rating could not be saved. Choose 1–5 and a note under 2000 bytes."})
        {:noreply, socket}
    end
  end

  def handle_in("watch", %{"id" => id}, socket) when is_integer(id) and id > 0 do
    ids = MapSet.put(socket.assigns.event_ids, id)

    if MapSet.size(ids) <= @max_watches do
      {:noreply, socket |> assign(:event_ids, ids) |> schedule()}
    else
      push(socket, "receipt_status", %{id: id, ack_status: "unavailable"})
      {:noreply, socket}
    end
  end

  def handle_in(_event, _payload, socket), do: {:noreply, socket}

  defp comparison_snapshot(socket) do
    case Selection.snapshot() do
      {:ok, snapshot} -> push(socket, "comparison", snapshot)
      _ -> push(socket, "comparison_error", %{reason: "Comparison usage is unavailable; Start will refuse unreadable usage."})
    end

    {:noreply, socket}
  end

  @impl true
  def handle_info(:check_receipts, socket) do
    ids = MapSet.to_list(socket.assigns.event_ids)
    receipts = status(socket, ids)
    Enum.each(receipts, &push(socket, "receipt_status", &1))
    received = for %{id: id, ack_status: "received"} <- receipts, do: id
    pending = Enum.reduce(received, socket.assigns.event_ids, &MapSet.delete(&2, &1))
    {:noreply, socket |> assign(:event_ids, pending) |> assign(:timer, nil) |> schedule()}
  end

  def handle_info({FinancialDataAccess, :configuration_changed, generation}, %{assigns: %{generation: generation}} = socket),
    do: {:noreply, socket}

  def handle_info({FinancialDataAccess, :configuration_changed, _generation}, socket), do: {:stop, :normal, socket}
  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, socket) do
    if timer = socket.assigns[:timer], do: Process.cancel_timer(timer)
    :ok
  end

  defp status(socket, ids), do: (socket.assigns[:receipt_status_fun] || (&Receipts.status/1)).(ids)
  defp schedule(%{assigns: %{timer: timer}} = socket) when not is_nil(timer), do: socket

  defp schedule(socket) do
    if MapSet.size(socket.assigns.event_ids) == 0,
      do: socket,
      else: assign(socket, :timer, Process.send_after(self(), :check_receipts, @interval_ms))
  end

  defp event_ids(%{"event_ids" => ids}) when is_list(ids) and length(ids) <= @max_watches do
    if Enum.all?(ids, &(is_integer(&1) and &1 > 0)), do: {:ok, MapSet.new(ids)}, else: {:error, :invalid_ids}
  end

  defp event_ids(%{"event_ids" => _invalid}), do: {:error, :invalid_ids}
  defp event_ids(%{}), do: {:ok, MapSet.new()}
  defp event_ids(_payload), do: {:error, :invalid_ids}
end
