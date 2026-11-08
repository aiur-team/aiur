defmodule AiurWeb.ExecutorVoiceReceiptChannelTest do
  use ExUnit.Case, async: true
  alias AiurWeb.ExecutorVoiceReceiptChannel, as: Channel
  alias AiurWeb.FinancialDataAccess
  alias Phoenix.Socket.Message

  defmodule Serializer do
    def encode!(message), do: message
  end

  test "receipt transport requires authenticated dashboard authority" do
    assert {:error, %{reason: "Unauthorized receipt access."}} = Channel.join("voice:executor_receipts", %{}, socket())
  end

  test "receipt-only transport polls after the voice session ends and stops polling acknowledged items" do
    waiting = socket(fn [7] -> [%{id: 7, ack_status: "waiting"}] end)
    assert {:noreply, pending} = Channel.handle_info(:check_receipts, waiting)
    assert_received %Message{topic: "voice:executor_receipts", event: "receipt_status", payload: %{id: 7, ack_status: "waiting"}}
    assert pending.assigns.event_ids == MapSet.new([7])
    Channel.terminate(:normal, pending)
    acknowledged = %{pending | assigns: %{pending.assigns | timer: nil, receipt_status_fun: fn [7] -> [%{id: 7, wake_id: 2, ack_status: "received"}] end}}
    assert {:noreply, complete} = Channel.handle_info(:check_receipts, acknowledged)
    assert_received %Message{event: "receipt_status", payload: %{id: 7, wake_id: 2, ack_status: "received"}}
    assert complete.assigns.event_ids == MapSet.new()
    assert complete.assigns.timer == nil
    refute_received {:"$gen_call", _, _}
  end

  test "watch capacity and authentication changes fail closed" do
    full = %{socket() | assigns: %{socket().assigns | event_ids: MapSet.new(1..20)}}
    assert {:noreply, ^full} = Channel.handle_in("watch", %{"id" => 21}, full)
    assert_received %Message{event: "receipt_status", payload: %{id: 21, ack_status: "unavailable"}}
    assert {:stop, :normal, ^full} = Channel.handle_info({FinancialDataAccess, :configuration_changed, "new"}, full)
  end

  defp socket(status_fun \\ fn _ -> [] end) do
    %Phoenix.Socket{
      topic: "voice:executor_receipts",
      joined: true,
      transport_pid: self(),
      serializer: Serializer,
      assigns: %{event_ids: MapSet.new([7]), timer: nil, generation: "current", receipt_status_fun: status_fun}
    }
  end
end
