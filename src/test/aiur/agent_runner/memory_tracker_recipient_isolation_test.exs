defmodule Aiur.AgentRunner.MemoryTrackerRecipientIsolationTest do
  use ExUnit.Case, async: false

  alias Aiur.Memory.Tracker

  test "a process-local recipient wins over a colliding global recipient" do
    parent = self()

    global_recipient =
      spawn(fn ->
        receive do
          message -> send(parent, {:global, message})
        end
      end)

    Process.put(:memory_tracker_recipient, self())
    Application.put_env(:aiur, :memory_tracker_recipient, global_recipient)

    try do
      assert :ok = Tracker.create_comment("TL-2806-isolated", "test event")
      assert_receive {:memory_tracker_comment, "TL-2806-isolated", "test event"}, 1000
      refute_receive {:global, _message}, 0
    after
      Process.delete(:memory_tracker_recipient)
      Application.delete_env(:aiur, :memory_tracker_recipient)
      Process.exit(global_recipient, :kill)
    end
  end
end
