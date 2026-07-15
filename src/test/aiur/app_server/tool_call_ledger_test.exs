defmodule Aiur.AppServer.ToolCallLedgerTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  alias Aiur.AppServer.ToolCallLedger

  test "concurrent callers share one completed result" do
    ledger = start_supervised!({ToolCallLedger, name: nil})
    scope = {:concurrent, System.unique_integer([:positive])}
    call_id = "call-concurrent"
    parent = self()

    fun = fn ->
      send(parent, {:executing, self()})

      receive do
        :release -> :completed
      end
    end

    first = Task.async(fn -> ToolCallLedger.execute(scope, call_id, fun, ledger) end)
    assert_receive {:executing, owner}
    second = Task.async(fn -> ToolCallLedger.execute(scope, call_id, fun, ledger) end)
    refute_receive {:executing, _duplicate}

    send(owner, :release)

    assert Task.await(first) == :completed
    assert Task.await(second) == :completed
    refute_receive {:executing, _duplicate}
  end

  test "owner death after mutation preserves an uncertain claim without replay" do
    ledger = start_supervised!({ToolCallLedger, name: nil})
    scope = {:owner_death, System.unique_integer([:positive])}
    call_id = "call-owner-death"
    parent = self()

    owner =
      spawn(fn ->
        ToolCallLedger.execute(
          scope,
          call_id,
          fn ->
            send(parent, :mutation_executed)
            Process.sleep(:infinity)
          end,
          ledger
        )
      end)

    assert_receive :mutation_executed

    replay =
      Task.async(fn ->
        ToolCallLedger.execute(
          scope,
          call_id,
          fn ->
            send(parent, :duplicate_mutation)
            :duplicate
          end,
          ledger
        )
      end)

    Process.exit(owner, :kill)

    assert Task.await(replay) == {:error, :outcome_uncertain}
    refute_receive :duplicate_mutation
  end

  test "completed results survive a ledger process restart", %{tmp_dir: tmp_dir} do
    storage_path = Path.join([tmp_dir, "state", "tool-ledger.dets"])
    {:ok, executions} = Agent.start_link(fn -> 0 end)
    scope = "restart-#{System.unique_integer([:positive])}"
    call_id = "call-restart"

    execute = fn ->
      Agent.update(executions, &(&1 + 1))
      :completed
    end

    opts = [name: nil, storage_path: storage_path, storage_name: :aiur_tool_call_ledger_restart_test]

    {:ok, first_ledger} = ToolCallLedger.start_link(opts)
    assert ToolCallLedger.execute(scope, call_id, execute, first_ledger) == :completed
    GenServer.stop(first_ledger)

    {:ok, second_ledger} = ToolCallLedger.start_link(opts)
    assert ToolCallLedger.execute(scope, call_id, execute, second_ledger) == :completed
    GenServer.stop(second_ledger)

    assert Agent.get(executions, & &1) == 1
  end

  test "an in-flight mutation becomes uncertain across a ledger process restart", %{
    tmp_dir: tmp_dir
  } do
    storage_path = Path.join([tmp_dir, "state", "tool-ledger.dets"])
    parent = self()
    identity = {:ledger_restart, System.unique_integer([:positive])}
    fingerprint = "call-ledger-restart"

    opts = [
      name: nil,
      storage_path: storage_path,
      storage_name: :aiur_tool_call_ledger_uncertain_restart_test
    ]

    {:ok, first_ledger} = ToolCallLedger.start_link(opts)

    owner =
      spawn(fn ->
        ToolCallLedger.execute(
          identity,
          fingerprint,
          fn ->
            send(parent, :mutation_executed_before_restart)

            receive do
              :finish_mutation -> :completed
            end
          end,
          first_ledger
        )
      end)

    assert_receive :mutation_executed_before_restart
    owner_ref = Process.monitor(owner)
    ledger_ref = Process.monitor(first_ledger)
    Process.unlink(first_ledger)
    Process.exit(first_ledger, :kill)

    assert_receive {:DOWN, ^ledger_ref, :process, ^first_ledger, :killed}
    send(owner, :finish_mutation)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, _reason}

    {:ok, second_ledger} = ToolCallLedger.start_link(opts)

    assert ToolCallLedger.execute(
             identity,
             fingerprint,
             fn ->
               send(parent, :duplicate_mutation_after_restart)
               :duplicate
             end,
             second_ledger
           ) == {:error, :outcome_uncertain}

    refute_receive :duplicate_mutation_after_restart
    GenServer.stop(second_ledger)
  end

  test "durable storage is owner-only", %{tmp_dir: tmp_dir} do
    state_dir = Path.join(tmp_dir, "state")
    storage_path = Path.join(state_dir, "tool-ledger.dets")

    {:ok, ledger} =
      ToolCallLedger.start_link(
        name: nil,
        storage_path: storage_path,
        storage_name: :aiur_tool_call_ledger_permissions_test
      )

    assert Bitwise.band(File.stat!(state_dir).mode, 0o777) == 0o700
    assert Bitwise.band(File.stat!(storage_path).mode, 0o777) == 0o600
    GenServer.stop(ledger)
  end

  test "durable storage rejects a symlinked ledger file", %{tmp_dir: tmp_dir} do
    state_dir = Path.join(tmp_dir, "state")
    storage_path = Path.join(state_dir, "tool-ledger.dets")
    target = Path.join(tmp_dir, "target.dets")
    File.mkdir_p!(state_dir)
    File.write!(target, "outside")
    File.ln_s!(target, storage_path)

    previous_trap_exit? = Process.flag(:trap_exit, true)

    try do
      assert {:error, {:tool_call_ledger_storage, {:symlink_rejected, ^storage_path}}} =
               ToolCallLedger.start_link(
                 name: nil,
                 storage_path: storage_path,
                 storage_name: :aiur_tool_call_ledger_symlink_test
               )
    after
      Process.flag(:trap_exit, previous_trap_exit?)
    end
  end
end
