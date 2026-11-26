defmodule Aiur.AgentRunner.MessageHandler.SendersTest do
  use ExUnit.Case, async: true

  alias Aiur.AgentRunner.MessageHandler
  alias Aiur.Issue

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

    test "sends :completed worker_control_state to a pid recipient" do
      issue = %Issue{id: "gid-sc-completed"}

      MessageHandler.send_control_state(self(), issue, :completed)

      assert_receive {:worker_control_state, "gid-sc-completed", :completed}, 2_000
    end

    test "preserves a worker pause payload" do
      issue = %Issue{id: "gid-sc-03"}
      pause_payload = %{kind: :usage_limit_exhausted, reset_hint: "23:00 UTC"}

      MessageHandler.send_control_state(self(), issue, :paused, pause_payload)

      assert_receive {:worker_control_state, "gid-sc-03", :paused, ^pause_payload}, 2_000
    end

    test "uses a cause-neutral fallback when a worker pause has no reason" do
      issue = %Issue{id: "gid-sc-unknown"}

      MessageHandler.send_control_state(self(), issue, :paused, %{})

      assert_receive {:worker_control_state, "gid-sc-unknown", :paused, %{kind: :worker_pause_unknown}},
                     2_000
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

  describe "send_dispatch_committed/2" do
    test "sends dispatch_committed to a pid recipient (lifetime commit signal)" do
      issue = %Issue{id: "gid-dc-01"}

      assert :ok = MessageHandler.send_dispatch_committed(self(), issue)
      assert_receive {:dispatch_committed, "gid-dc-01"}, 2_000
    end

    test "no-ops for a nil recipient" do
      issue = %Issue{id: "gid-dc-02"}
      assert :ok = MessageHandler.send_dispatch_committed(nil, issue)
      refute_receive {:dispatch_committed, _}, 100
    end

    test "no-ops for a non-binary issue id" do
      issue = %Issue{id: nil, identifier: "DC-03"}
      assert :ok = MessageHandler.send_dispatch_committed(self(), issue)
      refute_receive {:dispatch_committed, _}, 100
    end
  end
end
