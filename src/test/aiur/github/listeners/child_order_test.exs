defmodule Aiur.GitHub.Listeners.ChildOrderTest do
  use ExUnit.Case, async: true

  test "listeners start immediately before the orchestrator in every startup shape" do
    for headless? <- [false, true], dashboard? <- [false, true], ticker? <- [false, true], recording? <- [false, true] do
      children = Aiur.Application.child_specs(interactive_cli?: not headless?, headless?: headless?, dashboard?: dashboard?, ls_remote_ticker?: ticker?, recording?: recording?)
      ids = Enum.map(children, &Supervisor.child_spec(&1, []).id)
      index = Enum.find_index(ids, &(&1 == Aiur.Orchestrator))
      assert Enum.at(ids, index - 1) == Aiur.GitHub.Listeners
    end
  end
end
