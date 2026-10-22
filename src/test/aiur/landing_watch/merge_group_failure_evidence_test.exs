defmodule Aiur.LandingWatch.MergeGroupFailureEvidenceTest do
  use ExUnit.Case, async: true

  alias Aiur.LandingWatch.MergeGroupFailureEvidence

  test "a main run list longer than the page cap keeps the read pages instead of failing" do
    parent = self()

    request = fn %{method: :get, url: url} ->
      id = System.unique_integer([:positive])
      send(parent, :main_page)

      {:ok,
       %{
         status: 200,
         body: %{"workflow_runs" => [%{"id" => id, "conclusion" => "failure"}]},
         headers: [{"link", "<#{url}&page=n>; rel=\"next\""}]
       }}
    end

    assert {:ok, paths} =
             MergeGroupFailureEvidence.recent_main_paths("main",
               token: "test-gh-token",
               request_fun: request,
               jobs_fun: fn id, _ -> {:ok, [%{"id" => id, "conclusion" => "failure"}]} end,
               job_log_fun: fn %{"id" => id}, _ -> {:ok, "  1) test failure #{id} (Aiur.Run#{id}Test)\n     test/run_#{id}_test.exs:1"} end
             )

    assert length(paths) == 5
    for _ <- 1..5, do: assert_received(:main_page)
    refute_received :main_page
  end

  test "a failed evidence fetch stays distinguishable from no matching failures" do
    assert {:error, :offline} =
             MergeGroupFailureEvidence.recent_main_paths("main",
               recent_main_failure_paths_fun: fn _, _ -> {:error, :offline} end
             )
  end

  test "failure paths only include ExUnit failure headers and normalize src-relative paths" do
    log = """
      1) test a failure (Aiur.SampleTest)
         test/aiur/sample_test.exs:41

      warning: test/aiur/other_test.exs:3:3
    """

    assert ["src/test/aiur/sample_test.exs"] = MergeGroupFailureEvidence.test_paths(log)
  end

  test "known flaky module signatures match ExUnit's rendered failure header" do
    root = Aiur.TestSupport.tmp_root!("merge-group-known-flake")
    path = Path.join(root, ".github/known-flaky-tests.txt")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "Aiur.SampleTest :: test known flaky behavior\n")

    assert Enum.any?(MergeGroupFailureEvidence.known_patterns(repo_root: root, known_failure_patterns: []), fn pattern ->
             String.contains?("1) test known flaky behavior (Aiur.SampleTest)", pattern)
           end)

    Aiur.TestCleanup.rm_rf!(root)
  end
end
