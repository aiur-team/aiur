defmodule Aiur.Webhooks.DeliveryLogTest do
  use ExUnit.Case, async: false

  alias Aiur.Webhooks.DeliveryLog

  @hour_ms 60 * 60 * 1000

  setup do
    dir = Path.join(System.tmp_dir!(), "aiur-webhook-deliveries-#{System.pid()}-#{System.unique_integer([:positive])}")
    clock = :counters.new(1, [])
    :counters.put(clock, 1, 1_700_000_000_000)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir, clock: clock}
  end

  defp start_log(context, id, opts \\ []) do
    clock = context.clock
    test_pid = self()

    defaults = [
      name: :"delivery_log_#{id}_#{System.unique_integer([:positive])}",
      state_dir: context.dir,
      clock_fun: fn -> :counters.get(clock, 1) end,
      alert_fun: fn topic, message, meta -> send(test_pid, {:alert, topic, message, meta}) end
    ]

    start_supervised!({DeliveryLog, Keyword.merge(defaults, opts)}, id: id)
  end

  defp advance_clock(%{clock: clock}, ms), do: :counters.add(clock, 1, ms)

  test "the same delivery id claimed twice is admitted exactly once", context do
    log = start_log(context, :first)

    assert :new == DeliveryLog.claim(:delivery, "d-1", log)
    assert {:duplicate, first_seen_at} = DeliveryLog.claim(:delivery, "d-1", log)
    assert {:duplicate, ^first_seen_at} = DeliveryLog.claim(:delivery, "d-1", log)
    assert :new == DeliveryLog.claim(:delivery, "d-2", log)
  end

  test "delivery ids and semantic event keys are claimed independently", context do
    log = start_log(context, :first)

    assert :new == DeliveryLog.claim(:delivery, "same-id", log)
    assert :new == DeliveryLog.claim(:event, "same-id", log)
  end

  test "an oversized key stays bounded without losing its identity", context do
    log = start_log(context, :first)
    long = String.duplicate("a", 4000)

    assert :new == DeliveryLog.claim(:event, long, log)
    assert {:duplicate, _at} = DeliveryLog.claim(:event, long, log)
    assert :new == DeliveryLog.claim(:event, long <> "b", log)

    path = Path.join(context.dir, "webhook_deliveries.ndjson")
    assert path |> File.read!() |> String.split("\n", trim: true) |> Enum.all?(&(byte_size(&1) < 1000))
  end

  test "claims survive a restart", context do
    log = start_log(context, :first)
    assert :new == DeliveryLog.claim(:delivery, "d-restart", log)
    stop_supervised!(:first)

    restarted = start_log(context, :second)
    assert {:duplicate, _at} = DeliveryLog.claim(:delivery, "d-restart", restarted)
  end

  test "entries older than the retention window are evicted and re-admitted", context do
    log = start_log(context, :first)

    assert :new == DeliveryLog.claim(:delivery, "d-old", log)
    advance_clock(context, DeliveryLog.retention_ms() + 1)

    assert DeliveryLog.size(log) == 0
    assert :new == DeliveryLog.claim(:delivery, "d-old", log)
  end

  test "an expired entry does not survive a restart", context do
    log = start_log(context, :first)
    assert :new == DeliveryLog.claim(:delivery, "d-expired", log)
    stop_supervised!(:first)

    advance_clock(context, DeliveryLog.retention_ms() + 1)
    restarted = start_log(context, :second)

    assert DeliveryLog.size(restarted) == 0
    assert :new == DeliveryLog.claim(:delivery, "d-expired", restarted)
  end

  test "a burst of redeliveries evicts nothing still inside the retention window", context do
    log = start_log(context, :first)

    assert :new == DeliveryLog.claim(:delivery, "d-first", log)
    advance_clock(context, @hour_ms)

    Enum.each(1..500, fn index ->
      assert :new == DeliveryLog.claim(:delivery, "burst-#{index}", log)
    end)

    DeliveryLog.sweep(log)

    assert {:duplicate, _at} = DeliveryLog.claim(:delivery, "d-first", log)
    assert DeliveryLog.size(log) == 501
  end

  test "the memory ceiling evicts the oldest entries and alerts once", context do
    log = start_log(context, :first, max_entries: 3)

    Enum.each(1..3, fn index ->
      assert :new == DeliveryLog.claim(:delivery, "c-#{index}", log)
      advance_clock(context, 1000)
    end)

    assert :new == DeliveryLog.claim(:delivery, "c-4", log)

    assert_receive {:alert, "webhook_delivery_log.ceiling_exceeded", ceiling_message, _meta}
    assert ceiling_message =~ "duplicate protection is degraded"

    # The oldest entry was evicted before its window expired; the newest survived.
    assert :new == DeliveryLog.claim(:delivery, "c-1", log)
    assert {:duplicate, _at} = DeliveryLog.claim(:delivery, "c-4", log)

    refute_receive {:alert, "webhook_delivery_log.ceiling_exceeded", _message, _meta}, 50
  end

  test "the ordering watermark only advances forwards", context do
    log = start_log(context, :first)

    assert :ok == DeliveryLog.advance(:issue_labels, "owner/repo#7", 2000, log)
    assert {:stale, 2000} = DeliveryLog.advance(:issue_labels, "owner/repo#7", 1000, log)
    assert {:stale, 2000} = DeliveryLog.advance(:issue_labels, "owner/repo#7", 2000, log)
    assert :ok == DeliveryLog.advance(:issue_labels, "owner/repo#7", 3000, log)
    assert DeliveryLog.lookup(:issue_labels, "owner/repo#7", log) == 3000
  end

  test "watermarks survive a restart", context do
    log = start_log(context, :first)
    assert :ok == DeliveryLog.advance(:issue_labels, "owner/repo#7", 5000, log)
    stop_supervised!(:first)

    restarted = start_log(context, :second)
    assert DeliveryLog.lookup(:issue_labels, "owner/repo#7", restarted) == 5000
    assert {:stale, 5000} = DeliveryLog.advance(:issue_labels, "owner/repo#7", 4000, restarted)
  end

  test "an append failure degrades to in-memory dedupe, alerts, and reports health", context do
    log = start_log(context, :first, append_fun: fn _path, _record -> {:error, :eacces} end)

    assert :new == DeliveryLog.claim(:delivery, "d-degraded", log)
    assert {:duplicate, _at} = DeliveryLog.claim(:delivery, "d-degraded", log)

    assert_receive {:alert, "webhook_delivery_log.unavailable", message, _meta}
    assert message =~ "no longer survives restart"
    assert {:append_failed, :eacces} = DeliveryLog.health(log)
  end

  test "a corrupt stream keeps the validated prefix and alerts", context do
    log = start_log(context, :first)
    assert :new == DeliveryLog.claim(:delivery, "d-good", log)
    stop_supervised!(:first)

    path = Path.join(context.dir, "webhook_deliveries.ndjson")
    File.write!(path, File.read!(path) <> "not json\n")

    restarted = start_log(context, :second)

    assert {:corrupt, 2, _reason} = DeliveryLog.health(restarted)
    assert {:duplicate, _at} = DeliveryLog.claim(:delivery, "d-good", restarted)
    assert_receive {:alert, "webhook_delivery_log.corrupted", _message, _meta}
  end

  test "an unresolvable state directory fails open rather than dropping deliveries", context do
    file = Path.join(System.tmp_dir!(), "aiur-webhook-not-a-dir-#{System.pid()}-#{System.unique_integer([:positive])}")
    File.write!(file, "")
    on_exit(fn -> File.rm_rf!(file) end)

    log = start_log(context, :first, state_dir: file)

    assert {:unavailable, _reason} = DeliveryLog.health(log)
    assert :new == DeliveryLog.claim(:delivery, "d-open", log)
    assert_receive {:alert, "webhook_delivery_log.unavailable", _message, _meta}
  end

  test "the append stream is compacted once it outgrows the live set", context do
    log = start_log(context, :first, compaction_floor: 10)
    path = Path.join(context.dir, "webhook_deliveries.ndjson")

    Enum.each(1..30, fn index ->
      assert :ok == DeliveryLog.advance(:issue_labels, "owner/repo#1", index * 1000, log)
    end)

    assert path |> File.read!() |> String.split("\n", trim: true) |> length() == 30

    DeliveryLog.sweep(log)

    assert path |> File.read!() |> String.split("\n", trim: true) |> length() == 1
    assert DeliveryLog.lookup(:issue_labels, "owner/repo#1", log) == 30_000
  end
end
