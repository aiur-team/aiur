defmodule Aiur.Orchestrator.CommentPollingTaskPortTest do
  use ExUnit.Case, async: true

  alias Aiur.Orchestrator.{FirehosePolling, State}

  test "firehose scheduling uses the caller's task starter" do
    state = %State{}
    parent = self()

    starter = fn current, key, fetch, apply_result ->
      send(parent, {:task_started, current, key, fetch, apply_result})
      %{current | poll_check_in_progress: :scheduled}
    end

    assert %{poll_check_in_progress: :scheduled} = FirehosePolling.start(state, &Function.identity/1, starter)
    assert_receive {:task_started, ^state, :dispatch_poll, fetch, apply_result}, 1_000
    assert is_function(fetch, 0)
    assert is_function(apply_result, 2)
  end
end
