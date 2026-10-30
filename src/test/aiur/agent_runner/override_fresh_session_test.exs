defmodule Aiur.AgentRunner.OverrideFreshSessionTest do
  use Aiur.DispatcherTestSupport
  alias Aiur.AgentRunner.SessionOptions
  alias Aiur.Issue
  alias Aiur.Workspace.Context
  alias Aiur.Orchestrator.OverrideRecovery

  test "replacement ignores a supplied stale thread and preserves the ticket workspace" do
    issue = %Issue{id: "6911", identifier: "6911", selected_backend: "codex", continuation_head_ref: "original-branch"}
    {"codex", false, resumed} = SessionOptions.resolve_session_options(issue, [resume_thread_id: "stale-thread"], nil)
    assert resumed[:resume_thread_id] == "stale-thread"
    {"codex", false, fresh} = SessionOptions.resolve_session_options(issue, [resume_thread_id: "stale-thread", fresh_session: true], nil)
    refute Keyword.has_key?(fresh, :resume_thread_id)
    context = Context.build(issue)
    assert context.issue_identifier == "6911"
    assert context.pr_head_ref == "original-branch"
    assert context.branch_name == "original-branch"
  end

  test "replacement dispatch reaches the actual runner with fresh-session and prior-work options" do
    parent = self()
    candidate = issue("replacement-dispatch")
    pr = %{head_ref: "existing-work"}

    runner = fn dispatched, _, opts ->
      send(parent, {:replacement_run, self(), dispatched, opts})
      receive do: (:stop -> :ok)
    end

    assert {{:ok, :started}, next} = OverrideRecovery.replace(%State{max_concurrent_agents: 1}, candidate, nil, pr, runner: runner)
    receive_barrier({:replacement_run, pid, dispatched, opts})
    on_exit(fn -> Process.exit(pid, :kill) end)
    assert opts[:fresh_session] == true
    assert opts[:prior_work] == true
    assert dispatched.id == candidate.id
    assert dispatched.pr_head_ref == nil
    assert dispatched.continuation_head_ref == "existing-work"
    assert next.running[candidate.id].pid == pid
    ref = next.running[candidate.id].ref
    send(pid, :stop)
    receive_barrier({:DOWN, ^ref, :process, ^pid, :normal})
  end
end
