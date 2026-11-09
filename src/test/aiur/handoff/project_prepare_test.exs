defmodule Aiur.Handoff.ProjectPrepareTest do
  use Aiur.TwoProjectsCase, async: false

  import ExUnit.CaptureIO

  alias Aiur.Handoff.{CLI, Record}

  test "restart --keep-agents in projects mode prepares every project and reports both ids", %{a: a, b: b} do
    # Projects mode runs no bare orchestrator, so the single-project snapshot would say "not running".
    Supervisor.terminate_child(Aiur.Supervisor, Aiur.Orchestrator)
    on_exit(fn -> Supervisor.restart_child(Aiur.Supervisor, Aiur.Orchestrator) end)
    assert GenServer.whereis(Aiur.Orchestrator) == nil

    output = capture_io(fn -> CLI.prepare() end)

    assert output =~ "__AIUR_CONTROL_EXIT__:0"
    [ids] = Regex.run(~r/__AIUR_HANDOFF__:(\S+)/, output, capture: :all_but_first)
    ids = String.split(ids, ",")
    assert length(ids) == 2

    for project <- [a, b] do
      assert File.exists?(in_project(project, fn -> Record.path() end)), "no record in #{project.state_root}"
      assert in_project(project, fn -> {:ok, r} = Record.read(); r["handoff_id"] end) in ids
    end
  end
end
