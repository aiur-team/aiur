defmodule Aiur.HandoffAbortTest do
  use ExUnit.Case, async: true

  alias Aiur.AgentRunner.Handoff

  test "abort_all waits until every runner confirms it resumed" do
    parent = self()

    runner =
      spawn(fn ->
        receive do
          {:handoff_abort, from, ref} ->
            send(parent, {:abort_received, self()})

            receive do
              :restore -> send(from, {:handoff_aborted, ref})
            end
        end
      end)

    task = Task.async(fn -> Handoff.abort_all([runner], 1_000) end)

    assert_receive {:abort_received, ^runner}, 1_000
    refute Task.yield(task, 20)
    send(runner, :restore)
    assert :ok = Task.await(task)
  end
end
