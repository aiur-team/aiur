defmodule Aiur.Events.GithubCIPollerTest do
  use Aiur.TestSupport
  import Aiur.TestSupport.CIPollerFixture

  setup :ci_poller_env

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
                 "head" => pr_head("aiur/42", "current-sha"),
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
             poll(["42"], request_fun: request_fun)
  end

  # The GraphQL batch carries draft + review decision alongside the checks so
  # the daemon can surface DRAFT in the Executor queue and alert on the
  # approved-green-draft stall (#1974).
  test "threads draft and review decision from the GraphQL batch into the result" do
    batch = %{
      "42" => %{
        pull_request: %{
          "number" => 77,
          "state" => "open",
          "head" => pr_head("aiur/42-x", "head-77"),
          "base" => %{"ref" => "main"},
          "merge_queue" => %{
            draft?: true,
            review_decision: "APPROVED",
            mergeable: "MERGEABLE",
            merge_state_status: "BLOCKED",
            auto_merge_request: nil,
            merge_queue_entry: nil
          }
        },
        check_runs: [%{"name" => "test", "status" => "completed", "conclusion" => "success"}],
        commit_status: %{"statuses" => [], "state" => ""}
      }
    }

    assert {:ok, %{errors: [], results: [result]}} =
             poll(["42"], ci_batch: batch)

    assert result.decision == :pending
    assert result.pending_reason == :draft_pull_request
    assert result.draft? == true
    assert result.review_decision == "APPROVED"
  end

  test "a ready (non-draft) batched PR reports draft false" do
    batch = %{
      "42" => %{
        pull_request: %{
          "number" => 77,
          "state" => "open",
          "head" => pr_head("aiur/42-x", "head-77"),
          "base" => %{"ref" => "main"},
          "merge_queue" => %{
            draft?: false,
            review_decision: nil,
            mergeable: "MERGEABLE",
            merge_state_status: "BLOCKED",
            auto_merge_request: nil,
            merge_queue_entry: nil
          }
        },
        check_runs: [%{"name" => "test", "status" => "completed", "conclusion" => "success"}],
        commit_status: %{"statuses" => [], "state" => ""}
      }
    }

    assert {:ok, %{errors: [], results: [%{draft?: false, review_decision: nil}]}} =
             poll(["42"], ci_batch: batch)
  end

  test "carries the batched merge-queue recovery observation into the result" do
    ci_batch = %{
      "42" => %{
        pull_request: %{
          "number" => 71,
          "head" => pr_head("aiur/71", "parked-head"),
          "base" => %{"ref" => "main"},
          "merge_queue" => %{
            draft?: false,
            review_decision: "APPROVED",
            mergeable: "MERGEABLE",
            merge_state_status: "BLOCKED",
            auto_merge_request: nil,
            merge_queue_entry: nil
          }
        },
        check_runs: [%{"name" => "test", "status" => "completed", "conclusion" => "success"}],
        commit_status: %{"statuses" => []}
      }
    }

    assert {:ok,
            %{
              errors: [],
              results: [
                %{
                  decision: :passed,
                  head_sha: "parked-head",
                  pr_number: 71,
                  draft?: false,
                  review_decision: "APPROVED",
                  mergeable: "MERGEABLE",
                  merge_state_status: "BLOCKED",
                  auto_merge_request: nil,
                  merge_queue_entry: nil
                }
              ]
            }} = poll(["42"], ci_batch: ci_batch, base_branch: "main")
  end

  # #2310 — a target the batch displaced because a webhook delivery answered it
  # carries an inert result: no verdict, no failure, no pass. The lifecycle
  # treats it as a no-op (`delivered: true`), because a CI verdict is never
  # answered from a held body at any age (R10); the next non-displaced read
  # produces the real verdict.
  test "a delivered (displaced) batch entry carries an inert result, never a verdict" do
    ci_batch = %{
      "42" => %{
        delivered: true,
        head_sha: "head-77",
        pr_number: 77,
        check_run: %{
          "id" => 5501,
          "name" => "test",
          "status" => "completed",
          "conclusion" => "success",
          "started_at" => "2026-08-22T11:55:00Z",
          "completed_at" => "2026-08-22T12:05:00Z"
        }
      }
    }

    assert {:ok, %{errors: [], results: [result]}} = poll(["42"], ci_batch: ci_batch)

    assert result.delivered == true
    assert result.target == "42"
    assert result.head_sha == "head-77"
    assert result.pr_number == 77
    refute Map.has_key?(result, :decision)
    refute Map.has_key?(result, :failures)
    refute Map.has_key?(result, :pending_reason)
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
            }} = poll(["72"], request_fun: request_fun)
  end

  test "logs the exact head and pending classification for a partial snapshot" do
    request_fun = fn %{url: url} ->
      cond do
        String.contains?(url, "/pulls?") ->
          {:ok,
           %{
             status: 200,
             body: [
               %{
                 "number" => 91,
                 "head" => pr_head("aiur/91", "partial-head"),
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
                 %{"name" => "lint", "status" => "completed", "conclusion" => "failure"},
                 %{"name" => "test", "status" => "in_progress", "conclusion" => nil}
               ]
             }
           }}

        String.ends_with?(url, "/status") ->
          {:ok, %{status: 200, body: %{"state" => "pending", "statuses" => []}}}
      end
    end

    log =
      capture_log([level: :debug], fn ->
        assert {:ok,
                %{
                  results: [
                    %{
                      decision: :pending,
                      pending_reason: :check_runs_incomplete,
                      head_sha: "partial-head"
                    }
                  ]
                }} = poll(["91"], request_fun: request_fun)
      end)

    assert log =~ "head=partial-head decision=pending"
    assert log =~ "pending_reason=:check_runs_incomplete"
  end

  test "reports one target failure without changing another target result" do
    # Both targets read the same open-pull-request listing URL — the
    # `head=<owner>:aiur/<n>` probe that used to tell the two lookups apart by
    # URL was a redundant second request per target and is gone. The listing now
    # carries both pull requests, and the failure under test is moved onto a
    # request that is still per-target: "43"'s check-run read.
    request_fun = fn %{url: url} ->
      cond do
        String.contains?(url, "/pulls?") ->
          {:ok,
           %{
             status: 200,
             body: [
               %{
                 "number" => 42,
                 "head" => pr_head("aiur/42", "head-42"),
                 "base" => %{"ref" => "main"}
               },
               %{
                 "number" => 43,
                 "head" => pr_head("aiur/43", "head-43"),
                 "base" => %{"ref" => "main"}
               }
             ]
           }}

        String.contains?(url, "head-43/check-runs") ->
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
             poll(["42", "43"], request_fun: request_fun)

    assert {"43", {:github, :timeout, %{reason: :timeout}}} = error
  end

  test "reports a failing pull request lookup as a pr_lookup error" do
    request_fun = fn %{url: url} ->
      cond do
        String.contains?(url, "/pulls?") ->
          {:error, :timeout}
      end
    end

    assert {:ok,
            %{
              results: [%{decision: :pending, target: "42"}],
              errors: [{"42", {:pr_lookup, {:github, :timeout, %{reason: :timeout}}}}]
            }} = poll(["42"], request_fun: request_fun)
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
                 "head" => pr_head("aiur/77", head_sha),
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
             poll(["77"], request_fun: request_fun)

    assert {:ok, %{results: [%{decision: :passed, head_sha: "head-2"}]}} =
             poll(["77"], request_fun: request_fun)
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
                 "head" => pr_head("aiur/78", head_sha),
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
            }} = poll(["78"], request_fun: request_fun)
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
                 "head" => pr_head("aiur/88", "head-88"),
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
             poll(["88"], request_fun: request_fun)
  end
end
