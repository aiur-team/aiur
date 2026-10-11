defmodule Aiur.Orchestrator.CommentPollingTaskPortTest do
  use ExUnit.Case, async: true

  alias Aiur.Orchestrator.{CommentPolling, State}

  test "firehose scheduling uses the caller's task starter" do
    state = %State{events_etag: "retained-etag", events_last_id: "retained-id"}
    parent = self()

    starter = fn current, key, fetch, apply_result ->
      send(parent, {:task_started, current, key, fetch, apply_result})
      %{current | events_etag: "scheduled"}
    end

    assert %{events_etag: "scheduled"} = CommentPolling.start_firehose(state, &Function.identity/1, starter)
    assert_receive {:task_started, ^state, :dispatch_poll, fetch, apply_result}, 1_000
    assert is_function(fetch, 0)
    assert is_function(apply_result, 2)
  end
end
