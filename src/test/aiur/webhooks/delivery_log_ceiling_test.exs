defmodule Aiur.Webhooks.DeliveryLogCeilingTest do
  use ExUnit.Case, async: false

  alias Aiur.Webhooks.DeliveryLog
  alias Aiur.Webhooks.DeliveryLogCeiling

  setup do
    dir = Aiur.TestSupport.tmp_root!("aiur-webhook-ceiling")
    clock = :counters.new(1, [])
    :counters.put(clock, 1, 1_700_000_000_000)
    sorts = :counters.new(1, [])
    test_pid = self()
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)

    sort_fun = fn entries ->
      :counters.add(sorts, 1, 1)
      DeliveryLogCeiling.sort_entries(entries)
    end

    log =
      start_supervised!(
        {DeliveryLog,
         [
           name: :delivery_log_ceiling_test,
           state_dir: dir,
           clock_fun: fn -> :counters.get(clock, 1) end,
           max_entries: 10,
           eviction_low_watermark: 0.8,
           eviction_sort_fun: sort_fun,
           alert_fun: fn topic, message, meta -> send(test_pid, {:alert, topic, message, meta}) end
         ]}
      )

    %{log: log, clock: clock, sorts: sorts}
  end

  test "crossing the ceiling evicts a batch of oldest entries and alerts once", %{log: log, clock: clock} do
    Enum.each(1..10, fn index ->
      assert :new == DeliveryLog.claim(:delivery, "c-#{index}", log)
      :counters.add(clock, 1, 1000)
    end)

    assert :new == DeliveryLog.claim(:delivery, "c-11", log)
    assert :new == DeliveryLog.claim(:delivery, "c-12", log)
    assert DeliveryLog.size(log) == 9

    assert_receive {:alert, "webhook_delivery_log.ceiling_exceeded", message, _meta}, 1000
    assert message =~ "duplicate protection is degraded"
    Enum.each(4..11, fn index -> assert {:duplicate, _at} = DeliveryLog.claim(:delivery, "c-#{index}", log) end)
    assert {:duplicate, _at} = DeliveryLog.claim(:delivery, "c-12", log)
    Enum.each(1..3, fn index -> assert :new == DeliveryLog.claim(:delivery, "c-#{index}", log) end)
    refute_received {:alert, "webhook_delivery_log.ceiling_exceeded", _message, _meta}
  end

  test "a batch eviction sorts once until capacity is crossed again", %{log: log, clock: clock, sorts: sorts} do
    Enum.each(1..10, fn index ->
      assert :new == DeliveryLog.claim(:delivery, "batch-#{index}", log)
      :counters.add(clock, 1, 1000)
    end)

    assert :new == DeliveryLog.claim(:delivery, "batch-11", log)
    assert :new == DeliveryLog.claim(:delivery, "batch-12", log)
    assert :new == DeliveryLog.claim(:delivery, "batch-13", log)

    assert :counters.get(sorts, 1) == 1
  end
end
