defmodule Aiur.TestQuarantineTest do
  use ExUnit.Case, async: true

  alias Aiur.TestQuarantine
  alias Aiur.TestQuarantine.Detector

  test "parses comments, exact test names, and ticket provenance" do
    source = "# test, name, ticket\nAiur.ExampleTest\tkeeps the exact name\t#42\n"

    assert {:ok, [%{module: "Aiur.ExampleTest", name: "keeps the exact name", ticket: "#42"}]} =
             TestQuarantine.parse(source)
  end

  test "rejects malformed entries with their source line" do
    assert {:error, {:invalid_quarantine_entry, 2}} = TestQuarantine.parse("# valid comment\nnot a valid row\n")
  end

  test "the checked-in quarantine list parses and excludes its exact entries" do
    path = Path.join([File.cwd!(), "test", "quarantine.txt"])
    assert {:ok, entries} = TestQuarantine.read(path)
    assert length(entries) == 15

    assert {:excluded, "due to test filter"} =
             ExUnit.Filters.eval(
               [],
               TestQuarantine.filters(entries),
               %{test: :"test create freezes the baseline and reports its window, count and coverage"},
               :test
             )

    assert {:excluded, "due to module filter"} =
             ExUnit.Filters.eval([], TestQuarantine.filters(entries), %{module: :"Aiur.Core.AgentRunnerCheckpointQueueTest"}, :test)
  end

  test "the blocking ExUnit run config excludes a listed test by its exact name" do
    assert {:test, :"test create freezes the baseline and reports its window, count and coverage"} in ExUnit.configuration()[:exclude]
  end

  test "repeated failures in two unrelated pull requests within a day qualify" do
    now = 1_800_000_000_000

    rows = [
      %{identity: "Aiur.ExampleTest :: flakes", pr: 41, run_url: "https://github.com/o/r/actions/runs/1", at_ms: now - 60_000, path: "src/test/example_test.exs", group_prs: [41]},
      %{identity: "Aiur.ExampleTest :: flakes", pr: 42, run_url: "https://github.com/o/r/actions/runs/2", at_ms: now - 30_000, path: "src/test/example_test.exs", group_prs: [42]}
    ]

    assert {:ok, [%{identity: "Aiur.ExampleTest :: flakes", observations: ^rows}]} =
             Detector.repeated(rows, now, fn _pr -> {:ok, []} end)
  end

  test "the detector ignores same-PR repeats, old failures, and tests changed by a failing PR" do
    now = 1_800_000_000_000
    old = %{identity: "Aiur.ExampleTest :: flakes", pr: 41, run_url: "run-1", at_ms: now - 90_000_000, path: "src/test/example_test.exs", group_prs: [41]}
    fresh = %{old | pr: 42, run_url: "run-2", at_ms: now - 30_000, group_prs: [42]}

    assert {:ok, []} = Detector.repeated([fresh, %{fresh | run_url: "run-3"}], now, fn _pr -> {:ok, []} end)
    assert {:ok, []} = Detector.repeated([old, fresh], now, fn _pr -> {:ok, []} end)
    assert {:ok, []} = Detector.repeated([%{fresh | pr: 41, group_prs: [41]}], now, fn _pr -> {:ok, ["src/test/example_test.exs"]} end)
    same_pr = %{fresh | run_url: "run-3"}
    same_run = %{fresh | pr: 41, group_prs: [41]}
    assert {:ok, []} = Detector.repeated([fresh, same_pr], now, fn _pr -> {:ok, []} end)
    assert {:ok, []} = Detector.repeated([fresh, same_run], now, fn _pr -> {:ok, []} end)
  end

  test "same PRs failing in both merge groups are not independent evidence" do
    now = 1_800_000_000_000

    rows = [
      %{identity: "Aiur.ExampleTest :: flakes", pr: 41, run_url: "run-1", at_ms: now - 60_000, path: "test/example_test.exs", group_prs: [41, 42]},
      %{identity: "Aiur.ExampleTest :: flakes", pr: 42, run_url: "run-1", at_ms: now - 60_000, path: "test/example_test.exs", group_prs: [41, 42]},
      %{identity: "Aiur.ExampleTest :: flakes", pr: 41, run_url: "run-2", at_ms: now - 30_000, path: "test/example_test.exs", group_prs: [41, 42]},
      %{identity: "Aiur.ExampleTest :: flakes", pr: 42, run_url: "run-2", at_ms: now - 30_000, path: "test/example_test.exs", group_prs: [41, 42]}
    ]

    assert {:ok, []} = Detector.repeated(rows, now, fn _pr -> {:ok, []} end)
  end
end
