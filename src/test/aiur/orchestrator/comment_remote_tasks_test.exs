defmodule Aiur.Orchestrator.CommentRemoteTasksTest do
  use ExUnit.Case, async: true
  import Aiur.TestSupport, only: [receive_barrier: 1]

  alias Aiur.Issue
  alias Aiur.Orchestrator.{CommentWake, State, TrackerTasks}

  setup do
    name = {__MODULE__, make_ref()}
    :yes = :global.register_name(name, self())
    on_exit(fn -> :global.unregister_name(name) end)
    {:ok, state: %State{snapshot_key: {:global, name}}}
  end

  test "idle comment tracker read leaves the owner responsive and applies to current state", %{
    state: state
  } do
    parent = self()

    event = %{
      issue_state_fetcher: fn _ids ->
        send(parent, {:fetching, self()})

        receive do
          :release -> {:ok, [%Issue{id: "42", identifier: "42", state: "parked", parked: true}]}
        end
      end
    }

    started = System.monotonic_time(:millisecond)
    pending = CommentWake.maybe_transition_idle_issue_to_rework(state, "42", :comment, event, 1)
    assert System.monotonic_time(:millisecond) - started < 500
    receive_barrier({:fetching, worker})
    refute worker == self()
    send(worker, :release)
    receive_barrier({ref, result})
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
          end
        end,
        merger_allowed_fun: fn _ -> true end,
        terminate_running_issue_fun: fn _, _, _ -> flunk("replacement runner was terminated") end
      )

    receive_barrier({:writing, worker})
    refute worker == self()
    replacement = %{original | session_id: "replacement"}
    current = %{pending | running: %{issue.id => replacement}, globally_paused: true}
    send(worker, :release)
    receive_barrier({ref, result})
    {:handled, applied} = TrackerTasks.result(current, ref, result)
    assert applied.running[issue.id] == replacement
    assert applied.globally_paused
  end

  test "idle review write delivers its wake if a runner starts before completion", %{state: state} do
    parent = self()
    issue = %Issue{id: "42", identifier: "42", state: "todo", labels: ["agent:todo"]}
    submitted_at = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.to_iso8601()
    head_committed_at = DateTime.utc_now() |> DateTime.add(-120, :second) |> DateTime.to_iso8601()

    event = %{
      author_trusted?: true,
      comment: %{
        "state" => "CHANGES_REQUESTED",
        "body" => "please fix",
        "submitted_at" => submitted_at
      },
      pull_request: %{
        "review_decision" => "CHANGES_REQUESTED",
        "head_committed_at" => head_committed_at
      },
      issue_state_fetcher: fn _ids -> {:ok, [issue]} end,
      open_pr_fetcher: fn _issue_key ->
        {:ok, %{"number" => 2337, "head" => %{"sha" => "head-sha"}}}
      end,
      unresolved_threads_fetcher: fn _pr -> {:ok, []} end,
      comment_update_issue_state_fun: fn _, "rework" ->
        send(parent, {:writing, self()})

        receive do
          :release -> :ok
        end
      end
    }

    pending = CommentWake.maybe_transition_idle_issue_to_rework(state, "42", :pr_review, event, 1)
    pending = apply_only_task(pending)
    pending = apply_only_task(pending)
    receive_barrier({:writing, worker})

    running = %{
      identifier: "42",
      issue: issue,
      session_id: "new-runner",
      control: %{status: :working}
    }

    pending = %{pending | running: %{"42" => running}}
    send(worker, :release)

    applied = apply_only_task(pending)

    assert [digest] = Aiur.AgentQueueStore.list_pending(applied.queue_store, "42")
    assert digest.body.events == [event]
    assert applied.running == %{"42" => running}
    assert applied.tracker_tasks == %{}
  end

  test "idle review gate delivers its wake if a runner starts before completion", %{state: state} do
    parent = self()
    issue = %Issue{id: "42", identifier: "42", state: "todo", labels: ["agent:todo"]}
    submitted_at = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.to_iso8601()
    head_committed_at = DateTime.utc_now() |> DateTime.add(-120, :second) |> DateTime.to_iso8601()

    event = %{
      author_trusted?: true,
      comment: %{
        "state" => "CHANGES_REQUESTED",
        "body" => "please fix",
        "submitted_at" => submitted_at
      },
      pull_request: %{
        "review_decision" => "CHANGES_REQUESTED",
        "head_committed_at" => head_committed_at
      },
      issue_state_fetcher: fn _ids -> {:ok, [issue]} end,
      open_pr_fetcher: fn _issue_key ->
        {:ok, %{"number" => 2337, "head" => %{"sha" => "head-sha"}}}
      end,
      unresolved_threads_fetcher: fn _pr ->
        send(parent, {:checking_threads, self()})

        receive do
          :release -> {:ok, []}
        end
      end,
      comment_update_issue_state_fun: fn _, "rework" ->
        send(parent, {:writing, self()})

        receive do
          :release -> :ok
        end
      end
    }

    pending = CommentWake.maybe_transition_idle_issue_to_rework(state, "42", :pr_review, event, 1)
    pending = apply_only_task(pending)
    receive_barrier({:checking_threads, gate_worker})
    [gate_ref] = Map.keys(pending.tracker_tasks)

    running = %{
      identifier: "42",
      issue: issue,
      session_id: "new-runner",
      control: %{status: :working}
    }

    pending = %{pending | running: %{"42" => running}}
    send(gate_worker, :release)
    assert_receive {^gate_ref, gate_result}, 2_000
    {:handled, pending} = TrackerTasks.result(pending, gate_ref, gate_result)
    assert_receive {:writing, write_worker}, 2_000
    send(write_worker, :release)

    [write_ref] = Map.keys(pending.tracker_tasks)
    assert_receive {^write_ref, write_result}, 2_000
    {:handled, applied} = TrackerTasks.result(pending, write_ref, write_result)

    assert [digest] = Aiur.AgentQueueStore.list_pending(applied.queue_store, "42")
    assert digest.body.events == [event]
    assert applied.running == %{"42" => running}
    assert applied.tracker_tasks == %{}
  end

  test "overlapping comments retain retry intent while only one rework write is pending", %{
    state: state
  } do
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
        end
      end
    }

    first = CommentWake.maybe_transition_idle_issue_to_rework(state, "42", :comment, event, 1)
    first = apply_only_task(first)
    first = apply_only_task(first)
    receive_barrier({:rework_writer, worker})
    second_event = %{event | comment: %{"body" => "another finding", "id" => 2}}

    second =
      CommentWake.maybe_transition_idle_issue_to_rework(first, "42", :comment, second_event, 1)

    read_ref =
      Enum.find_value(second.tracker_tasks, fn {ref, job} ->
        if match?({:comment_idle, _, _, _}, job.key), do: ref
      end)

    second = apply_task(second, read_ref)

    gate_ref =
      Enum.find_value(second.tracker_tasks, fn {ref, job} ->
        if match?({:comment_gate, _, _, _}, job.key), do: ref
      end)

    second = apply_task(second, gate_ref)
    assert map_size(second.comment_rework_retries) == 1
    refute_received {:rework_writer, _}
    second = CommentWake.cancel_comment_rework_retries(second)
    send(worker, :release)
    TrackerTasks.stop(second)
  end

  defp apply_only_task(state) do
    [ref] = Map.keys(state.tracker_tasks)
    apply_task(state, ref)
  end

  defp apply_task(state, ref) do
    receive_barrier({^ref, result})
    {:handled, state} = TrackerTasks.result(state, ref, result)
    state
  end
end
