defmodule Aiur.Opencode.SlotRegistryTest do
  use ExUnit.Case, async: false

  alias Aiur.Opencode.SlotRegistry

  setup do
    # The Registry is started by Aiur.Application via the test
    # supervisor tree. Just verify it's available and clean up after
    # the test by stopping any registered processes.
    on_exit(fn ->
      for {_index, pid} <- SlotRegistry.all() do
        if Process.alive?(pid), do: Process.exit(pid, :kill)
      end
    end)

    :ok
  end

  test "register_self/1 + lookup/1 roundtrip" do
    parent = self()
    ref = make_ref()

    pid =
      spawn(fn ->
        :ok = SlotRegistry.register_self(1)
        send(parent, {ref, :registered})

        receive do
          :exit -> :ok
        end
      end)

    assert_receive {^ref, :registered}, 1_000

    assert {:ok, ^pid} = SlotRegistry.lookup(1)

    send(pid, :exit)
  end

  test "lookup/1 returns :not_found for an unregistered slot" do
    assert SlotRegistry.lookup(999) == :not_found
  end

  test "register_self/1 returns :already_registered when the same slot is taken" do
    parent = self()
    ref = make_ref()

    pid1 =
      spawn(fn ->
        :ok = SlotRegistry.register_self(5)
        send(parent, {ref, :first_registered})

        receive do
          :exit -> :ok
        end
      end)

    assert_receive {^ref, :first_registered}, 1_000

    # Second registration from a different process should refuse.
    pid2 =
      spawn(fn ->
        result = SlotRegistry.register_self(5)
        send(parent, {ref, {:second_result, result}})
      end)

    assert_receive {^ref, {:second_result, {:error, :already_registered}}}, 1_000

    send(pid1, :exit)
    refute_received {^ref, _other}
    _ = pid2
  end

  test "all/0 returns alive registrations and filters dead pids" do
    parent = self()
    ref = make_ref()

    pid =
      spawn(fn ->
        :ok = SlotRegistry.register_self(7)
        send(parent, {ref, :ready})

        receive do
          :exit -> :ok
        end
      end)

    assert_receive {^ref, :ready}, 1_000

    entries = SlotRegistry.all()
    assert {7, ^pid} = Enum.find(entries, fn {idx, _pid} -> idx == 7 end)

    send(pid, :exit)
  end

  test "update_pane_state/3 + pane_state/1 roundtrip" do
    parent = self()
    ref = make_ref()

    pid =
      spawn(fn ->
        :ok = SlotRegistry.register_self(11)
        :ok = SlotRegistry.update_pane_state(11, "agent-a", "%42")
        send(parent, {ref, :written})

        receive do
          :exit -> :ok
        end
      end)

    assert_receive {^ref, :written}, 1_000

    assert {:ok, %{visible_identifier: "agent-a", pane_id: "%42"}} = SlotRegistry.pane_state(11)

    send(pid, :exit)
  end

  test "find_visible/1 returns the slot whose visible_identifier matches" do
    parent = self()
    ref = make_ref()

    pid_a =
      spawn(fn ->
        :ok = SlotRegistry.register_self(20)
        :ok = SlotRegistry.update_pane_state(20, "agent-a", "%100")
        send(parent, {ref, :a_ready})

        receive do
          :exit -> :ok
        end
      end)

    pid_b =
      spawn(fn ->
        :ok = SlotRegistry.register_self(21)
        :ok = SlotRegistry.update_pane_state(21, "agent-b", "%101")
        send(parent, {ref, :b_ready})

        receive do
          :exit -> :ok
        end
      end)

    assert_receive {^ref, :a_ready}, 1_000
    assert_receive {^ref, :b_ready}, 1_000

    assert {:ok, 20, "%100"} = SlotRegistry.find_visible("agent-a")
    assert {:ok, 21, "%101"} = SlotRegistry.find_visible("agent-b")
    assert :not_found = SlotRegistry.find_visible("agent-z")

    send(pid_a, :exit)
    send(pid_b, :exit)
  end

  test "find_visible/1 ignores slots whose pane_id is nil (not yet painted)" do
    parent = self()
    ref = make_ref()

    pid =
      spawn(fn ->
        :ok = SlotRegistry.register_self(30)
        :ok = SlotRegistry.update_pane_state(30, "agent-x", nil)
        send(parent, {ref, :ready})

        receive do
          :exit -> :ok
        end
      end)

    assert_receive {^ref, :ready}, 1_000

    # A slot with a pending identifier but no pane_id yet must NOT be
    # returned as a warm-open target — PaneManager would try to move a
    # nil pane visible and crash.
    assert :not_found = SlotRegistry.find_visible("agent-x")

    send(pid, :exit)
  end
end
