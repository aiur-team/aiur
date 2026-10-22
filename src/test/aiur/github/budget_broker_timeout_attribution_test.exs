defmodule Aiur.GitHub.BudgetBrokerTimeoutAttributionTest do
  use ExUnit.Case, async: false

  alias Aiur.GitHub.{Budget, BudgetBroker}

  setup do
    root = Aiur.TestSupport.tmp_root!("budget-broker-timeout-attribution")
    File.mkdir_p!(root)
    server = start_supervised!({BudgetBroker, name: __MODULE__})
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)
    %{root: root, server: server}
  end

  test "a timed-out acquisition retains Python and SQLite timings from its late reply", %{root: root, server: server} do
    args = acquire_args(root)
    assert {:ok, "granted " <> lease, 0} = command(server, Budget.broker_path(), args)
    assert {:ok, _, 0} = command(server, Budget.broker_path(), ["release", "--lease-id", String.trim(lease)] ++ common(root))
    port = :sys.get_state(server).port

    script = """
    import sqlite3, sys
    connection = sqlite3.connect(sys.argv[1], isolation_level=None)
    connection.execute("BEGIN IMMEDIATE")
    print("locked", flush=True)
    sys.stdin.readline()
    connection.execute("COMMIT")
    print("released", flush=True)
    """

    lock = Port.open({:spawn_executable, System.find_executable("python3")}, [:binary, :exit_status, args: ["-c", script, Path.join(root, "budget.sqlite3")]])
    on_exit(fn -> if Port.info(lock), do: Port.close(lock) end)

    assert_receive {^lock, {:data, "locked\n"}}, 1_000
    assert :timeout = BudgetBroker.command(server, Budget.broker_path(), args, System.monotonic_time(:millisecond) + 50)
    Port.command(lock, "\n")

    assert_receive {^lock, {:data, "released\n"}}, 1_000
    assert {:ok, snapshot, 0} = command(server, Budget.broker_path(), ["snapshot" | common(root)])
    assert %{"inflight" => %{}, "admissions" => [_]} = Jason.decode!(snapshot)

    assert Enum.any?(:sys.get_state(server).stats, fn
             {:timeout, %{command_type: :acquire, python_queue_wait_ms: python_wait, sqlite_lock_wait_ms: lock_wait}}
             when is_number(python_wait) and is_number(lock_wait) ->
               true

             _sample ->
               false
           end)

    assert {:ok, "granted " <> _, 0} = command(server, Budget.broker_path(), args)
    assert :sys.get_state(server).port == port
  end

  defp command(server, broker, args), do: BudgetBroker.command(server, broker, args, System.monotonic_time(:millisecond) + 5_000)
  defp common(root), do: ["--db", Path.join(root, "budget.sqlite3"), "--token-key", "shared-key"]

  defp acquire_args(root) do
    [
      "acquire",
      "--resource",
      "core",
      "--consumer-key",
      "daemon",
      "--endpoint-family",
      "rest",
      "--max-inflight",
      "2",
      "--max-inflight-per-endpoint",
      "2",
      "--requests-per-minute",
      "10000",
      "--stagger-ms",
      "0",
      "--lease-ttl-ms",
      "30000"
    ] ++ common(root)
  end
end
