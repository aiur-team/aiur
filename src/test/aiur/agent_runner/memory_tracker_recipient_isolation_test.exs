defmodule Aiur.AgentRunner.MemoryTrackerRecipientIsolationTest do
  use ExUnit.Case, async: false

  alias Aiur.Memory.Tracker

  test "a process-local recipient wins over a colliding global recipient" do
    parent = self()
    previous_recipient = Application.fetch_env(:aiur, :memory_tracker_recipient)

    global_recipient =
      start_supervised!(
        {Task,
         fn ->
           receive do
             message -> send(parent, {:global, message})
           end
         end}
      )

    Process.put(:memory_tracker_recipient, self())
    Application.put_env(:aiur, :memory_tracker_recipient, global_recipient)

    try do
      assert :ok = Tracker.create_comment("TL-2806-isolated", "test event")
      assert_receive {:memory_tracker_comment, "TL-2806-isolated", "test event"}, 1000
      refute_receive {:global, _message}, 0
    after
      Process.delete(:memory_tracker_recipient)

      case previous_recipient do
        {:ok, recipient} -> Application.put_env(:aiur, :memory_tracker_recipient, recipient)
        :error -> Application.delete_env(:aiur, :memory_tracker_recipient)
      end
    end
  end
end
