defmodule Aiur.ExecutorWakeInboxTest do
  use Aiur.TestSupport

  alias Aiur.ExecutorWakeInbox

  setup do
    root = Path.join(System.tmp_dir!(), "aiur-wake-inbox-#{System.unique_integer([:positive])}")

    opts = [
      name: __MODULE__,
      debounce_ms: 1_000,
      path: Path.join(root, "wakes.ndjson"),
      cursor_path: Path.join(root, "cursor.json"),
      pending_path: Path.join(root, "pending.json")
    ]

    on_exit(fn -> File.rm_rf!(root) end)
    %{opts: opts}
  end

  test "coalesces forty events across sixteen tickets", %{opts: opts} do
    start_supervised!({ExecutorWakeInbox, opts})

    for id <- 1..40 do
      ticket = Integer.to_string(rem(id, 16) + 1)
      :ok = ExecutorWakeInbox.enqueue(record(id, ticket), __MODULE__)
    end

    Process.sleep(1_100)
    records = ExecutorWakeInbox.pending(__MODULE__)
    assert length(records) == 16
    assert Enum.sum(Enum.map(records, & &1["count"])) == 40
  end

  test "coalesces by topic class and ticket while keeping the latest identifiers", %{opts: opts} do
    start_supervised!({ExecutorWakeInbox, opts})
    first_seen = "2026-08-16T01:00:00Z"
    last_seen = "2026-08-16T01:00:01Z"

    first = record(1, "42") |> Map.put("head_sha", String.duplicate("a", 40)) |> Map.put("first_seen_at", first_seen)
    latest = record(2, "42") |> Map.put("head_sha", String.duplicate("b", 40)) |> Map.put("last_seen_at", last_seen)

    ci =
      record(3, "42")
      |> Map.put("topic", "ticket.42.ci.failed")
      |> Map.put("topic_class", "ticket.ci.failed")

    :ok = ExecutorWakeInbox.enqueue(first, __MODULE__)
    :ok = ExecutorWakeInbox.enqueue(latest, __MODULE__)
    :ok = ExecutorWakeInbox.enqueue(ci, __MODULE__)
    Process.sleep(1_100)

    records = ExecutorWakeInbox.pending(__MODULE__)
    assert length(records) == 2

    push = Enum.find(records, &(&1["topic_class"] == "ticket.branch.push"))
    assert push["event_id"] == 2
    assert push["head_sha"] == String.duplicate("b", 40)
    assert push["first_seen_at"] == first_seen
    assert push["last_seen_at"] == last_seen
    assert push["count"] == 2
  end

  test "serves concurrent waiters when a wake arrives late", %{opts: opts} do
    opts = Keyword.put(opts, :debounce_ms, 100)
    start_supervised!({ExecutorWakeInbox, opts})
    first = Task.async(fn -> ExecutorWakeInbox.wait(1_000, __MODULE__) end)
    second = Task.async(fn -> ExecutorWakeInbox.wait(1_000, __MODULE__) end)
    Process.sleep(20)
    :ok = ExecutorWakeInbox.enqueue(record(10, "42"), __MODULE__)

    assert {:ok, [%{"ticket" => "42"}]} = Task.await(first)
    assert {:ok, [%{"ticket" => "42"}] = records} = Task.await(second)
    assert :ok = ExecutorWakeInbox.acknowledge(records, __MODULE__)
  end

  test "timeout leaves a later wake unread", %{opts: opts} do
    opts = Keyword.put(opts, :debounce_ms, 20)
    start_supervised!({ExecutorWakeInbox, opts})
    started_at = System.monotonic_time(:millisecond)
    assert :timeout = ExecutorWakeInbox.wait(1_000, __MODULE__)
    assert System.monotonic_time(:millisecond) - started_at >= 900
    refute File.exists?(opts[:cursor_path])
    :ok = ExecutorWakeInbox.enqueue(record(11, "43"), __MODULE__)
    Process.sleep(30)
    assert {:ok, [%{"event_id" => 11}] = records} = ExecutorWakeInbox.wait(100, __MODULE__)
    assert :ok = ExecutorWakeInbox.acknowledge(records, __MODULE__)
  end

  test "acknowledging a high source event does not skip a later lower source event", %{opts: opts} do
    opts = Keyword.put(opts, :debounce_ms, 20)
    start_supervised!({ExecutorWakeInbox, opts})

    :ok = ExecutorWakeInbox.enqueue(record(100, "42"), __MODULE__)
    Process.sleep(30)

    assert {:ok, [%{"wake_id" => 1, "event_id" => 100}] = first} =
             ExecutorWakeInbox.wait(100, __MODULE__)

    :ok = ExecutorWakeInbox.enqueue(record(10, "43"), __MODULE__)
    Process.sleep(30)
    assert :ok = ExecutorWakeInbox.acknowledge(first, __MODULE__)

    assert {:ok, [%{"wake_id" => 2, "event_id" => 10}] = second} =
             ExecutorWakeInbox.wait(100, __MODULE__)

    assert :ok = ExecutorWakeInbox.acknowledge(second, __MODULE__)
    assert :ok = ExecutorWakeInbox.acknowledge(first, __MODULE__)
    assert {:ok, %{"last_seen_wake_id" => 2}} = Aiur.JsonStore.read(opts[:cursor_path])
    assert ExecutorWakeInbox.pending(__MODULE__) == []
  end

  test "normal shutdown flushes a debounce window for restart", %{opts: opts} do
    pid = start_supervised!({ExecutorWakeInbox, Keyword.put(opts, :debounce_ms, 60_000)})
    :ok = ExecutorWakeInbox.enqueue(record(12, "44"), __MODULE__)
    GenServer.stop(pid)
    stop_supervised!(ExecutorWakeInbox)

    start_supervised!({ExecutorWakeInbox, opts}, id: :restarted_wake_inbox)
    assert {:ok, [%{"event_id" => 12}] = records} = ExecutorWakeInbox.wait(100, __MODULE__)
    assert :ok = ExecutorWakeInbox.acknowledge(records, __MODULE__)
  end

  test "a crash mid-window recovers the durable pending map without duplicates", %{opts: opts} do
    opts = Keyword.put(opts, :debounce_ms, 60_000)
    pid = start_supervised!({ExecutorWakeInbox, opts})
    :ok = ExecutorWakeInbox.enqueue(record(13, "45"), __MODULE__)
    Process.exit(pid, :kill)

    assert eventually(fn ->
             case Process.whereis(__MODULE__) do
               restarted when is_pid(restarted) -> restarted != pid
               _ -> false
             end
           end)

    assert {:ok, [%{"wake_id" => 1, "event_id" => 13}] = records} =
             ExecutorWakeInbox.wait(500, __MODULE__)

    assert :ok = ExecutorWakeInbox.acknowledge(records, __MODULE__)
    assert ExecutorWakeInbox.pending(__MODULE__) == []
    assert opts[:path] |> File.read!() |> String.split("\n", trim: true) |> length() == 1
  end

  test "refuses startup without replacing a corrupt pending store", %{opts: opts} do
    File.mkdir_p!(Path.dirname(opts[:pending_path]))
    corrupt = ~s({"not valid")
    File.write!(opts[:pending_path], corrupt)

    assert {:executor_wake_pending_store_unavailable, %Jason.DecodeError{}} = start_error(opts)

    assert File.read!(opts[:pending_path]) == corrupt
  end

  test "refuses unreadable and wrong-shape pending stores", %{opts: opts} do
    File.mkdir_p!(opts[:pending_path])

    assert start_error(opts) == {:executor_wake_pending_store_unavailable, :eisdir}

    File.rmdir!(opts[:pending_path])
    File.write!(opts[:pending_path], Jason.encode!([]))
    assert start_error(opts) == :invalid_executor_wake_pending_store

    File.write!(opts[:pending_path], Jason.encode!(%{"not-json" => record(1, "42")}))
    assert start_error(opts) == :invalid_executor_wake_pending_store
  end

  test "reaps a dead waiter", %{opts: opts} do
    start_supervised!({ExecutorWakeInbox, opts})
    waiter = spawn(fn -> ExecutorWakeInbox.wait(60_000, __MODULE__) end)
    assert eventually(fn -> map_size(:sys.get_state(__MODULE__).waiters) == 1 end)
    Process.exit(waiter, :kill)
    assert eventually(fn -> :sys.get_state(__MODULE__).waiters == %{} end)
    assert Process.alive?(Process.whereis(__MODULE__))
  end

  test "trims oldest consumed records without deleting unread wakes", %{opts: opts} do
    opts = Keyword.merge(opts, debounce_ms: 20, max_records: 3)
    start_supervised!({ExecutorWakeInbox, opts})

    for id <- 1..3, do: :ok = ExecutorWakeInbox.enqueue(record(id, Integer.to_string(id)), __MODULE__)
    Process.sleep(30)
    assert {:ok, records} = ExecutorWakeInbox.wait(100, __MODULE__)
    assert Enum.map(records, & &1["event_id"]) == [1, 2, 3]
    assert :ok = ExecutorWakeInbox.acknowledge(records, __MODULE__)

    for id <- 4..8, do: :ok = ExecutorWakeInbox.enqueue(record(id, Integer.to_string(id)), __MODULE__)
    Process.sleep(30)
    assert {:ok, records} = ExecutorWakeInbox.wait(100, __MODULE__)
    assert Enum.map(records, & &1["event_id"]) == [4, 5, 6, 7, 8]
    assert :ok = ExecutorWakeInbox.acknowledge(records, __MODULE__)

    journal_ids =
      opts[:path]
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!(&1)["event_id"])

    assert journal_ids == [6, 7, 8]
  end

  defp record(id, ticket) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    %{
      "wake_id" => id,
      "topic" => "ticket.#{ticket}.branch.push",
      "topic_class" => "ticket.branch.push",
      "event_id" => id,
      "ticket" => ticket,
      "count" => 1,
      "first_seen_at" => now,
      "last_seen_at" => now
    }
  end

  defp start_error(opts) do
    previous = Process.flag(:trap_exit, true)
    assert {:error, reason} = ExecutorWakeInbox.start_link(opts)
    Process.flag(:trap_exit, previous)
    reason
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end
end
