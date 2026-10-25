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

  test "browser spec annotations identify the spec path without using the job shard name" do
    log = """
    new-failure :: BrowserSpec :: src/browser/tests/build-home-tools-parity.browser.spec.mjs
    new-failure :: BrowserSpec :: src/browser/tests/home.spec.mjs
    """

    assert [
             "src/browser/tests/build-home-tools-parity.browser.spec.mjs",
             "src/browser/tests/home.spec.mjs"
           ] = MergeGroupFailureEvidence.test_paths(log)

    assert [
             "BrowserSpec :: src/browser/tests/build-home-tools-parity.browser.spec.mjs",
             "BrowserSpec :: src/browser/tests/home.spec.mjs"
           ] =
             MergeGroupFailureEvidence.test_identities(log)
  end

  test "raw Playwright failure lines identify browser specs without annotations" do
    log = """
      1) [chromium] › tests/settings/toolbar.spec.mjs:30:27 › toolbar parity
      2) tests/home.spec.mjs:4:12 › home tools
      3) tests/build-home-tools-parity.spec.mjs:73:11 › parity
    """

    assert [
             "src/browser/tests/settings/toolbar.spec.mjs",
             "src/browser/tests/home.spec.mjs",
             "src/browser/tests/build-home-tools-parity.spec.mjs"
           ] = MergeGroupFailureEvidence.test_paths(log)

    assert [
             "BrowserSpec :: src/browser/tests/settings/toolbar.spec.mjs",
             "BrowserSpec :: src/browser/tests/home.spec.mjs",
             "BrowserSpec :: src/browser/tests/build-home-tools-parity.spec.mjs"
           ] = MergeGroupFailureEvidence.test_identities(log)
  end

  test "timestamped Actions lines retain raw browser and ExUnit failure identities" do
    log = """
    2026-10-24T18:20:20.5688806Z   1) tests/build-home-list-parity.browser.spec.mjs:30:27 › list parity
    2026-10-24T18:20:20.5688810Z   1) test exhausts process capacity (Aiur.ProcessExhaustionTest)
    2026-10-24T18:20:20.5688811Z      src/test/aiur/process_exhaustion_test.exs:42
    """

    assert ["src/test/aiur/process_exhaustion_test.exs", "src/browser/tests/build-home-list-parity.browser.spec.mjs"] =
             MergeGroupFailureEvidence.test_paths(log)

    assert [
             "test exhausts process capacity (Aiur.ProcessExhaustionTest) :: src/test/aiur/process_exhaustion_test.exs",
             "BrowserSpec :: src/browser/tests/build-home-list-parity.browser.spec.mjs"
           ] = MergeGroupFailureEvidence.test_identities(log)
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
