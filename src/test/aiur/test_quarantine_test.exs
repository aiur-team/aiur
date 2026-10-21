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
    test_root = Path.join(File.cwd!(), "test")
    path = Path.join(test_root, "quarantine.txt")
    assert {:ok, entries} = TestQuarantine.read(path)

    identities = Enum.map(entries, &{&1.module, &1.name})
    assert identities == Enum.sort(identities)
    assert length(identities) == length(Enum.uniq(identities))
    assert Enum.all?(entries, &(&1.ticket =~ ~r/^#?[1-9][0-9]*$/))

    test_modules = test_root |> Path.join("**/*_test.exs") |> Path.wildcard() |> test_module_names()

    assert Enum.all?(entries, &MapSet.member?(test_modules, &1.module))

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

  test "a listed describe-block test is excluded by the name ExUnit gives it" do
    assert {:ok, entries} = TestQuarantine.read(Path.join([File.cwd!(), "test", "quarantine.txt"]))

    tags = %{
      module: Aiur.DecisionStore.EnrichmentTest,
      describe: "supervisor enrichment",
      test: :"test supervisor enrichment exact replay is duplicate while changed reuse conflicts without append or notification"
    }

    assert {:excluded, "due to test filter"} = ExUnit.Filters.eval([], TestQuarantine.filters(entries), tags, :test)
  end

  test "the blocking ExUnit run config excludes a listed test by its exact name" do
    assert {:test, :"test create freezes the baseline and reports its window, count and coverage"} in ExUnit.configuration()[:exclude]
  end

  defp test_module_names(files) do
    files
    |> Enum.flat_map(fn file ->
      file
      |> File.read!()
      |> then(&Regex.scan(~r/defmodule\s+([A-Z][A-Za-z0-9_.]*)\s+do/, &1, capture: :all_but_first))
      |> Enum.map(&List.first/1)
    end)
    |> MapSet.new()
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
