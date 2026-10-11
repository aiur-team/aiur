defmodule Aiur.UsageAggregate.SignalTest do
  use ExUnit.Case, async: false

  alias Aiur.UsageAggregate.Store

  @moduletag :tmp_dir

  defmodule Sink do
    def emit_system(topic, opts) do
      send(Aiur.UsageAggregate.SignalTest, {:signal_alert, topic, opts})
      :ok
    end
  end

  test "default aggregate outage alerts reach the registered signal sink", %{tmp_dir: dir} do
    Process.register(self(), __MODULE__)
    previous = Application.fetch_env!(:aiur, :signal)
    Application.put_env(:aiur, :signal, alert_sink: Sink)
    on_exit(fn -> Application.put_env(:aiur, :signal, previous) end)

    store = start_supervised!({Store, name: nil, state_dir: dir, ledger_server: :absent_signal_test_ledger})
    since = Store.freshness(store).since
    assert %DateTime{} = since
    send(store, {:ledger_unavailable, since})

    assert_receive {:signal_alert, "system.usage_aggregate.source_unavailable", opts}, 1_000
    assert opts[:message] == "Usage aggregate has been disconnected from the ledger for 60 seconds"
    assert opts[:reason] == "Usage totals are stale; subscription retries continue"
    assert opts[:needs_attention] == true
    send(store, {:ledger_unavailable, since})
    _ = Store.snapshot(store)
    refute_received {:signal_alert, _, _}
  end
end
