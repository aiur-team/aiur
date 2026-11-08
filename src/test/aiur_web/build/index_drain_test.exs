defmodule AiurWeb.Build.IndexDrainTest do
  use ExUnit.Case, async: true
  alias AiurWeb.Build.Index.Drain

  @signals %{running_changed: [:now, :planned], build_queue_changed: [:queue, :planned], poll_state_changed: [:capacity]}

  test "one handled signal consumes a whole queued burst and merges its parts" do
    for n <- 1..5_000, do: send(self(), {:running_changed, n})
    send(self(), {:build_queue_changed, %{}})
    send(self(), :fleet_changed)
    send(self(), :flush)

    keys = Drain.keys(@signals, :running_changed)

    assert Enum.sort(keys) == [:capacity, :now, :planned, :queue]
    assert {:message_queue_len, 1} = Process.info(self(), :message_queue_len)
    assert_received :flush
  end

  test "a lone signal returns just its own parts" do
    assert Drain.keys(@signals, :poll_state_changed) == [:capacity]
  end
end
