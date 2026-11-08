defmodule Aiur.Orchestrator.StaleOwnerTest do
  use Aiur.TestSupport

  alias Aiur.{AlertFeed, Issue}
  alias Aiur.Orchestrator.{AgentTeardown, StaleOwner, State}
  alias Aiur.Ownership.{Fence, Record}
  alias Aiur.Workspace.Layout

  @record %Record{
    schema: "aiur.ownership/v1",
    repo: "o/r",
    ticket: "1",
    state: "owned",
    gateway_id: "aaaaaaaaaaaaaaaaaaaaaaaaaa",
    gateway_label: "mine",
    daemon_key: "k1",
    epoch: 3,
    previous_epoch: 2,
    actor: %{kind: "daemon", id: "k1"},
    reason: "dispatch",
    at: "2026-11-08T00:00:00Z"
  }

  setup do
    previous = Application.get_env(:aiur, :docker_cleanup_command)
    Application.put_env(:aiur, :docker_cleanup_command, fn "docker", _args, _opts -> {"", 0} end)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:aiur, :docker_cleanup_command, previous),
        else: Application.delete_env(:aiur, :docker_cleanup_command)
    end)
  end

  defp running(identifier) do
    issue = %Issue{id: "so-#{identifier}", identifier: identifier, state: "in-progress", title: "Stale"}
    entry = %{pid: nil, ref: nil, identifier: identifier, issue: issue, session_id: "s", started_at: DateTime.utc_now(), control: %{status: :working}}
    {%State{running: %{issue.id => entry}, claimed: MapSet.new([issue.id]), max_concurrent_agents: 2, effective_concurrent_agents: 2}, issue}
  end

  test "a moved owner stops the agent, schedules no retry, starts no workspace cleanup and alerts once" do
    identifier = "SO-#{System.unique_integer([:positive])}"
    {state, _issue} = running(identifier)

    {:ok, workspace} = identifier |> Layout.safe_identifier() |> Layout.workspace_path_for_issue(nil)
    File.mkdir_p!(workspace)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(workspace) end)

    next = StaleOwner.handle(state, identifier, 3)

    assert next.running == %{}
    assert next.retry_attempts == %{}
    # Terminal cleanup runs in a task that reports back to the caller; keeping the workspace means it never starts.
    refute_receive {:workspace_cleanup_finished, _, _}, 500
    assert File.dir?(workspace)
    assert [alert] = Enum.filter(AlertFeed.list(), &(&1["topic"] == "system.ownership.stale_agent" and &1["reason"] =~ identifier))
    assert alert["reason"] =~ "epoch 3"

    # A second report for a ticket that no longer runs changes nothing.
    assert StaleOwner.handle(next, identifier, 3) == next
  end

  test "terminal cleanup does report back, so the refute above can fail" do
    identifier = "SO-#{System.unique_integer([:positive])}"
    {state, issue} = running(identifier)
    AgentTeardown.terminate_running_issue(state, issue.id, true)
    assert_receive {:workspace_cleanup_finished, _, _}, 5_000
  end

  test "tearing a run down unregisters its fence claim" do
    identifier = "SO-#{System.unique_integer([:positive])}"
    {state, issue} = running(identifier)
    read = fn _, _, _ -> {:ok, %{record: @record, oid: "x", repository_id: "r"}} end
    start_supervised!({Fence, read_fun: read, notify: fn _, _ -> :ok end})
    :ok = Fence.register(issue, @record)
    assert {:ok, _} = Fence.check(identifier)

    AgentTeardown.terminate_running_issue(state, issue.id, false)

    # unregister is a cast; the check call is ordered after it from this process.
    assert {:unknown, :no_registration} = Fence.check(identifier)
  end
end
