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
end
