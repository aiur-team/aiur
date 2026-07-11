defmodule Aiur.RunTelemetryTaskTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Aiur.Telemetry.Dashboard, as: DashboardTask

  @fixtures Path.expand("../fixtures/run_telemetry", __DIR__)

  test "parses repeated and positional inputs relative to the caller" do
    caller = Path.join(System.tmp_dir!(), "aiur-dashboard-caller")

    assert {:ok, parsed} =
             DashboardTask.parse_args(
               [
                 "--input",
                 "one",
                 "-i",
                 "two",
                 "three",
                 "--output",
                 "reports/run.html",
                 "--repo",
                 "owner/repo",
                 "--review-resume-grace-seconds",
                 "45"
               ],
               caller_cwd: caller
             )

    assert parsed.inputs == Enum.map(~w(one two three), &Path.join(caller, &1))
    assert parsed.output == Path.join(caller, "reports/run.html")
    assert parsed.repo == "owner/repo"
    assert parsed.review_resume_grace_seconds == 45
  end

  test "parses default paths and normalizes a blank repository" do
    caller = Path.join(System.tmp_dir!(), "aiur-dashboard-default-caller")

    assert {:ok, defaults} = DashboardTask.parse_args([], caller_cwd: caller)
    assert defaults.inputs == [Path.expand("~/.aiur/logs")]
    assert defaults.output == Path.join(caller, "aiur-telemetry-dashboard.html")

    assert {:ok, blank_repo} =
             DashboardTask.parse_args(["--input", @fixtures, "--repo", "  "],
               caller_cwd: caller
             )

    assert blank_repo.repo == nil
  end

  test "rejects invalid options and non-positive grace values" do
    assert {:error, message} = DashboardTask.parse_args(["--unknown"])
    assert message =~ "Invalid option"

    assert {:error, message} =
             DashboardTask.parse_args(["--review-resume-grace-seconds", "0"])

    assert message =~ "positive integer"

    assert_raise Mix.Error, ~r/Invalid option/, fn ->
      DashboardTask.run(["--unknown"])
    end
  end

  test "help is available without telemetry or app supervision" do
    assert {:help, usage} = DashboardTask.parse_args(["--help"])
    assert usage =~ "mix aiur.telemetry.dashboard"
    assert usage =~ "default: 300"

    assert {:ok, parsed} = DashboardTask.parse_args(["--input", @fixtures])
    assert parsed.review_resume_grace_seconds == 300

    output = capture_io(fn -> DashboardTask.run(["--help"]) end)
    assert output =~ "Self-contained Aiur telemetry dashboard"
  end

  test "task writes the requested output and reports missing telemetry" do
    root = Path.join(System.tmp_dir!(), "aiur-dashboard-task-#{System.unique_integer([:positive])}")
    output = Path.join(root, "result.html")
    missing = Path.join(root, "missing")
    on_exit(fn -> File.rm_rf!(root) end)

    message =
      capture_io(fn ->
        assert :ok = DashboardTask.run(["--input", @fixtures, "--output", output])
      end)

    assert File.read!(output) =~ "<!doctype html>"
    assert message =~ output

    assert_raise Mix.Error, ~r/No telemetry files found/, fn ->
      DashboardTask.run(["--input", missing, "--output", output])
    end

    File.rm!(output)
    File.mkdir_p!(output)

    assert_raise Mix.Error, ~r/Could not generate telemetry dashboard: eisdir/, fn ->
      DashboardTask.run(["--input", @fixtures, "--output", output])
    end
  end
end
