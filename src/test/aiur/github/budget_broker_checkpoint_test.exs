defmodule Aiur.GitHub.BudgetBrokerCheckpointTest do
  use ExUnit.Case, async: false

  alias Aiur.GitHub.{Budget, BudgetBroker}
  alias Aiur.TestSupport.Isolation

  test "checkpoint timings are retained after a broker command", %{test: test} do
    root = Aiur.TestSupport.tmp_root!("budget-broker-checkpoint")
    server = start_supervised!({BudgetBroker, name: Module.concat(__MODULE__, test)})
    opts = [state_dir: root, stagger_ms: 0, broker_server: server, enabled?: true]
    request = %{token: "daemon-token", url: "https://api.github.com/repos/owner/repo/issues"}

    assert {:ok, lease} = Budget.acquire(request, opts)
    assert :ok = Budget.release(lease, opts)

    Isolation.await_telemetry!([:aiur, :github, :budget_broker, :command], fn ->
      Budget.snapshot("daemon-token", opts)
    end)

    assert Enum.any?(:sys.get_state(server).stats, fn {_outcome, measurements} ->
             is_number(measurements.sqlite_checkpoint_ms)
           end)
  end
end
