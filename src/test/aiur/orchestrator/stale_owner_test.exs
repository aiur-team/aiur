defmodule Aiur.Orchestrator.StaleOwnerTest do
  use Aiur.TestSupport

  alias Aiur.{AlertFeed, Issue}
  alias Aiur.Orchestrator.{StaleOwner, State}
  alias Aiur.Workspace.Layout

  setup do
    previous = Application.get_env(:aiur, :docker_cleanup_command)
    Application.put_env(:aiur, :docker_cleanup_command, fn "docker", _args, _opts -> {"", 0} end)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:aiur, :docker_cleanup_command, previous),
        else: Application.delete_env(:aiur, :docker_cleanup_command)
    end)
  end

  test "a moved owner stops the agent, keeps the workspace, schedules no retry and alerts once" do
    identifier = "SO-#{System.unique_integer([:positive])}"
    issue = %Issue{id: "so-#{identifier}", identifier: identifier, state: "in-progress", title: "Stale"}
    entry = %{pid: nil, ref: nil, identifier: identifier, issue: issue, session_id: "s", started_at: DateTime.utc_now(), control: %{status: :working}}
    state = %State{running: %{issue.id => entry}, claimed: MapSet.new([issue.id]), max_concurrent_agents: 2, effective_concurrent_agents: 2}

    {:ok, workspace} = identifier |> Layout.safe_identifier() |> Layout.workspace_path_for_issue(nil)
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(workspace) end)

    next = StaleOwner.handle(state, identifier, 3)

    assert next.running == %{}
    assert next.retry_attempts == %{}
    assert File.dir?(workspace)
    assert [alert] = Enum.filter(AlertFeed.list(), &(&1["topic"] == "system.ownership.stale_agent" and &1["reason"] =~ identifier))
    assert alert["reason"] =~ "epoch 3"

    # A second report for a ticket that no longer runs changes nothing.
    assert StaleOwner.handle(next, identifier, 3) == next
  end
end
