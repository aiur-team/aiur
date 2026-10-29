defmodule Aiur.VoiceConversation.ReceiptsTest do
  use Aiur.TestSupport

  alias Aiur.ExecutorWakeInbox
  import Aiur.TestSupport.WakeInboxAck

  setup do
    root = Aiur.TestSupport.tmp_root!("voice-receipts")
    opts = [name: __MODULE__, debounce_ms: 60_000, path: Path.join(root, "wakes.ndjson"), cursor_path: Path.join(root, "cursor.json"), pending_path: Path.join(root, "pending.json")]
    start_supervised!({ExecutorWakeInbox, opts})
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)
    :ok
  end

  test "each handoff waits until its persisted wake is acknowledged by the Executor" do
    first = 1_800_000_000_000_001
    second = first + 1
    for id <- [first, second], do: :ok = ExecutorWakeInbox.enqueue(record(id), __MODULE__)
    assert {:ok, [%{id: ^first, ack_status: "waiting"}, %{id: ^second, ack_status: "waiting"}]} = receipts([first, second])
    flush()
    records = ExecutorWakeInbox.pending(__MODULE__)
    assert [%{"event_id" => ^first, "wake_id" => first_wake}, %{"event_id" => ^second, "wake_id" => second_wake}] = records
    refute first_wake == first
    assert {:ok, [%{ack_status: "waiting"}, %{ack_status: "waiting"}]} = receipts([first, second])
    :ok = ack_as_owner([hd(records)], __MODULE__)
    assert {:ok, [%{id: ^first, wake_id: ^first_wake, ack_status: "received", observed_at: observed}, %{id: ^second, wake_id: ^second_wake, ack_status: "waiting"}]} = receipts([first, second])
    assert {:ok, _, 0} = DateTime.from_iso8601(observed)
    :ok = ack_as_owner(records, __MODULE__)
    assert {:ok, [%{ack_status: "received"}, %{ack_status: "missing", wake_id: nil}]} = receipts([second, first + 100])
  end

  test "a cursor advanced by wake eviction never proves the missing handoff was received" do
    first = 1_800_000_000_000_010
    :ok = ExecutorWakeInbox.enqueue(record(first), __MODULE__)
    flush()
    :sys.replace_state(__MODULE__, &%{&1 | max_records: 1})
    :ok = ExecutorWakeInbox.enqueue(record(first + 1), __MODULE__)
    flush()
    assert :sys.get_state(__MODULE__).cursor > 0
    assert {:ok, [%{id: ^first, ack_status: "missing", wake_id: nil}]} = receipts([first])
  end

  defp receipts(ids), do: ExecutorWakeInbox.voice_receipts(ids, __MODULE__)

  defp flush do
    send(Process.whereis(__MODULE__), :flush)
    :sys.get_state(__MODULE__)
  end

  defp record(id) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()
    %{"wake_id" => id, "event_id" => id, "topic" => "executor.voice.session_ended", "topic_class" => "executor.voice", "ticket" => nil, "count" => 1, "first_seen_at" => now, "last_seen_at" => now}
  end
end
