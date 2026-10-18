defmodule Aiur.Orchestrator.DispatchExecutorOwnedTest do
  use Aiur.TestSupport

  alias Aiur.Orchestrator.{DispatchPolicy, State}

  test "Executor-owned tickets are skipped while released tickets remain dispatchable" do
    state = %State{max_concurrent_agents: 3, running: %{}, claimed: MapSet.new(), retry_attempts: %{}}
    held = %Issue{id: "owned-1", identifier: "MT-OWNED", title: "Executor work", state: "Todo", executor_owner: "codex"}
    released = %{held | executor_owner: nil}

    assert DispatchPolicy.dispatch_decision(held, state) == {:skip, :executor_owned}
    assert DispatchPolicy.should_dispatch_issue?(released, state)
    assert :executor_owned in DispatchPolicy.dispatch_decline_reasons()
  end
end
