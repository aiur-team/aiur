defmodule Aiur.LandingWatch.MergeGroupQuarantineModuleTest do
  # Shaped like main run 42328076530, which failed 7 tests of one module and opened 7 PRs (#7748).
  use ExUnit.Case, async: true

  alias Aiur.CI.FailureDigest
  alias Aiur.LandingWatch.MergeGroupQuarantine

  @run "https://github.com/test-org/test-repo/actions/runs/42328076530/job/117676517063"

  setup do
    journal = Path.join(System.tmp_dir!(), "quarantine-module-#{System.unique_integer([:positive])}.json")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(journal) end)
    %{journal: journal}
  end

  test "one base run failing 3 tests in module A and 1 in module B opens 2 tickets and 2 PRs", %{journal: journal} do
    tests =
      [{"Aiur.FleetCapacityTest", "first"}, {"Aiur.FleetCapacityTest", "second"}, {"Aiur.FleetCapacityTest", "third"}, {"Aiur.OtherTest", "only"}]
      |> Enum.map(fn {module, name} -> %{identity: "#{module} :: #{name}", path: "src/test/#{Macro.underscore(module)}.exs", classification: :new_failure} end)

    digest = %FailureDigest{checks: [%{name: "coverage (2/4)", url: @run, tests: tests}], tests: tests}
    red = %{sha: "fb9f75853ec58c7c402947274faa1562939d5dff", completed_at: System.system_time(:millisecond) - 15 * 60_000, run_urls: [], digest: digest}

    assert :ok = MergeGroupQuarantine.process_completed([], [], "main", opts(journal, self(), red))

    assert_received {:flake_ticket, "Aiur.FleetCapacityTest", module_tests}
    assert length(module_tests) == 2
    assert_received {:flake_ticket, "Aiur.OtherTest", []}
    refute_received {:flake_ticket, _, _}

    assert_received {:quarantine_pr, %{identities: fleet}}
    assert Enum.sort(fleet) == ["Aiur.FleetCapacityTest :: first", "Aiur.FleetCapacityTest :: second", "Aiur.FleetCapacityTest :: third"]
    assert_received {:quarantine_pr, %{identities: ["Aiur.OtherTest :: only"]}}
    refute_received {:quarantine_pr, _}

    # A later poll finds every identity claimed and opens nothing more.
    assert :ok = MergeGroupQuarantine.process_completed([], [], "main", opts(journal, self(), red))
    refute_received {:flake_ticket, _, _}
    refute_received {:quarantine_pr, _}
  end

  defp opts(journal, parent, red) do
    [
      base_branch: "main",
      token: "test-gh-token",
      journal_path: journal,
      main_history_fun: fn -> [red] end,
      quarantine_list_fun: fn -> {:ok, ""} end,
      recent_main_failure_paths_fun: fn _, _ -> {:ok, []} end,
      job_log_fun: fn _, _ -> {:ok, ""} end,
      commit_paths_fun: fn _sha, _opts -> {:ok, ["src/lib/aiur/unrelated.ex"]} end,
      jobs_fun: fn _run, _opts -> {:ok, []} end,
      annotations_fun: fn _id, _opts -> {:ok, []} end,
      request_fun: fn
        %{method: :get, url: url} ->
          cond do
            url =~ "/commits?" -> {:ok, %{status: 200, body: [%{"sha" => "fixsha"}]}}
            url =~ "/compare/" -> {:ok, %{status: 200, body: %{"status" => "behind"}}}
            true -> flunk("unexpected request #{url}")
          end
      end,
      flake_recorder: fn failure, _run, [], recorder_opts ->
        send(parent, {:flake_ticket, failure.module, Map.get(failure, :module_tests, [])})
        recorder_opts[:issue_recorded_fun].(5200)
      end,
      quarantine_pr_fun: fn candidate, _ticket, _opts ->
        send(parent, {:quarantine_pr, candidate})
        {:ok, %{"number" => 5201}}
      end
    ]
  end
end
