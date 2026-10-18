defmodule Aiur.Workspace.Ownership.RetentionOrderTest do
  use ExUnit.Case, async: true

  alias Aiur.Workspace.Ownership
  alias Aiur.Workspace.Ownership.Store

  test "publishes the reaping phase before retention alert I/O completes" do
    ticket = "ownership-retention-order-#{System.unique_integer([:positive])}"
    parent = self()

    alert_fun = fn topic, _opts ->
      send(parent, {:retention_alert_started, topic})

      receive do
        :finish_retention_alert -> :ok
      end
    end

    assert {:ok, lease} =
             Ownership.claim(ticket, Aiur.Workspace.Ownership.Registry, retention_alert_fun: alert_fun)

    assert :ok = Ownership.expect_provider(lease)
    release = Task.async(fn -> Ownership.release_and_wait(lease) end)

    assert_receive {:retention_alert_started, "ticket." <> ^ticket <> ".workspace.workspace_lease_retained"}, 2_000
    assert {:ok, %{phase: :reaping, retained_cause: "provider_unrecorded"}} = Ownership.current(ticket)
    assert {:error, {:workspace_owned, {:ok, %{phase: :reaping}}}} = Ownership.claim(ticket)
    refute Task.yield(release, 0)

    send(lease.guardian, :finish_retention_alert)
    Task.shutdown(release, :brutal_kill)
    Process.exit(lease.guardian, :kill)
    assert_eventually(fn -> Ownership.current(ticket) == :none end)
    assert :ok = Store.delete(ticket)
  end

  defp assert_eventually(fun, attempts \\ 40) do
    if fun.() do
      :ok
    else
      assert attempts > 0
      Process.sleep(25)
      assert_eventually(fun, attempts - 1)
    end
  end
end
