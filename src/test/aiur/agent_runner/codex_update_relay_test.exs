defmodule Aiur.AgentRunner.CodexUpdateRelayTest do
  use ExUnit.Case, async: true

  alias Aiur.AgentRunner.CodexUpdateRelay, as: Relay
  alias Aiur.AgentRunner.MessageHandler
  alias Aiur.Issue

  @interval Relay.coalesce_interval_ms()

  defp delta(text \\ "tok") do
    %{
      event: :notification,
      timestamp: DateTime.utc_now(),
      codex_app_server_pid: "4242",
      payload: %{
        "method" => "item/agentMessage/delta",
        "params" => %{"itemId" => "item-1", "delta" => text}
      },
      raw: text
    }
  end

  defp turn_completed do
    %{
      event: :notification,
      timestamp: DateTime.utc_now(),
      codex_app_server_pid: "4242",
      payload: %{"method" => "turn/completed", "usage" => %{"input_tokens" => 10, "output_tokens" => 3}}
    }
  end

  describe "control?/1" do
    test "a bare streamed text delta is not control traffic" do
      refute Relay.control?(delta())
    end

    test "anything that is not a recognised delta method is control traffic" do
      assert Relay.control?(%{event: :notification, payload: %{"method" => "turn/started"}})
      assert Relay.control?(%{event: :agent_message, body: "done"})
      assert Relay.control?(%{event: :session_started, session_id: "s-1"})
    end

    test "a delta that carries usage, rate limits or a session id stays control traffic" do
      assert Relay.control?(Map.put(delta(), :usage, %{"total_tokens" => 5}))
      assert Relay.control?(Map.put(delta(), :rate_limits, %{"primary" => %{"used_percent" => 10}}))
      assert Relay.control?(Map.put(delta(), :session_id, "s-2"))
    end

    test "the constant app-server pid every message carries does not make a delta control traffic" do
      # Every app-server message carries `codex_app_server_pid` from the port
      # metadata. If that counted as control, nothing would ever coalesce.
      refute Relay.control?(delta())
    end
  end

  describe "relay/4" do
    test "control messages are always forwarded, however many arrive" do
      for _ <- 1..50, do: assert(:sent = Relay.relay(self(), "gid-ctl", turn_completed(), 0))

      assert 50 == drain_count("gid-ctl")
    end

    test "a burst of deltas inside one window collapses to a single message" do
      results = for _ <- 1..500, do: Relay.relay(self(), "gid-burst", delta(), 0)

      assert Enum.count(results, &(&1 == :sent)) == 1
      assert drain_count("gid-burst") == 1
    end

    test "liveness still refreshes once per interval" do
      # Ten intervals of solid streaming: ten liveness updates reach the
      # orchestrator instead of ten thousand.
      sent =
        for tick <- 0..9, _ <- 1..1_000 do
          Relay.relay(self(), "gid-live", delta(), tick * @interval)
        end

      assert Enum.count(sent, &(&1 == :sent)) == 10
      assert drain_count("gid-live") == 10
    end

    test "a delta arriving just before the window closes is still coalesced" do
      assert :sent = Relay.relay(self(), "gid-edge", delta(), 0)
      assert :coalesced = Relay.relay(self(), "gid-edge", delta(), @interval - 1)
      assert :sent = Relay.relay(self(), "gid-edge", delta(), @interval)
    end

    test "windows are per issue, so one chatty agent cannot mute another" do
      assert :sent = Relay.relay(self(), "gid-a", delta(), 0)
      assert :coalesced = Relay.relay(self(), "gid-a", delta(), 1)
      assert :sent = Relay.relay(self(), "gid-b", delta(), 1)
    end

    test "a nil recipient is a no-op" do
      assert :sent = Relay.relay(nil, "gid-nil", turn_completed(), 0)
      refute_receive {:codex_worker_update, "gid-nil", _}, 50
    end
  end

  describe "through MessageHandler.build/6" do
    # This is the fault as measured on the live daemon: 9,313 of 10,456 messages
    # queued on Aiur.Orchestrator were `item/agentMessage/delta`. Without the
    # relay, every one of these 2,000 deltas lands in the recipient's mailbox.
    test "a streaming turn does not fill the orchestrator mailbox" do
      issue = %Issue{id: "gid-relay-int", identifier: nil}
      handler = MessageHandler.build(self(), issue, nil, nil, "codex")

      for _ <- 1..2_000, do: handler.(delta())

      queued = drain_count("gid-relay-int")

      assert queued >= 1, "liveness must still reach the orchestrator"

      # 2,000 sends take well under a second, so at most a handful of 250ms
      # windows can have opened. The pre-fix number here is 2,000.
      assert queued <= 20, "expected coalesced deltas, got #{queued}"
    end

    test "a turn-completed message is never coalesced away" do
      issue = %Issue{id: "gid-relay-ctl", identifier: nil}
      handler = MessageHandler.build(self(), issue, nil, nil, "codex")

      handler.(delta())
      handler.(turn_completed())

      assert drain_count("gid-relay-ctl") == 2
    end
  end

  defp drain_count(issue_id, acc \\ 0) do
    receive do
      {:codex_worker_update, ^issue_id, _message} -> drain_count(issue_id, acc + 1)
    after
      0 -> acc
    end
  end
end
