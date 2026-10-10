defmodule Aiur.SignalTest do
  use Aiur.TestSupport

  import ExUnit.CaptureLog

  alias Aiur.Signal
  alias AiurWeb.ObservabilityPubSub

  defmodule Sink do
    def emit_system(topic, opts) do
      send(self(), {:system, self(), topic, opts})
      Keyword.get(opts, :result, :ok)
    end

    def emit_custom(topic, message, opts) do
      send(self(), {:custom, self(), topic, message, opts})
      Keyword.get(opts, :result, :ok)
    end
  end

  defmodule RaisingSink do
    def emit_system(_topic, _opts), do: raise("sink failed")
  end

  setup do
    previous = Application.fetch_env(:aiur, :signal)

    on_exit(fn ->
      case previous do
        {:ok, config} -> Application.put_env(:aiur, :signal, config)
        :error -> Application.delete_env(:aiur, :signal)
      end
    end)

    :ok
  end

  test "composition root registers Alerts as the sink" do
    assert Application.fetch_env!(:aiur, :signal)[:alert_sink] == Aiur.Alerts
  end

  test "alert delegates once synchronously and returns the sink result" do
    Application.put_env(:aiur, :signal, alert_sink: Sink)
    opts = [message: "system message", result: {:error, :sink_failed}]
    caller = self()
    assert {:error, :sink_failed} = Signal.alert("system.example", opts)
    assert_received {:system, ^caller, "system.example", ^opts}
    refute_received {:system, _, _, _}
    assert :ok = Signal.alert("system.default")
    assert_received {:system, ^caller, "system.default", []}
  end

  test "agent_alert forwards topic, message and options synchronously" do
    Application.put_env(:aiur, :signal, alert_sink: Sink)
    opts = [reason: "reason", result: {:error, :sink_failed}]
    caller = self()
    assert {:error, :sink_failed} = Signal.agent_alert("phase.work.start", "agent message", opts)
    assert_received {:custom, ^caller, "phase.work.start", "agent message", ^opts}
    refute_received {:custom, _, _, _, _}
    assert :ok = Signal.agent_alert("phase.work.end", "done")
    assert_received {:custom, ^caller, "phase.work.end", "done", []}
  end

  test "absent registration returns a visible error for both alert entry points" do
    for config <- [:absent, [], [alert_sink: nil]] do
      if config == :absent, do: Application.delete_env(:aiur, :signal), else: Application.put_env(:aiur, :signal, config)

      log =
        capture_log(fn ->
          assert {:error, :signal_sink_unregistered} = Signal.alert("system.missing")
          assert {:error, :signal_sink_unregistered} = Signal.agent_alert("agent.missing", "message")
        end)

      assert log =~ "signal: no alert sink registered; dropped system.missing"
      assert log =~ "signal: no alert sink registered; dropped agent.missing"
    end
  end

  test "sink exceptions propagate to the caller" do
    Application.put_env(:aiur, :signal, alert_sink: RaisingSink)
    assert_raise RuntimeError, "sink failed", fn -> Signal.alert("system.failure") end
  end

  test "default refresh interoperates with web subscribers" do
    assert :ok = ObservabilityPubSub.subscribe()
    probe = make_ref()
    assert :ok = Phoenix.PubSub.broadcast(Aiur.PubSub, "observability:dashboard", {:signal_topic_probe, probe})
    assert_received {:signal_topic_probe, ^probe}
    assert :ok = Signal.refresh()
    assert_received {:observability_updated, id}
    assert is_integer(id) and id > 0
  end

  test "named refresh preserves web compatibility and fresh event ids" do
    pubsub = __MODULE__.PubSub
    start_supervised!({Phoenix.PubSub, name: pubsub})
    assert :ok = Signal.subscribe_refresh(pubsub)
    assert :ok = ObservabilityPubSub.broadcast_update(pubsub)
    assert_received {:observability_updated, first}
    assert :ok = Signal.refresh(pubsub)
    assert_received {:observability_updated, second}
    assert second > first
  end

  test "refresh is a no-op when the PubSub server is down" do
    refute Process.whereis(__MODULE__.Unavailable)
    assert :ok = Signal.refresh(__MODULE__.Unavailable)
  end

  # Future layering regression guard; these paths must use the low-layer port.
  test "core has no reference to the web refresh helper" do
    files = Path.wildcard(Path.expand("../../lib/aiur/**/*.ex", __DIR__))
    assert files != []
    for file <- files, do: refute(File.read!(file) =~ "AiurWeb.ObservabilityPubSub", file)
  end
end
