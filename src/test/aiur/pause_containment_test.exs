defmodule Aiur.PauseContainmentTest do
  use ExUnit.Case, async: true

  alias Aiur.PauseContainment

  test "reaps only the armed generation after its bounded fallback" do
    parent = self()
    name = Module.concat(__MODULE__, "Containment#{System.unique_integer([:positive])}")

    {:ok, _pid} =
      PauseContainment.start_link(
        name: name,
        grace_ms: 60_000,
        reap_fun: fn group ->
          send(parent, {:reaped, group})
          {:ok, :reaped}
        end,
        event_fun: fn stage, payload -> send(parent, {:event, stage, payload}) end,
        notify_fun: fn identifier, generation, result -> send(parent, {:notified, identifier, generation, result}) end
      )

    assert {:ok, handle} = PauseContainment.register(name, "repo#886", 321, 321, workspace: "/workspace/886")
    assert {:ok, ^handle} = PauseContainment.arm(name, "repo#886")
    assert_receive {:event, :cooperative, %{identifier: "repo#886"}}

    send(name, {:fallback, "repo#886", handle.generation})

    assert_receive {:event, :fallback_started, %{process_group_id: 321}}
    assert_receive {:reaped, 321}
    assert_receive {:event, :fallback_succeeded, %{generation: generation}}
    assert generation == handle.generation
    assert_receive {:notified, "repo#886", ^generation, :contained}
    refute PauseContainment.paused?(name, handle)
  end

  test "ignores a stale fallback after cooperative confirmation" do
    name = Module.concat(__MODULE__, "Confirmed#{System.unique_integer([:positive])}")

    {:ok, _pid} =
      PauseContainment.start_link(
        name: name,
        grace_ms: 60_000,
        reap_fun: fn _group -> flunk("stale fallback reaped a cooperatively paused session") end
      )

    assert {:ok, handle} = PauseContainment.register(name, "repo#887", 322, 322)
    assert {:ok, ^handle} = PauseContainment.arm(name, "repo#887")
    assert :ok = PauseContainment.confirm(name, handle)
    assert PauseContainment.paused?(name, handle)

    send(name, {:fallback, "repo#887", handle.generation})
    refute_receive _message, 30
  end

  test "retains the latch when fallback reaping fails until the same generation is released" do
    name = Module.concat(__MODULE__, "Failed#{System.unique_integer([:positive])}")

    {:ok, _pid} =
      PauseContainment.start_link(
        name: name,
        grace_ms: 60_000,
        reap_fun: fn _group -> {:error, :group_alive} end
      )

    assert {:ok, handle} = PauseContainment.register(name, "repo#888", 323, 323)
    assert {:ok, ^handle} = PauseContainment.arm(name, "repo#888")

    send(name, {:fallback, "repo#888", handle.generation})
    assert_eventually(fn -> PauseContainment.paused?(name, handle) end)
    assert :ok = PauseContainment.release(name, handle)
    refute PauseContainment.paused?(name, handle)
  end

  test "arms a registered canonical identifier from its issue-number target" do
    name = Module.concat(__MODULE__, "Target#{System.unique_integer([:positive])}")
    {:ok, _pid} = PauseContainment.start_link(name: name, grace_ms: 60_000)

    assert {:ok, handle} = PauseContainment.register(name, "repo#889", 324, 324)
    assert {:ok, ^handle} = PauseContainment.arm_target(name, "889")
    assert PauseContainment.paused?(name, handle)
  end

  test "a stuck reap does not block arming a sibling agent" do
    parent = self()
    name = Module.concat(__MODULE__, "Concurrent#{System.unique_integer([:positive])}")

    {:ok, _pid} =
      PauseContainment.start_link(
        name: name,
        grace_ms: 60_000,
        reap_fun: fn group ->
          # Simulate a slow TERM->KILL grace wait that blocks until released.
          send(parent, {:reaping, group, self()})

          receive do
            :finish -> :ok
          after
            5_000 -> :ok
          end

          {:ok, :reaped}
        end
      )

    assert {:ok, handle_a} = PauseContainment.register(name, "repo#100", 500, 500)
    assert {:ok, ^handle_a} = PauseContainment.arm(name, "repo#100")
    assert {:ok, handle_b} = PauseContainment.register(name, "repo#200", 600, 600)

    send(name, {:fallback, "repo#100", handle_a.generation})
    assert_receive {:reaping, 500, worker}, 1_000

    # A's reap is stuck in its worker; the GenServer must still service B.
    assert {:ok, ^handle_b} = PauseContainment.arm(name, "repo#200")
    assert PauseContainment.paused?(name, handle_b)
    # A stays latched while it is reaping.
    assert PauseContainment.paused?(name, handle_a)

    send(worker, :finish)
    assert_eventually(fn -> not PauseContainment.paused?(name, handle_a) end)
    assert PauseContainment.paused?(name, handle_b)
  end

  defp assert_eventually(assertion, attempts \\ 20)

  defp assert_eventually(assertion, attempts) when attempts > 0 do
    if assertion.() do
      :ok
    else
      Process.sleep(10)
      assert_eventually(assertion, attempts - 1)
    end
  end

  defp assert_eventually(_assertion, 0), do: flunk("condition was not met")
end
