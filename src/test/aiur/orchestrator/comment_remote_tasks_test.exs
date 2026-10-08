defmodule Aiur.Orchestrator.CommentRemoteTasksTest do
  use ExUnit.Case, async: true

  alias Aiur.Issue
  alias Aiur.Orchestrator.{CommentWake, State, TrackerTasks}

  setup do
    name = {__MODULE__, make_ref()}
    :yes = :global.register_name(name, self())
    on_exit(fn -> :global.unregister_name(name) end)
    {:ok, state: %State{snapshot_key: {:global, name}}}
  end

  test "idle comment tracker read leaves the owner responsive and applies to current state", %{state: state} do
    parent = self()

    event = %{
      issue_state_fetcher: fn _ids ->
        send(parent, {:fetching, self()})

        receive do
          :release -> {:ok, [%Issue{id: "42", identifier: "42", state: "parked", parked: true}]}
        after
          1_000 -> {:error, :read_blocked}
        end
      end
    }

    started = System.monotonic_time(:millisecond)
    pending = CommentWake.maybe_transition_idle_issue_to_rework(state, "42", :comment, event, 1)
    assert System.monotonic_time(:millisecond) - started < 500
    assert_receive {:fetching, worker}, 1_000
    refute worker == self()
    send(worker, :release)
    assert_receive {ref, result}, 1_000
    {:handled, applied} = TrackerTasks.result(%{pending | globally_paused: true}, ref, result)
    assert applied.globally_paused
    assert applied.tracker_tasks == %{}
  end

  test "late merged PR write cannot tear down a replacement runner", %{state: state} do
    parent = self()
    issue = %Issue{id: "42", identifier: "42", state: "in-progress"}
    original = %{identifier: "42", issue: issue, session_id: "original"}
    state = %{state | running: %{issue.id => original}}

    pending =
      CommentWake.mark_pr_merged_issue_done(state, "42",
        pr_body: "Closes #42",
        repo_fun: fn -> "owner/repo" end,
        open_pull_requests_fun: fn _ -> {:ok, []} end,
        update_issue_state_fun: fn _, "done" ->
          send(parent, {:writing, self()})

          receive do
            :release -> :ok
          after
            1_000 -> {:error, :write_blocked}
          end
        end,
        merger_allowed_fun: fn _ -> true end,
        terminate_running_issue_fun: fn _, _, _ -> flunk("replacement runner was terminated") end
      )

    assert_receive {:writing, worker}, 1_000
    refute worker == self()
    replacement = %{original | session_id: "replacement"}
    current = %{pending | running: %{issue.id => replacement}, globally_paused: true}
    send(worker, :release)
    assert_receive {ref, result}, 1_000
    {:handled, applied} = TrackerTasks.result(current, ref, result)
    assert applied.running[issue.id] == replacement
    assert applied.globally_paused
  end

  test "overlapping comments retain retry intent while only one rework write is pending", %{state: state} do
    parent = self()
    issue = %Issue{id: "42", identifier: "42", state: "rework", labels: ["agent:rework"]}
    state = %{state | last_polled_issues: %{issue.id => issue}}

    event = %{
      author_trusted?: true,
      comment: %{"body" => "please fix", "id" => 1},
      open_pr_fetcher: fn _ -> {:ok, %{"headRefOid" => "head-sha"}} end,
      unresolved_threads_fetcher: fn _ -> {:ok, [%{"id" => "thread"}]} end,
      comment_update_issue_state_fun: fn _, "rework" ->
        send(parent, {:rework_writer, self()})

        receive do
          :release -> :ok
        after
          1_000 -> {:error, :blocked}
        end
      end
    }

    first = CommentWake.maybe_transition_idle_issue_to_rework(state, "42", :comment, event, 1)
    first = apply_only_task(first)
    first = apply_only_task(first)
    assert_receive {:rework_writer, worker}, 1_000
    second_event = %{event | comment: %{"body" => "another finding", "id" => 2}}
    second = CommentWake.maybe_transition_idle_issue_to_rework(first, "42", :comment, second_event, 1)
    read_ref = Enum.find_value(second.tracker_tasks, fn {ref, job} -> if match?({:comment_idle, _, _, _}, job.key), do: ref end)
    second = apply_task(second, read_ref)
    gate_ref = Enum.find_value(second.tracker_tasks, fn {ref, job} -> if match?({:comment_gate, _, _, _}, job.key), do: ref end)
    second = apply_task(second, gate_ref)
    assert map_size(second.comment_rework_retries) == 1
    refute_receive {:rework_writer, _}, 20
    second = CommentWake.cancel_comment_rework_retries(second)
    send(worker, :release)
    TrackerTasks.stop(second)
  end

  defp apply_only_task(state) do
    [ref] = Map.keys(state.tracker_tasks)
    apply_task(state, ref)
  end

  defp apply_task(state, ref) do
    assert_receive {^ref, result}, 1_000
    {:handled, state} = TrackerTasks.result(state, ref, result)
    state
  end
end
