defmodule Aiur.ExecutorWakeInboxRecoveryTest do
  use Aiur.TestSupport

  alias Aiur.Executor.Claims
  alias Aiur.ExecutorWakeInbox

  setup do
    root = Aiur.TestSupport.tmp_root!("aiur-wake-inbox-recovery")

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

  test "corrupt journal tail is quarantined and the inbox starts", %{opts: opts} do
    good = Jason.encode!(record(1, "42"))
    File.mkdir_p!(Path.dirname(opts[:path]))
    File.write!(opts[:path], good <> "\n{\"not valid\"\n")
    test_pid = self()
    opts = Keyword.put(opts, :alert_fun, fn name, msg, _opts -> send(test_pid, {:alert, name, msg}) end)

    start_supervised!({ExecutorWakeInbox, opts})

    assert [%{"wake_id" => 1}] = ExecutorWakeInbox.pending(__MODULE__)
    assert [quarantined] = Path.wildcard(opts[:path] <> ".corrupt-*")
    assert File.read!(quarantined) =~ "not valid"
    assert_received {:alert, "executor.wakes.journal_quarantined", message}
    assert message =~ "unacknowledged wakes lost"
    refute_received {:alert, _, _}
  end

  test "unreadable journal still stops", %{opts: opts} do
    File.mkdir_p!(opts[:path])
    assert {:not_a_file, _} = start_error(opts)
    assert Path.wildcard(opts[:path] <> ".corrupt-*") == []
  end

  test "three flush failures raise one alert and success resets", %{opts: opts} do
    test_pid = self()
    opts = Keyword.put(opts, :alert_fun, fn name, _msg, _opts -> send(test_pid, {:alert, name}) end)
    start_supervised!({ExecutorWakeInbox, opts})
    :ok = ExecutorWakeInbox.enqueue(record(1, "42"), __MODULE__)
    File.rm!(opts[:path])
    File.mkdir_p!(opts[:path])

    for _ <- 1..4, do: send(__MODULE__, :flush)
    assert :sys.get_state(__MODULE__).flush_failures == 4
    assert_received {:alert, "executor.wakes.flush_failing"}
    refute_received {:alert, _}

    File.rm_rf!(opts[:path])
    send(__MODULE__, :flush)
    assert :sys.get_state(__MODULE__).flush_failures == 0
  end

  test "acknowledge without ownership does not advance the cursor", %{opts: opts} do
    start_supervised!({ExecutorWakeInbox, opts})
    :ok = ExecutorWakeInbox.enqueue(record(1, "42"), __MODULE__)
    send(__MODULE__, :flush)
    assert {:ok, [_] = records} = ExecutorWakeInbox.wait(500, __MODULE__)
    assert {:ok, _claim} = Claims.claim("real-owner")

    assert {:error, {:not_owner, _}} = ExecutorWakeInbox.acknowledge_as("intruder", records, __MODULE__)
    assert ExecutorWakeInbox.cursor(__MODULE__) == 0
  end

  defp start_error(opts) do
    previous = Process.flag(:trap_exit, true)
    assert {:error, reason} = ExecutorWakeInbox.start_link(opts)
    Process.flag(:trap_exit, previous)
    reason
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
end
