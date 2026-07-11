defmodule Aiur.AgentRunner.MessageHandlerTest do
  use ExUnit.Case, async: true

  alias Aiur.{AgentPubSub, Issue}
  alias Aiur.AgentRunner.MessageHandler

  describe "build/6" do
    test "returns a closure that forwards codex_worker_update to recipient" do
      issue = %Issue{id: "gid-mh-01", identifier: "MH-01"}
      handler = MessageHandler.build(self(), issue, nil, nil, "codex")
      message = %{event: :agent_message, body: "hello"}

      handler.(message)

      assert_receive {:codex_worker_update, "gid-mh-01", _normalized}, 2_000
    end

    test "no-ops codex_worker_update for nil recipient" do
      issue = %Issue{id: "gid-mh-02", identifier: "MH-02"}
      handler = MessageHandler.build(nil, issue, nil, nil, "codex")

      assert :ok = handler.(%{event: :agent_message, body: "test"})
      refute_receive {:codex_worker_update, _, _}, 100
    end

    test "broadcasts a transcript event for an issue with binary identifier" do
      identifier = "MH-t-#{System.unique_integer([:positive])}"
      issue = %Issue{id: "gid-mh-03", identifier: identifier}
      :ok = AgentPubSub.subscribe_agent(identifier)

      handler = MessageHandler.build(nil, issue, nil, nil, "codex")
      handler.(%{event: :agent_message, body: "transcript content"})

      assert_receive {:transcript_event, _event}, 2_000
    end

    test "skips transcript broadcast for an empty body" do
      identifier = "MH-empty-#{System.unique_integer([:positive])}"
      issue = %Issue{id: "gid-mh-04", identifier: identifier}
      :ok = AgentPubSub.subscribe_agent(identifier)

      handler = MessageHandler.build(nil, issue, nil, nil, "codex")
      handler.(%{event: :agent_message, body: ""})

      refute_receive {:transcript_event, _event}, 500
    end

    test "broadcasts a turn event when turn_id is binary and event kind is terminal" do
      identifier = "MH-turn-#{System.unique_integer([:positive])}"
      issue = %Issue{id: "gid-mh-05", identifier: identifier}
      :ok = AgentPubSub.subscribe_agent(identifier)

      turn_id = "t#{System.unique_integer([:positive])}"
      handler = MessageHandler.build(nil, issue, nil, nil, "codex", turn_id)
      handler.(%{event: :turn_completed})

      assert_receive {:turn_event, ^identifier, :turn_completed, _payload}, 2_000
    end

    test "does not send a turn event when turn_id is nil" do
      identifier = "MH-noturn-#{System.unique_integer([:positive])}"
      issue = %Issue{id: "gid-mh-06", identifier: identifier}
      :ok = AgentPubSub.subscribe_agent(identifier)

      handler = MessageHandler.build(nil, issue, nil, nil, "codex")
      handler.(%{event: :turn_completed})

      refute_receive {:turn_event, _, _, _}, 200
    end

    test "tolerates string-keyed messages (event_kind uses MapAccess)" do
      issue = %Issue{id: "gid-mh-07", identifier: "MH-07"}
      handler = MessageHandler.build(self(), issue, nil, nil, "codex")
      message = %{"event" => "agent_message", "body" => "string-keyed"}

      handler.(message)

      assert_receive {:codex_worker_update, "gid-mh-07", _normalized}, 2_000
    end
  end

  describe "send_control_state/3" do
    test "sends :paused worker_control_state to a pid recipient" do
      issue = %Issue{id: "gid-sc-01"}

      MessageHandler.send_control_state(self(), issue, :paused)

      assert_receive {:worker_control_state, "gid-sc-01", :paused}, 2_000
    end

    test "sends :working worker_control_state to a pid recipient" do
      issue = %Issue{id: "gid-sc-02"}

      MessageHandler.send_control_state(self(), issue, :working)

      assert_receive {:worker_control_state, "gid-sc-02", :working}, 2_000
    end

    test "preserves a worker pause payload" do
      issue = %Issue{id: "gid-sc-03"}
      pause_payload = %{kind: :usage_limit_exhausted, reset_hint: "23:00 UTC"}

      MessageHandler.send_control_state(self(), issue, :paused, pause_payload)

      assert_receive {:worker_control_state, "gid-sc-03", :paused, ^pause_payload}, 2_000
    end

    test "no-ops for a nil recipient" do
      issue = %Issue{id: "gid-sc-03"}
      assert :ok = MessageHandler.send_control_state(nil, issue, :paused)
    end

    test "no-ops for a non-binary issue id" do
      issue = %Issue{id: nil, identifier: "SC-04"}
      assert :ok = MessageHandler.send_control_state(self(), issue, :paused)
      refute_receive {:worker_control_state, _, _}, 100
    end

    test "no-ops for an unrecognized status" do
      issue = %Issue{id: "gid-sc-05"}
      assert :ok = MessageHandler.send_control_state(self(), issue, :unknown_status)
      refute_receive {:worker_control_state, _, _}, 100
    end
  end

  describe "send_worker_runtime_info/4" do
    test "sends worker_runtime_info to a pid recipient with binary workspace" do
      issue = %Issue{id: "gid-wri-01"}

      MessageHandler.send_worker_runtime_info(self(), issue, "host-1", "/workspace/path")

      assert_receive {:worker_runtime_info, "gid-wri-01", %{worker_host: "host-1", workspace_path: "/workspace/path"}},
                     2_000
    end

    test "no-ops when workspace is nil" do
      issue = %Issue{id: "gid-wri-02"}
      assert :ok = MessageHandler.send_worker_runtime_info(self(), issue, "host", nil)
      refute_receive {:worker_runtime_info, _, _}, 100
    end

    test "no-ops for a nil recipient" do
      issue = %Issue{id: "gid-wri-03"}
      assert :ok = MessageHandler.send_worker_runtime_info(nil, issue, "host", "/path")
    end

    test "no-ops for a non-binary issue id" do
      issue = %Issue{id: nil, identifier: "WRI-04"}
      assert :ok = MessageHandler.send_worker_runtime_info(self(), issue, "host", "/path")
      refute_receive {:worker_runtime_info, _, _}, 100
    end
  end
end
