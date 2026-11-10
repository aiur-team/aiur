defmodule Aiur.Handoff.ReportTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO
  alias Aiur.Handoff.{CLI, Record, Report}

  @tag :tmp_dir
  test "report retains per-agent identity, fallbacks, timestamps and measured gap", %{tmp_dir: dir} do
    record = %{
      "handoff_id" => "restart-report",
      "written_at" => "2026-10-15T10:00:00.000Z",
      "completed_at" => "2026-10-15T10:00:02.345Z",
      "outcome" => [
        %{"identifier" => "1", "status" => "adopted", "provider_pid_before" => 123, "provider_pid_after" => 123, "session_id_before" => "session-1", "session_id_after" => "session-1"},
        %{"identifier" => "2", "status" => "fallback", "reason" => ":schema", "provider_pid_before" => 234}
      ]
    }

    Aiur.JsonStore.write!(Record.path(dir: dir) <> ".consumed", record)
    assert {:ok, report} = Report.latest(dir: dir)
    assert report.gap_ms == 2345
    assert report.handoff_id == "restart-report"
    assert report.adopted == [hd(record["outcome"])]
    assert report.fallback == [List.last(record["outcome"])]
    output = capture_io(fn -> CLI.report(dir: dir, json: true, expected_id: "restart-report") end)
    [json, "__AIUR_CONTROL_EXIT__:0"] = String.split(output, "\n", trim: true)
    assert Jason.decode!(json) == Jason.decode!(Jason.encode!(report))
    text = capture_io(fn -> CLI.report(dir: dir) end)
    assert text =~ "gap=2345ms"
    assert text =~ "1 adopted pid=123 session=session-1"
    assert text =~ "2 fallback :schema"
  end

  @tag :tmp_dir
  test "missing report is none and a mismatched previous report cannot complete restart", %{tmp_dir: dir} do
    assert :none = Report.latest(dir: dir)
    assert capture_io(fn -> CLI.report(dir: dir) end) == "HANDOFF none\n__AIUR_CONTROL_EXIT__:0\n"
    assert capture_io(fn -> CLI.report(dir: dir, json: true) end) == "null\n__AIUR_CONTROL_EXIT__:0\n"
    Aiur.JsonStore.write!(Record.path(dir: dir) <> ".consumed", %{"handoff_id" => "old", "outcome" => []})
    text = capture_io(fn -> CLI.report(dir: dir, expected_id: "new", wait_ms: 0) end)
    assert text =~ "adoption_report_timeout"
    assert text =~ "__AIUR_CONTROL_EXIT__:1"
  end

  @tag :tmp_dir
  test "a matching consumed record is unavailable until its outcome is complete", %{tmp_dir: dir} do
    file = Record.path(dir: dir) <> ".consumed"
    record = %{"handoff_id" => "publishing", "written_at" => "2026-10-15T10:00:00.000Z"}
    Aiur.JsonStore.write!(file, record)

    assert :none = Report.latest(dir: dir)
    assert capture_io(fn -> CLI.report(dir: dir, json: true) end) == "null\n__AIUR_CONTROL_EXIT__:0\n"
    output = capture_io(fn -> CLI.report(dir: dir, expected_id: "publishing", wait_ms: 0) end)
    assert output =~ "adoption_report_timeout"
    assert output =~ "__AIUR_CONTROL_EXIT__:1"
    refute output =~ "adopted=0"

    outcome = [%{"identifier" => "1", "status" => "adopted", "provider_pid_after" => "123", "session_id_after" => "kept-session"}]
    Aiur.JsonStore.write!(file, Map.merge(record, %{"completed_at" => "2026-10-15T10:00:02.000Z", "outcome" => outcome}))
    assert {:ok, %{adopted: ^outcome, gap_ms: 2000}} = Report.latest(dir: dir)
    completed = capture_io(fn -> CLI.report(dir: dir, expected_id: "publishing", wait_ms: 0) end)
    assert completed =~ "1 adopted pid=123 session=kept-session"
    assert completed =~ "__AIUR_CONTROL_EXIT__:0"
  end

  test "unavailable gap stays unknown instead of claiming zero downtime" do
    report = Report.from_record(%{"handoff_id" => "legacy", "outcome" => []})
    assert report.gap_ms == nil
    assert capture_io(fn -> CLI.print(report) end) =~ "gap=unknownms"
  end

  test "agents JSON exposes the live provider identity and adoption id" do
    snapshot = %{running: [%{identifier: "1", issue_id: "1", session_id: "thread-turn", codex_app_server_pid: 42, adopted_from: "restart"}]}
    output = capture_io(fn -> CLI.agents(snapshot: snapshot) end)
    [json, "__AIUR_CONTROL_EXIT__:0"] = String.split(output, "\n", trim: true)

    assert Jason.decode!(json)["running"] == [
             %{"identifier" => "1", "issue_id" => "1", "session_id" => "thread-turn", "provider_pid" => "42", "codex_app_server_pid" => 42, "adopted_from" => "restart", "skill_preload" => nil}
           ]
  end

  @tag :tmp_dir
  test "in projects mode the report reads each project's own state root and merges them", %{tmp_dir: dir} do
    for id <- ["o/a", "o/b"] do
      root = Path.join(dir, String.replace(id, "/", "_"))
      project = %Aiur.Project{id: id, repo: id, config_path: Path.join(root, "config"), state_root: root}
      parent = self()

      pid =
        spawn_link(fn ->
          {:ok, _} = Aiur.Project.Registry.register_root(project)
          send(parent, :registered)
          receive do: (:stop -> :ok)
        end)

      assert_receive :registered, 1_000
      on_exit(fn -> Process.exit(pid, :kill) end)

      record = %{
        "handoff_id" => "h-" <> String.last(id),
        "written_at" => "2026-10-15T10:00:00.000Z",
        "completed_at" => "2026-10-15T10:00:01.000Z",
        "outcome" => [%{"identifier" => id, "status" => "adopted"}]
      }

      Aiur.JsonStore.write!(Path.join([root, "handoff", "current.json"]) <> ".consumed", record)
    end

    assert {:ok, report} = Report.latest_all()
    assert report.handoff_id == "h-a,h-b"
    assert Enum.map(report.adopted, & &1["identifier"]) == ["o/a", "o/b"]
    # An expected id from only one project must not complete the restart wait while the other is missing.
    out = capture_io(fn -> CLI.report(expected_id: "h-a,h-z", wait_ms: 0) end)
    assert out =~ "adoption_report_timeout"
  end
end
