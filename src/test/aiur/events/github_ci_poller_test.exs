defmodule Aiur.Events.GithubCIPollerTest do
  use Aiur.TestSupport

  alias Aiur.Events.GithubCIPoller
  alias Aiur.Workflow

  setup do
    previous_token = System.get_env("GITHUB_TOKEN")
    System.put_env("GITHUB_TOKEN", "test-gh-token")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "owner/repo",
      tracker_label_prefix: "agent"
    )

    on_exit(fn -> restore_env("GITHUB_TOKEN", previous_token) end)
    :ok
  end

  test "passes completed observed checks without requiring a missing guard" do
    request_fun = fn %{url: url} ->
      cond do
        String.contains?(url, "/pulls?") ->
          {:ok, %{status: 200, body: [%{"number" => 71, "head" => %{"sha" => "current-sha"}}]}}

        String.contains?(url, "/check-runs?") ->
          {:ok,
           %{
             status: 200,
             body: %{
               "check_runs" => [
                 %{"name" => "lint", "status" => "completed", "conclusion" => "success"}
               ]
             }
           }}

        String.ends_with?(url, "/status") ->
          {:ok, %{status: 200, body: %{"state" => "success", "statuses" => []}}}
      end
    end

    assert {:ok, %{errors: [], results: [%{decision: :passed, head_sha: "current-sha", pr_number: 71}]}} =
             GithubCIPoller.poll(["42"], request_fun: request_fun)
  end

  test "returns pending for no observed checks or in-progress work" do
    assert %{decision: :pending, failures: []} = GithubCIPoller.evaluate_for_test([], %{"statuses" => []})

    assert %{decision: :pending, failures: []} =
             GithubCIPoller.evaluate_for_test(
               [%{"name" => "test", "status" => "in_progress", "conclusion" => nil}],
               %{"statuses" => []}
             )
  end

  test "uses the combined-status aggregate when contexts are absent" do
    assert %{decision: :passed, failures: []} =
             GithubCIPoller.evaluate_for_test([], %{"state" => "success", "statuses" => []})

    assert %{
             decision: :failed,
             failures: [%{name: "combined commit status", result: "failure"}]
           } = GithubCIPoller.evaluate_for_test([], %{"state" => "failure", "statuses" => []})

    assert %{decision: :pending, failures: []} =
             GithubCIPoller.evaluate_for_test([], %{"state" => "pending", "statuses" => []})
  end

  test "keeps a ticket pending until an open PR is visible" do
    request_fun = fn %{url: url} ->
      assert String.contains?(url, "/pulls?")
      {:ok, %{status: 200, body: []}}
    end

    assert {:ok,
            %{
              errors: [],
              results: [%{decision: :pending, pending_reason: :open_pr_not_yet_visible}]
            }} = GithubCIPoller.poll(["72"], request_fun: request_fun)
  end

  test "returns failed check details without suppressing a test failure" do
    assert %{
             decision: :failed,
             failures: [
               %{
                 name: "test",
                 kind: "check_run",
                 result: "failure",
                 excerpt: "expected green test suite"
               }
             ]
           } =
             GithubCIPoller.evaluate_for_test(
               [
                 %{
                   "name" => "test",
                   "status" => "completed",
                   "conclusion" => "failure",
                   "output" => %{"summary" => "expected green test suite"}
                 }
               ],
               %{"statuses" => []}
             )
  end

  test "reports one target failure without changing another target result" do
    request_fun = fn %{url: url} ->
      cond do
        String.contains?(url, "aiur%2F42") ->
          {:ok, %{status: 200, body: [%{"number" => 42, "head" => %{"sha" => "head-42"}}]}}

        String.contains?(url, "aiur%2F43") ->
          {:error, :timeout}

        String.contains?(url, "head-42/check-runs") ->
          {:ok, %{status: 200, body: %{"check_runs" => [%{"status" => "completed", "conclusion" => "success"}]}}}

        String.ends_with?(url, "head-42/status") ->
          {:ok, %{status: 200, body: %{"statuses" => []}}}
      end
    end

    assert {:ok, %{results: [%{decision: :passed, target: "42"}, %{decision: :pending, target: "43"}], errors: [{"43", {:pr_lookup, {:github, :timeout, %{}}}}]}} =
             GithubCIPoller.poll(["42", "43"], request_fun: request_fun)
  end

  test "uses the current PR head on every poll after a re-push" do
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    request_fun = fn %{url: url} ->
      cond do
        String.contains?(url, "/pulls?") ->
          head_number = Agent.get_and_update(calls, &{&1 + 1, &1 + 1})
          head_sha = "head-#{head_number}"
          {:ok, %{status: 200, body: [%{"number" => 77, "head" => %{"sha" => head_sha}}]}}

        String.contains?(url, "/check-runs?") ->
          {:ok,
           %{
             status: 200,
             body: %{
               "check_runs" => [
                 %{"name" => "test", "status" => "completed", "conclusion" => "success"}
               ]
             }
           }}

        String.ends_with?(url, "/status") ->
          {:ok, %{status: 200, body: %{"statuses" => []}}}
      end
    end

    assert {:ok, %{results: [%{decision: :passed, head_sha: "head-1"}]}} =
             GithubCIPoller.poll(["77"], request_fun: request_fun)

    assert {:ok, %{results: [%{decision: :passed, head_sha: "head-2"}]}} =
             GithubCIPoller.poll(["77"], request_fun: request_fun)
  end
end
