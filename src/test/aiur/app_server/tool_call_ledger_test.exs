defmodule Aiur.AppServer.ToolCallLedgerTest do
  use ExUnit.Case, async: true

  alias Aiur.AppServer.ToolCallLedger

  test "concurrent callers share one completed result" do
    ledger = start_supervised!({ToolCallLedger, name: nil})
    scope = {:concurrent, System.unique_integer([:positive])}
    call_id = make_ref()
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
end
