defmodule Aiur.SignalTest do
  use Aiur.TestSupport

  import ExUnit.CaptureLog

  alias Aiur.RunTelemetry.Lifecycle
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

  defmodule LifecycleSink do
    def record(ticket, attempt_id, event, boundary, metadata, opts) do
      send(self(), {:record, ticket, attempt_id, event, boundary, metadata, opts})
      :ok
    end

    def observe_backend_message(ticket, attempt_id, backend, message, opts) do
      send(self(), {:backend, ticket, attempt_id, backend, message, opts})
      :ok
    end
  end

  describe "lifecycle telemetry" do
    test "lifecycle delegates all six arguments to the sink" do
      Application.put_env(:aiur, :signal, lifecycle_sink: LifecycleSink)

      assert :ok = Signal.lifecycle("1", "1:a", :dispatch, :point, %{k: 1}, recorder: :r)
      assert_received {:record, "1", "1:a", :dispatch, :point, %{k: 1}, [recorder: :r]}
    end

    test "backend_message delegates all five arguments to the sink" do
      Application.put_env(:aiur, :signal, lifecycle_sink: LifecycleSink)

      assert :ok = Signal.backend_message("1", "1:a", "codex", %{"m" => 1}, tracker: :t)
      assert_received {:backend, "1", "1:a", "codex", %{"m" => 1}, [tracker: :t]}
    end

    test "missing lifecycle sink is a silent :ok" do
      Application.put_env(:aiur, :signal, [])

      log =
        capture_log(fn ->
          assert :ok = Signal.lifecycle("1", nil, :dispatch, :point)
          assert :ok = Signal.backend_message("1", nil, "codex", %{})
        end)

      assert log == ""
    end

    test "reason_class maps each reason shape and Lifecycle delegates to it" do
      for {reason, class} <- [
            {:boom, "boom"},
            {%ArgumentError{}, "argument_error"},
            {{:down, :x}, "down"},
            {{:down, :x, :y}, "down"},
            {503, "status_503"},
            {"text", "unknown"}
          ] do
        assert Signal.reason_class(reason) == class
        assert Lifecycle.reason_class(reason) == class
      end
    end

    test "new_attempt_id is ticket-prefixed and unique" do
      id = Signal.new_attempt_id("42")
      assert String.starts_with?(id, "42:")
      refute id == Signal.new_attempt_id("42")
      assert String.starts_with?(Lifecycle.new_attempt_id("42"), "42:")
    end
  end
end
