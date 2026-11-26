defmodule Aiur.LandingWatch.FlakeFilingGateTest do
  use ExUnit.Case, async: true

  alias Aiur.LandingWatch.{FlakeFilingGate, MergeGroupQuarantine}

  @hour_ms 60 * 60 * 1_000
  @now_ms 1_800_000_000_000
  @failure %{module: "Aiur.ExampleTest", name: "flakes", path: "src/test/example_test.exs"}
  @run %{"id" => 7, "head_sha" => "runhead"}

  describe "test changed on the base branch after the run" do
    test "skips when the newest commit touching the test is not in the run head" do
      assert {:skip, :test_changed_on_base} = decide(compare_request("ahead"))
      assert {:skip, :test_changed_on_base} = decide(compare_request("diverged"))
    end

    test "files when the run already contained the newest change" do
      assert :file = decide(compare_request("behind"))
      assert :file = decide(compare_request("identical"))
    end

    test "files when the test has no base history or the lookup fails" do
      assert :file = decide(fn _ -> {:ok, %{status: 200, body: []}} end)
      assert :file = decide(fn _ -> {:ok, %{status: 500, body: %{}}} end)
    end

    test "asks for the base-branch history of the failing test file" do
      parent = self()

      request = fn %{url: url} = req ->
        send(parent, {:url, url})
        compare_request("behind").(req)
      end

      decide(request)
      assert_received {:url, commits_url}
      assert %{"sha" => "main", "path" => "src/test/example_test.exs"} = URI.decode_query(URI.parse(commits_url).query)
      assert_received {:url, compare_url}
      assert compare_url =~ "/compare/runhead...fixsha"
    end
  end

  describe "run age" do
    test "skips a run older than the max age without a newer failure" do
      request = fn _ -> flunk("stale runs must not query GitHub") end
      assert {:skip, :stale_run} = decide(request, @now_ms - 13 * @hour_ms, [row(@now_ms - 13 * @hour_ms)])
    end

    test "files an old run when the same test also failed on a newer run" do
      rows = [row(@now_ms - 13 * @hour_ms), row(@now_ms - @hour_ms)]
      assert :file = decide(compare_request("behind"), @now_ms - 13 * @hour_ms, rows)
    end

    test "a newer failure of a different test does not count" do
      rows = [row(@now_ms - 13 * @hour_ms), %{row(@now_ms - @hour_ms) | "identity" => "Aiur.OtherTest :: x"}]
      assert {:skip, :stale_run} = decide(compare_request("behind"), @now_ms - 13 * @hour_ms, rows)
    end

    test "the max age is configurable" do
      at = @now_ms - 13 * @hour_ms
      opts = [flake_max_run_age_ms: 24 * @hour_ms]
      assert :file = decide(compare_request("behind"), at, [row(at)], opts)
    end
  end

  test "merge-group quarantine does not file a flake whose test changed on main after the run" do
    runs = [failed_run(601, "pr-61-a", 20), failed_run(602, "pr-62-b", 10)]
    assert :ok = MergeGroupQuarantine.process_completed(runs, [], "main", quarantine_opts(compare_request("ahead")))
    refute_received :flake_ticket_recorded
  end

  test "merge-group quarantine does not file a flake seen only on runs older than the max age" do
    runs = [failed_run(611, "pr-63-a", 14 * 60), failed_run(612, "pr-64-b", 13 * 60)]
    assert :ok = MergeGroupQuarantine.process_completed(runs, [], "main", quarantine_opts(compare_request("behind")))
    refute_received :flake_ticket_recorded
  end

  test "merge-group quarantine still files a recent flake whose test did not change" do
    runs = [failed_run(621, "pr-65-a", 20), failed_run(622, "pr-66-b", 10)]
    assert :ok = MergeGroupQuarantine.process_completed(runs, [], "main", quarantine_opts(compare_request("behind")))
    assert_received :flake_ticket_recorded
  end

  defp quarantine_opts(request) do
    parent = self()
    journal = Path.join(System.tmp_dir!(), "flake-gate-#{System.unique_integer([:positive])}.json")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(journal) end)

    [
      token: "test-gh-token",
      journal_path: journal,
      request_fun: request,
      main_history_fun: fn -> [] end,
      recent_main_failure_paths_fun: fn _, _ -> {:ok, []} end,
      job_log_fun: fn _, _ -> {:ok, ""} end,
      quarantine_list_fun: fn -> {:ok, ""} end,
      changed_paths_fun: fn _pr, _opts -> {:ok, []} end,
      jobs_fun: fn _run, _opts -> {:ok, [%{"check_run_id" => 1, "name" => "test", "conclusion" => "failure"}]} end,
      annotations_fun: fn _id, _opts ->
        {:ok, [%{"title" => "aiur-test-failure", "message" => "new-failure :: Aiur.ExampleTest :: flakes", "path" => "src/test/example_test.exs"}]}
      end,
      flake_recorder: fn _failure, _run, _passed, recorder_opts ->
        send(parent, :flake_ticket_recorded)
        recorder_opts[:issue_recorded_fun].(900)
      end,
      quarantine_pr_fun: fn _candidate, _ticket, _opts -> {:ok, %{"number" => 901}} end
    ]
  end

  defp decide(request, run_at_ms \\ @now_ms - @hour_ms, rows \\ [], opts \\ []) do
    opts = Keyword.merge([token: "test-gh-token", request_fun: request, now_ms: @now_ms], opts)
    FlakeFilingGate.decide(@failure, @run, run_at_ms, rows, "main", opts)
  end

  defp compare_request(status) do
    fn %{method: :get, url: url} ->
      cond do
        url =~ "/commits?" -> {:ok, %{status: 200, body: [%{"sha" => "fixsha"}]}}
        url =~ "/compare/" -> {:ok, %{status: 200, body: %{"status" => status}}}
        true -> flunk("unexpected request #{url}")
      end
    end
  end

  defp row(at_ms), do: %{"identity" => "Aiur.ExampleTest :: flakes", "at_ms" => at_ms}

  defp failed_run(id, branch, minutes_ago) do
    %{
      "id" => id,
      "head_sha" => "head-#{id}",
      "conclusion" => "failure",
      "head_branch" => "gh-readonly-queue/main/#{branch}",
      "html_url" => "https://github.com/test-org/test-repo/actions/runs/#{id}",
      "created_at" => DateTime.utc_now() |> DateTime.add(-minutes_ago * 60) |> DateTime.to_iso8601()
    }
  end
end
