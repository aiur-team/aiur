defmodule Aiur.Opencode.AttachQueueTest do
  use ExUnit.Case, async: false

  alias Aiur.Opencode.AttachQueue

  describe "without a running GenServer" do
    test "snapshot/0 returns empty default" do
      refute Process.whereis(AttachQueue)
      snap = AttachQueue.snapshot()
      assert snap.base_url == nil
      assert snap.pending == []
      assert snap.inflight == nil
      assert snap.priorities == []
      assert snap.cancellations == []
    end

    test "enqueue/1 is a no-op" do
      refute Process.whereis(AttachQueue)
      assert AttachQueue.enqueue("issue-1") == :ok
    end

    test "cancel/1 is a no-op" do
      refute Process.whereis(AttachQueue)
      assert AttachQueue.cancel("issue-1") == :ok
    end

    test "request_priority/1 reports :unknown" do
      refute Process.whereis(AttachQueue)
      assert AttachQueue.request_priority("issue-1") == {:ok, :unknown}
    end
  end

  describe "attach_topic/0" do
    test "is a stable string for PubSub subscribers" do
      assert is_binary(AttachQueue.attach_topic())
      assert AttachQueue.attach_topic() != ""
    end
  end
end
