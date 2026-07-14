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

  test "passes completed Actions checks when the status endpoint has no legacy statuses" do
    request_fun = fn %{url: url} ->
      cond do
        String.contains?(url, "/pulls?") ->
          {:ok,
           %{
             status: 200,
             body: [
               %{
                 "number" => 71,
                 "head" => %{"sha" => "current-sha"},
                 "base" => %{"ref" => "main"}
               }
             ]
           }}

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
          {:ok, %{status: 200, body: %{"state" => "pending", "total_count" => 0, "statuses" => []}}}
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

  test "reports a test-only check failure for agent judgment" do
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

  test "does not suppress a test-only check failure" do
    assert %{
             decision: :failed,
             failures: [%{name: "test", kind: "check_run", result: "failure"}]
           } =
             GithubCIPoller.evaluate_for_test(
               [
                 %{"name" => "test", "status" => "completed", "conclusion" => "failure"},
                 %{"name" => "lint", "status" => "completed", "conclusion" => "success"}
               ],
               %{"state" => "pending", "total_count" => 0, "statuses" => []}
             )
  end

  test "reports one target failure without changing another target result" do
    request_fun = fn %{url: url} ->
      cond do
        String.contains?(url, "aiur%2F42") ->
          {:ok,
           %{
             status: 200,
             body: [
               %{
                 "number" => 42,
                 "head" => %{"sha" => "head-42"},
                 "base" => %{"ref" => "main"}
               }
             ]
           }}

        String.contains?(url, "aiur%2F43") ->
          {:error, :timeout}

        String.contains?(url, "head-42/check-runs") ->
          {:ok, %{status: 200, body: %{"check_runs" => [%{"status" => "completed", "conclusion" => "success"}]}}}

        String.ends_with?(url, "head-42/status") ->
          {:ok, %{status: 200, body: %{"statuses" => []}}}
      end
    end

    assert {:ok,
            %{
              results: [%{decision: :passed, target: "42"}, %{decision: :pending, target: "43"}],
              errors: [error]
            }} =
             GithubCIPoller.poll(["42", "43"], request_fun: request_fun)

    assert {"43", {:pr_lookup, {:github, :timeout, %{reason: :timeout}}}} = error
  end

  test "uses the current PR head on every poll after a re-push" do
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    request_fun = fn %{url: url} ->
      cond do
        String.contains?(url, "/pulls?") ->
          head_number = Agent.get_and_update(calls, fn count -> {div(count, 2) + 1, count + 1} end)
          head_sha = "head-#{head_number}"

          {:ok,
           %{
             status: 200,
             body: [
               %{
                 "number" => 77,
                 "head" => %{"sha" => head_sha},
                 "base" => %{"ref" => "main"}
               }
             ]
           }}

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

  test "keeps CI pending when the head changes during an observation" do
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    request_fun = fn %{url: url} ->
      cond do
        String.contains?(url, "/pulls?") ->
          head_sha =
            Agent.get_and_update(calls, fn
              0 -> {"old-head", 1}
              _ -> {"new-head", 2}
            end)

          {:ok,
           %{
             status: 200,
             body: [
               %{
                 "number" => 78,
                 "head" => %{"sha" => head_sha},
                 "base" => %{"ref" => "main"}
               }
             ]
           }}

        String.contains?(url, "/check-runs?") ->
          {:ok, %{status: 200, body: %{"check_runs" => [%{"status" => "completed", "conclusion" => "success"}]}}}

        String.ends_with?(url, "/status") ->
          {:ok, %{status: 200, body: %{"state" => "success", "statuses" => []}}}
      end
    end

    assert {:ok,
            %{
              results: [
                %{decision: :pending, pending_reason: :head_changed, head_sha: "new-head"}
              ]
            }} = GithubCIPoller.poll(["78"], request_fun: request_fun)
  end

  test "repairs a base that changes while CI is being observed" do
    parent = self()
    {:ok, pull_reads} = Agent.start_link(fn -> 0 end)

    request_fun = fn request ->
      url = request.url

      cond do
        request.method == :get and String.contains?(url, "/pulls?") ->
          base = Agent.get_and_update(pull_reads, fn count -> {if(count == 0, do: "main", else: "v2"), count + 1} end)

          {:ok,
           %{
             status: 200,
             body: [
               %{
                 "number" => 79,
                 "head" => %{"sha" => "head-79"},
                 "base" => %{"ref" => base}
               }
             ]
           }}

        request.method == :get and String.contains?(url, "/check-runs?") ->
          {:ok,
           %{
             status: 200,
             body: %{"check_runs" => [%{"status" => "completed", "conclusion" => "success"}]}
           }}

        request.method == :get and String.ends_with?(url, "/status") ->
          {:ok, %{status: 200, body: %{"state" => "success", "statuses" => []}}}

        request.method == :patch ->
          send(parent, {:base_repaired_during_observation, request.body})
          {:ok, %{status: 200, body: %{"base" => %{"ref" => "main"}}}}
      end
    end

    assert {:ok,
            %{
              errors: [],
              results: [
                %{
                  decision: :failed,
                  failures: [%{name: "pull request base branch", result: "repaired"}]
                }
              ]
            }} = GithubCIPoller.poll(["79"], request_fun: request_fun, base_branch: "main")

    assert_receive {:base_repaired_during_observation, %{"base" => "main"}}
  end

  test "does not pass when a later check-run page contains a failure" do
    request_fun = fn %{url: url} ->
      cond do
        String.contains?(url, "/pulls?") ->
          {:ok,
           %{
             status: 200,
             body: [
               %{
                 "number" => 88,
                 "head" => %{"sha" => "head-88"},
                 "base" => %{"ref" => "main"}
               }
             ]
           }}

        String.contains?(url, "page=2") ->
          {:ok,
           %{
             status: 200,
             body: %{"check_runs" => [%{"name" => "test", "status" => "completed", "conclusion" => "failure"}]}
           }}

        String.contains?(url, "/check-runs?") ->
          {:ok,
           %{
             status: 200,
             headers: [{"link", "<https://api.github.com/check-runs?page=2>; rel=\"next\""}],
             body: %{"check_runs" => [%{"name" => "lint", "status" => "completed", "conclusion" => "success"}]}
           }}

        String.ends_with?(url, "/status") ->
          {:ok, %{status: 200, body: %{"state" => "success", "statuses" => []}}}
      end
    end

    assert {:ok, %{results: [%{decision: :failed, failures: [%{name: "test"}]}]}} =
             GithubCIPoller.poll(["88"], request_fun: request_fun)
  end

  test "repairs configured main on a pre-existing draft targeting repository default v2" do
    parent = self()

    request_fun = fn
      %{method: :get, url: url} when is_binary(url) ->
        assert String.contains?(url, "/pulls?")

        {:ok,
         %{
           status: 200,
           body: [
             %{
               "number" => 1144,
               "draft" => true,
               "head" => %{"sha" => "head-1144"},
               "base" => %{"ref" => "v2"}
             }
           ]
         }}

      %{method: :patch, url: url, body: body} ->
        send(parent, {:base_repaired, url, body})

        {:ok,
         %{
           status: 200,
           body: %{
             "number" => 1144,
             "draft" => true,
             "base" => %{"ref" => "main"}
           }
         }}
    end

    assert {:ok,
            %{
              errors: [],
              results: [
                %{
                  decision: :failed,
                  pr_number: 1144,
                  failures: [
                    %{
                      name: "pull request base branch",
                      result: "repaired",
                      excerpt: excerpt
                    }
                  ]
                }
              ]
            }} = GithubCIPoller.poll(["1146"], request_fun: request_fun, base_branch: "main")

    assert_receive {:base_repaired, url, %{"base" => "main"}}
    assert String.ends_with?(url, "/repos/owner/repo/pulls/1144")
    assert excerpt =~ "CI recorded before the repair is not valid"
    assert excerpt =~ "baseRefName"
  end

  test "returns actionable CI failure when automatic wrong-base repair fails" do
    parent = self()

    request_fun = fn
      %{method: :get, url: url} ->
        assert String.contains?(url, "/pulls?")

        {:ok,
         %{
           status: 200,
           body: [
             %{
               "number" => 1145,
               "draft" => true,
               "head" => %{"sha" => "head-1145"},
               "base" => %{"ref" => "v2"}
             }
           ]
         }}

      %{method: :patch, body: %{"base" => "main"}} ->
        send(parent, :base_repair_attempted)
        {:ok, %{status: 422, body: %{"message" => "base is invalid"}}}
    end

    assert {:ok,
            %{
              errors: [],
              results: [
                %{
                  decision: :failed,
                  failures: [
                    %{
                      name: "pull request base branch",
                      kind: "pull_request",
                      result: "repair_failed",
                      excerpt: excerpt
                    }
                  ]
                }
              ]
            }} = GithubCIPoller.poll(["1146"], request_fun: request_fun, base_branch: "main")

    assert_receive :base_repair_attempted
    assert excerpt =~ ~s(targets "v2")
    assert excerpt =~ ~s(tracker.base_branch is "main")
    assert excerpt =~ "baseRefName"
  end
end
