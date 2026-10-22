defmodule Aiur.Webhooks.DeliveryLogCeilingTest do
  use ExUnit.Case, async: false

  alias Aiur.Webhooks.DeliveryLog

  setup do
    dir = Aiur.TestSupport.tmp_root!("aiur-webhook-ceiling")
    clock = :counters.new(1, [])
    :counters.put(clock, 1, 1_700_000_000_000)
    test_pid = self()
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)

    log =
      start_supervised!(
        {DeliveryLog,
         [
           name: :delivery_log_ceiling_test,
           state_dir: dir,
           clock_fun: fn -> :counters.get(clock, 1) end,
           max_entries: 10,
           eviction_low_watermark: 0.8,
           alert_fun: fn topic, message, meta -> send(test_pid, {:alert, topic, message, meta}) end
         ]}
      )

    %{log: log}
  end

  test "crossing the ceiling evicts a batch of oldest entries and alerts once", %{log: log} do
    Enum.each(1..10, fn index -> assert :new == DeliveryLog.claim(:delivery, "c-#{index}", log) end)

    assert :new == DeliveryLog.claim(:delivery, "c-11", log)
    assert :new == DeliveryLog.claim(:delivery, "c-12", log)
    assert DeliveryLog.size(log) == 9

    assert_receive {:alert, "webhook_delivery_log.ceiling_exceeded", message, _meta}, 1000
    assert message =~ "duplicate protection is degraded"
    assert :new == DeliveryLog.claim(:delivery, "c-1", log)
    assert {:duplicate, _at} = DeliveryLog.claim(:delivery, "c-12", log)
    refute_received {:alert, "webhook_delivery_log.ceiling_exceeded", _message, _meta}
  end
end
