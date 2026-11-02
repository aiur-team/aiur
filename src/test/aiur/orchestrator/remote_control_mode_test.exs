defmodule Aiur.Orchestrator.RemoteControlModeTest do
  use ExUnit.Case, async: true
  import Aiur.TestSupport, only: [receive_barrier: 1]

  alias Aiur.Issue
  alias Aiur.Orchestrator.{Dispatcher, RemoteControlMode, Slots, State}
  alias Aiur.Orchestrator.PauseResume.ControlCalls
  alias Aiur.Orchestrator.TrackerTasks

  test "remote control summary requires both the alias label and session URL" do
    issue = %Issue{id: "1", identifier: "repo#1", labels: ["model:remote"]}

    assert RemoteControlMode.remote_control_summary(%{issue: issue}) == nil

    assert RemoteControlMode.remote_control_summary(%{
             issue: %Issue{issue | labels: ["model:codex"]},
             repl_rc_session_url: "https://claude.ai/code/session_1"
           }) == nil

    assert RemoteControlMode.remote_control_summary(%{
             issue: issue,
             repl_rc_session_url: "https://claude.ai/code/session_1"
           }) == %{status: :on, session_url: "https://claude.ai/code/session_1"}
  end

  test "label helpers are idempotent" do
    issue = %Issue{id: "1", identifier: "repo#1", labels: ["model:codex"]}

    assert RemoteControlMode.add_issue_label(issue, "MODEL:REMOTE").labels == ["model:codex", "model:remote"]

    assert RemoteControlMode.add_issue_label(
             RemoteControlMode.add_issue_label(issue, "model:remote"),
             "model:remote"
           ).labels == ["model:codex", "model:remote"]

    assert RemoteControlMode.remove_issue_label(issue, "model:remote") == issue

    assert RemoteControlMode.remove_issue_label(
             RemoteControlMode.add_issue_label(issue, "model:remote"),
             "model:remote"
           ).labels == ["model:codex"]
  end

  test "redispatch pins the requested backend and reuses the workspace and reservation" do
    parent = self()
    workspace = Path.join(System.tmp_dir!(), "aiur-redispatch-#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)
    dirty_file = Path.join(workspace, "uncommitted.txt")
    File.write!(dirty_file, "local edits survive")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(workspace) end)

    issue = %Issue{
      id: "1",
      identifier: "repo#1",
      labels: ["model:claude", "model:remote", "in-progress"]
    }

    fence = %{pending_item_ids: MapSet.new([12]), authoritative_state: "in-progress"}
    entry = running_entry(issue) |> Map.put(:workspace_path, workspace) |> Map.put(:lifecycle_fence, fence)
    state = %Aiur.Orchestrator.State{running: %{issue.id => entry}, claimed: MapSet.new([issue.id])}

    assert {{:ok, :redispatched}, next} =
             RemoteControlMode.redispatch_call_unchecked(state, issue.identifier, "codex",
               known_backends_fun: fn -> ["claude", "codex"] end,
               effort_labels: fn -> ["model:xhigh"] end,
               admit_fun: fn admitted, selected, nil ->
                 assert selected.labels == ["model:remote", "in-progress", "model:codex"]
                 {:ok, admitted}
               end,
               write_marker_fun: fn _identifier, _action, _label, _opts -> :ok end,
               teardown_fun: fn current, old, :redispatch ->
                 assert current.claimed == MapSet.new([issue.id])
                 send(parent, {:teardown, old.workspace_path})
                 current
               end,
               dispatch_fun: fn dispatch_state, dispatched_issue, nil, nil, opts ->
                 assert dispatched_issue.labels == ["model:remote", "in-progress", "model:codex"]
                 assert opts[:forced_backend] == "codex"
                 assert opts[:redispatch_safety].workspace_path == workspace
                 assert dispatch_state.claimed == MapSet.new([issue.id])
                 send(parent, {:dispatch, dispatched_issue.id, dispatch_state.running[issue.id].workspace_path})
                 dispatch_state
               end,
               schedule_retry_fun: fn retry_state, _id, _attempt, _metadata -> retry_state end
             )

    assert_received {:teardown, ^workspace}
    assert_received {:dispatch, "1", ^workspace}
    assert File.read!(dirty_file) == "local edits survive"
    assert next.claimed == MapSet.new([issue.id])
    assert next.running[issue.id].lifecycle_fence == fence
    assert next.running[issue.id].redispatch_safety.workspace_path == workspace
  end

  test "redispatch without a backend keeps model variants and uses the selected route without writing labels" do
    issue = %Issue{
      id: "route-1",
      identifier: "repo#route-1",
      labels: ["model:claude-opus-4-8", "model:xhigh", "agent:in-progress"],
      selected_backend: "claude",
      selected_model: "opus-4-8"
    }

    entry = running_entry(issue)
    state = %State{running: %{issue.id => entry}, claimed: MapSet.new([issue.id])}

    assert {{:ok, :redispatched}, _next} =
             RemoteControlMode.redispatch_call_unchecked(state, issue.identifier, nil,
               select_backend_fun: fn current ->
                 assert current.selected_backend == nil
                 assert current.selected_model == nil
                 {:ok, %{current | selected_backend: "claude"}}
               end,
               admit_fun: fn _state, admitted_issue, nil ->
                 assert admitted_issue.labels == issue.labels
                 {:ok, state}
               end,
               write_marker_fun: fn _, _, _, _ -> flunk("backend-agnostic redispatch rewrote ticket labels") end,
               teardown_fun: fn current, _old, :redispatch -> current end,
               dispatch_fun: fn dispatch_state, dispatched_issue, nil, nil, opts ->
                 assert dispatched_issue.labels == issue.labels
                 assert dispatched_issue.selected_backend == "claude"
                 assert opts[:forced_backend] == nil
                 dispatch_state
               end,
               schedule_retry_fun: fn retry_state, _id, _attempt, _metadata -> retry_state end
             )
  end

  test "redispatch without a backend dispatches the current route without persisting a pin" do
    issue = %Issue{id: "route-2", identifier: "repo#route-2", labels: ["agent:in-progress"], selected_backend: "claude"}
    entry = running_entry(issue)
    state = %State{running: %{issue.id => entry}, claimed: MapSet.new([issue.id])}

    assert {{:ok, :redispatched}, _next} =
             RemoteControlMode.redispatch_call_unchecked(state, issue.identifier, nil,
               select_backend_fun: fn current -> {:ok, %{current | selected_backend: "codex"}} end,
               admit_fun: fn _current, selected, nil ->
                 assert selected.selected_backend == "codex"
                 {:ok, state}
               end,
               write_marker_fun: fn _, _, _, _ -> flunk("routing selection was persisted as a pin") end,
               teardown_fun: fn current, _old, :redispatch -> current end,
               dispatch_fun: fn current, selected, nil, nil, opts ->
                 assert selected.selected_backend == "codex"
                 assert opts[:forced_backend] == nil
                 current
               end,
               schedule_retry_fun: fn retry_state, _id, _attempt, _metadata -> retry_state end
             )
  end

  test "redispatch admission replaces the running ticket at the full global cap" do
    # Future regression guard for the dispatcher admission path: a swap must
    # consume the existing ticket slot instead of requiring a spare one.
    issue = %Issue{id: "full-1", identifier: "repo#full-1", labels: ["model:codex"]}
    entry = running_entry(issue)

    state = %State{
      max_concurrent_agents: 1,
      effective_concurrent_agents: 1,
      running: %{issue.id => entry}
    }

    assert Slots.used_slots(state) == 1
    assert {:ok, admitted} = Dispatcher.admit_redispatch(state, issue, nil)
    assert Slots.used_slots(admitted) == 1
    assert map_size(admitted.running) == map_size(state.running)
  end

  test "refused redispatch paths leave the worker and labels untouched" do
    issue = %Issue{id: "refuse-1", identifier: "repo#refuse-1", labels: ["model:claude-opus", "agent:in-progress"]}
    entry = running_entry(issue)
    state = %State{running: %{issue.id => entry}}

    no_side_effects = [
      teardown_fun: fn _, _old, _reason -> flunk("refused redispatch tore down the worker") end,
      write_marker_fun: fn _, _, _, _ -> flunk("refused redispatch wrote a label") end
    ]

    assert {{:error, :not_running}, %State{}} =
             RemoteControlMode.redispatch_call_unchecked(%State{}, issue.identifier, "codex", no_side_effects)

    missing_workspace = %{entry | workspace_path: nil}
    missing_state = %{state | running: %{issue.id => missing_workspace}}

    assert {{:error, :workspace_unavailable}, ^missing_state} =
             RemoteControlMode.redispatch_call_unchecked(missing_state, issue.identifier, "codex", no_side_effects)

    assert {{:error, {:unknown_backend, "nope"}}, ^state} =
             RemoteControlMode.redispatch_call_unchecked(state, issue.identifier, "nope", Keyword.merge(no_side_effects, known_backends_fun: fn -> ["claude", "codex"] end))

    in_progress = %{state | tracker_tasks: %{make_ref() => %{key: {:redispatch, issue.identifier}}}}

    assert {:reply, {:error, :redispatch_in_progress}, ^in_progress} =
             ControlCalls.redispatch_call(in_progress, issue.identifier, "codex")

    paused = %{entry | control: %{status: :paused}}
    paused_state = %{state | running: %{issue.id => paused}}

    assert {{:error, :not_running}, ^paused_state} =
             RemoteControlMode.redispatch_call_unchecked(paused_state, issue.identifier, "codex", no_side_effects)
  end

  test "promotion preserves the live agent when redispatch is not ready" do
    issue = %Issue{id: "1", identifier: "repo#1", labels: ["model:codex"]}
    entry = running_entry(issue)
    state = %Aiur.Orchestrator.State{running: %{issue.id => entry}}

    assert {{:error, :thrash_circuit_open}, ^state} =
             RemoteControlMode.set_remote_control_reply(state, issue.identifier, true,
               dashboard_url_fun: fn -> "http://localhost:4000" end,
               dispatch_ready_fun: fn _state, relabeled, nil ->
                 assert "model:remote" in relabeled.labels
                 {:error, :thrash_circuit_open}
               end
             )
  end

  test "demotion preserves the live agent when redispatch is not ready" do
    issue = %Issue{id: "1", identifier: "repo#1", labels: ["model:remote"]}
    entry = running_entry(issue)
    state = %Aiur.Orchestrator.State{running: %{issue.id => entry}}

    assert {{:error, :thrash_circuit_open}, ^state} =
             RemoteControlMode.set_remote_control_reply(state, issue.identifier, false,
               dispatch_ready_fun: fn _state, relabeled, nil ->
                 refute "model:remote" in relabeled.labels
                 {:error, :thrash_circuit_open}
               end
             )
  end

  test "failed promotion redispatch does not leave the torn-down entry consuming a slot" do
    issue = %Issue{id: "1", identifier: "repo#1", labels: ["model:codex"]}
    entry = running_entry(issue)

    state = %Aiur.Orchestrator.State{
      running: %{issue.id => entry},
      claimed: MapSet.new([issue.id])
    }

    assert {{:ok, :on}, next_state} =
             RemoteControlMode.set_remote_control_reply(state, issue.identifier, true,
               dashboard_url_fun: fn -> "http://localhost:4000" end,
               dispatch_ready_fun: fn admitted_state, _relabeled, nil ->
                 {:ok, admitted_state}
               end,
               trust_fun: fn _workspace, _opts -> :ok end,
               add_label_fun: fn _identifier, _label -> :ok end,
               teardown_fun: fn current_state, _running_entry -> current_state end,
               dispatch_fun: fn dispatch_state, _issue, nil, nil, _opts -> dispatch_state end,
               schedule_retry_fun: fn retry_state, issue_id, _attempt, metadata ->
                 # The torn-down entry was already running and continuation is
                 # on by default, so the retry carries the prior work rather
                 # than cold-starting over it.
                 assert metadata.prior_work == true
                 assert metadata.error == "remote-control redispatch did not start"

                 %{
                   retry_state
                   | retry_attempts: Map.put(retry_state.retry_attempts, issue_id, metadata)
                 }
               end
             )

    refute Map.has_key?(next_state.running, issue.id)
    assert Map.has_key?(next_state.retry_attempts, issue.id)
    assert next_state.claimed == MapSet.new([issue.id])
  end

  test "a late remote-control label write replies without replacing a new runner" do
    parent = self()
    reply_ref = make_ref()
    issue = %Issue{id: "1", identifier: "repo#1", labels: ["model:codex"]}
    entry = running_entry(issue) |> Map.put(:session_id, "original")
    state = %Aiur.Orchestrator.State{running: %{issue.id => entry}}

    assert {:noreply, pending} =
             RemoteControlMode.set_remote_control_call(state, issue.identifier, true,
               from: {parent, reply_ref},
               dashboard_url_fun: fn -> "http://localhost:4000" end,
               dispatch_ready_fun: fn current, _, _ -> {:ok, current} end,
               trust_fun: fn _, _ -> :ok end,
               add_label_fun: fn _, _ ->
                 send(parent, {:rc_writer, self()})

                 receive do
                   :release -> :ok
                 end
               end,
               teardown_fun: fn _, _ -> flunk("replacement runner was torn down") end
             )

    receive_barrier({:rc_writer, worker})

    assert {:reply, {:error, :remote_control_change_in_progress}, ^pending} =
             RemoteControlMode.set_remote_control_call(pending, issue.identifier, false, from: {parent, make_ref()})

    refute worker == self()
    refute_received {^reply_ref, _}
    replacement = %{entry | session_id: "replacement"}
    current = %{pending | running: %{issue.id => replacement}}
    send(worker, :release)
    receive_barrier({task_ref, result})
    {:handled, applied} = TrackerTasks.result(current, task_ref, result)
    receive_barrier({^reply_ref, {:error, :stale_runner}})
    assert applied.running[issue.id] == replacement
  end

  defp running_entry(issue) do
    %{
      identifier: issue.identifier,
      issue: issue,
      workspace_path: "/tmp/aiur-rc-test",
      worker_host: nil,
      pid: self(),
      ref: make_ref(),
      control: %{status: :working}
    }
  end
end
