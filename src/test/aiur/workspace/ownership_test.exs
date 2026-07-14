defmodule Aiur.Workspace.OwnershipTest do
  use ExUnit.Case, async: true

  alias Aiur.Workspace.Ownership

  test "a generation excludes a competing runner until it releases" do
    ticket = "ownership-#{System.unique_integer([:positive])}"

    assert {:ok, lease} = Ownership.claim(ticket)
    assert {:ok, %{phase: :provisioning}} = Ownership.current(ticket)
    assert {:ok, active_lease} = Ownership.activate(lease)

    contender = Task.async(fn -> Ownership.claim(ticket) end)

    assert {:error, {:workspace_owned, {:ok, %{generation: generation, phase: :active}}}} =
             Task.await(contender)

    assert generation == lease.generation
    assert :ok = Ownership.release(active_lease)
    assert :none = Ownership.current(ticket)
  end

  test "a crashed runner releases its generation automatically" do
    ticket = "ownership-crash-#{System.unique_integer([:positive])}"
    parent = self()

    owner =
      spawn(fn ->
        send(parent, {:claimed, Ownership.claim(ticket)})
        Process.sleep(:infinity)
      end)

    assert_receive {:claimed, {:ok, _lease}}
    monitor = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}
    _registry_state = :sys.get_state(Aiur.Workspace.Ownership.Registry)
    assert :none = Ownership.current(ticket)
  end
end
