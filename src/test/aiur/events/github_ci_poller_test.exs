defmodule Aiur.Events.GithubCIPollerTest do
  use Aiur.TestSupport

  alias Aiur.{CIApprovalStore, Workflow}
  alias Aiur.Events.GithubCIPoller

  setup do
    previous_token = System.get_env("GITHUB_TOKEN")
    previous_store_path = Application.get_env(:aiur, :ci_approval_store_path)

    store_path =
      Path.join(System.tmp_dir!(), "github_ci_poller_#{System.unique_integer([:positive])}.json")

    System.put_env("GITHUB_TOKEN", "test-gh-token")
    Application.put_env(:aiur, :ci_approval_store_path, store_path)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "owner/repo",
      tracker_label_prefix: "agent"
    )

    on_exit(fn ->
      restore_env("GITHUB_TOKEN", previous_token)

      if is_nil(previous_store_path),
        do: Application.delete_env(:aiur, :ci_approval_store_path),
        else: Application.put_env(:aiur, :ci_approval_store_path, previous_store_path)

      File.rm(store_path)
    end)

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

  test "carries batched draft and review state into the lifecycle result" do
    ci_batch = %{
      "42" => %{
        pull_request: %{
          "number" => 71,
          "head" => %{"sha" => "approved-draft-head"},
          "base" => %{"ref" => "main"},
          "draft" => true,
          "review_decision" => "APPROVED"
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
                  draft?: true,
                  review_decision: "APPROVED",
                  head_sha: "approved-draft-head",
                  pr_number: 71
                }
              ]
            }} = GithubCIPoller.poll(["42"], ci_batch: ci_batch, base_branch: "main")
  end

  test "an alert-only target reads batched review state without evaluating or repairing CI" do
    ci_batch = %{
      "42" => %{
        pull_request: %{
          "number" => 71,
          "head" => %{"sha" => "approved-draft-head"},
          "base" => %{"ref" => "wrong-base"},
          "draft" => true,
          "review_decision" => "APPROVED"
        },
        check_runs: [%{"name" => "test", "status" => "completed", "conclusion" => "failure"}],
        commit_status: %{"state" => "failure", "statuses" => []}
      }
    }

    assert {:ok,
            %{
              errors: [],
              results: [
                %{
                  decision: :pending,
                  pending_reason: :alert_only,
                  draft?: true,
                  review_decision: "APPROVED",
                  head_sha: "approved-draft-head",
                  pr_number: 71
                }
              ]
            }} =
             GithubCIPoller.poll(["42"],
               ci_batch: ci_batch,
               alert_only_targets: MapSet.new(["42"]),
               base_branch: "main"
             )
  end

  test "an alert-only target clears draft state when the authoritative batch has no open PR" do
    ci_batch = %{"42" => %{pull_request: nil}}

    assert {:ok,
            %{
              errors: [],
              results: [
                %{
                  decision: :pending,
                  pending_reason: :open_pr_not_yet_visible,
                  draft?: false
                }
              ]
            }} =
             GithubCIPoller.poll(["42"],
               ci_batch: ci_batch,
               alert_only_targets: MapSet.new(["42"])
             )
  end

  test "an alert-only target clears draft state when REST reports no open PR" do
    request_fun = fn %{method: :get, url: url} ->
      assert String.contains?(url, "/pulls?")
      {:ok, %{status: 200, body: []}}
    end

    assert {:ok,
            %{
              errors: [],
              results: [
                %{
                  decision: :pending,
                  pending_reason: :open_pr_not_yet_visible,
                  draft?: false
                }
              ]
            }} =
             GithubCIPoller.poll(["42"],
               request_fun: request_fun,
               alert_only_targets: MapSet.new(["42"])
             )
  end

  test "carries approved draft state through the REST fallback" do
    request_fun = fn
      %{method: :get, url: url} ->
        cond do
          String.contains?(url, "/pulls?") ->
            {:ok,
             %{
               status: 200,
               body: [
                 %{
                   "number" => 71,
                   "draft" => true,
                   "head" => %{"sha" => "approved-draft-head"},
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
            {:ok, %{status: 200, body: %{"state" => "pending", "statuses" => []}}}
        end

      %{method: :post, url: "https://api.github.com/graphql", body: body} ->
        assert body["query"] =~ "reviewDecision"
        assert body["variables"] == %{"owner" => "owner", "repo" => "repo", "number" => 71}

        {:ok,
         %{
           status: 200,
           body: %{
             "data" => %{
               "repository" => %{"pullRequest" => %{"reviewDecision" => "APPROVED"}}
             }
           }
         }}
    end

    assert {:ok,
            %{
              errors: [],
              results: [
                %{
                  decision: :passed,
                  draft?: true,
                  review_decision: "APPROVED",
                  head_sha: "approved-draft-head",
                  pr_number: 71
                }
              ]
            }} = GithubCIPoller.poll(["42"], request_fun: request_fun)
  end

  test "keeps draft review state unknown when the REST fallback review read fails" do
    request_fun = fn
      %{method: :get, url: url} ->
        cond do
          String.contains?(url, "/pulls?") ->
            {:ok,
             %{
               status: 200,
               body: [
                 %{
                   "number" => 71,
                   "draft" => true,
                   "head" => %{"sha" => "unknown-review-head"},
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
            {:ok, %{status: 200, body: %{"state" => "pending", "statuses" => []}}}
        end

      %{method: :post, url: "https://api.github.com/graphql"} ->
        {:ok, %{status: 502, body: %{}}}
    end

    assert {:ok, %{errors: [], results: [%{decision: :passed, draft?: true} = result]}} =
             GithubCIPoller.poll(["42"], request_fun: request_fun)

    refute Map.has_key?(result, :review_decision)
  end

  test "carries approved draft state when the CI read fails before the PR recheck" do
    request_fun = fn
      %{method: :get, url: url} ->
        cond do
          String.contains?(url, "/pulls?") ->
            {:ok,
             %{
               status: 200,
               body: [
                 %{
                   "number" => 71,
                   "draft" => true,
                   "head" => %{"sha" => "approved-draft-head"},
                   "base" => %{"ref" => "main"}
                 }
               ]
             }}

          String.contains?(url, "/check-runs?") ->
            {:ok, %{status: 502, body: %{}}}
        end

      %{method: :post, url: "https://api.github.com/graphql", body: body} ->
        assert body["variables"] == %{"owner" => "owner", "repo" => "repo", "number" => 71}

        {:ok,
         %{
           status: 200,
           body: %{
             "data" => %{
               "repository" => %{"pullRequest" => %{"reviewDecision" => "APPROVED"}}
             }
           }
         }}
    end

    assert {:ok,
            %{
              results: [
                %{
                  decision: :pending,
                  pending_reason: :ci_lookup_unavailable,
                  draft?: true,
                  review_decision: "APPROVED",
                  pr_number: 71,
                  head_sha: "approved-draft-head",
                  error: reason
                }
              ],
              errors: [{"42", reason}]
            }} = GithubCIPoller.poll(["42"], request_fun: request_fun)
  end

  test "carries ready state without a review lookup when the CI read fails" do
    request_fun = fn %{method: :get, url: url} ->
      cond do
        String.contains?(url, "/pulls?") ->
          {:ok,
           %{
             status: 200,
             body: [
               %{
                 "number" => 71,
                 "draft" => false,
                 "head" => %{"sha" => "ready-head"},
                 "base" => %{"ref" => "main"}
               }
             ]
           }}

        String.contains?(url, "/check-runs?") ->
          {:ok, %{status: 502, body: %{}}}
      end
    end

    assert {:ok,
            %{
              results: [
                %{
                  decision: :pending,
                  pending_reason: :ci_lookup_unavailable,
                  draft?: false,
                  pr_number: 71,
                  head_sha: "ready-head",
                  error: reason
                }
              ],
              errors: [{"42", reason}]
            }} = GithubCIPoller.poll(["42"], request_fun: request_fun)
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

  test "ignores explicitly non-blocking check failures" do
    check_runs = [
      %{"name" => "test", "status" => "completed", "conclusion" => "success"},
      %{
        "name" => "quarantined tests (non-blocking)",
        "status" => "completed",
        "conclusion" => "failure"
      },
      %{"name" => "advisory scan (non-blocking)", "status" => "in_progress", "conclusion" => nil}
    ]

    assert %{decision: :passed, failures: []} =
             GithubCIPoller.evaluate_for_test(check_runs, %{"state" => "pending", "statuses" => []})
  end

  test "waits for every check before reporting the complete failure set" do
    partial_snapshot = [
      %{"name" => "lint", "status" => "completed", "conclusion" => "failure"},
      %{"name" => "test", "status" => "in_progress", "conclusion" => nil},
      %{"name" => "dialyzer", "status" => "queued", "conclusion" => nil}
    ]

    assert %{
             decision: :pending,
             pending_reason: :check_runs_incomplete,
             failures: [%{name: "lint", result: "failure"}]
           } = GithubCIPoller.evaluate_for_test(partial_snapshot, %{"statuses" => []})

    terminal_snapshot = [
      %{"name" => "dialyzer", "status" => "completed", "conclusion" => "success"},
      %{"name" => "test", "status" => "completed", "conclusion" => "timed_out"},
      %{"name" => "lint", "status" => "completed", "conclusion" => "failure"}
    ]

    assert %{
             decision: :failed,
             failures: [
               %{name: "test", result: "timed_out"},
               %{name: "lint", result: "failure"}
             ]
           } = GithubCIPoller.evaluate_for_test(terminal_snapshot, %{"statuses" => []})
  end

  test "treats cancelled and stale checks as replacement work instead of code failures" do
    for conclusion <- ["cancelled", "stale"] do
      assert %{
               decision: :pending,
               pending_reason: :check_runs_incomplete,
               failures: []
             } =
               GithubCIPoller.evaluate_for_test(
                 [%{"name" => "test", "status" => "completed", "conclusion" => conclusion}],
                 %{"statuses" => []}
               )
    end
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
                 "head" => %{"sha" => "partial-head"},
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
                }} = GithubCIPoller.poll(["91"], request_fun: request_fun)
      end)

    assert log =~ "head=partial-head decision=pending"
    assert log =~ "pending_reason=:check_runs_incomplete"
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
        request.method == :post and request.url == "https://api.github.com/graphql" ->
          {:ok,
           %{
             status: 200,
             body: %{
               "data" => %{
                 "repository" => %{"pullRequest" => %{"reviewDecision" => "APPROVED"}}
               }
             }
           }}

        request.method == :get and String.contains?(url, "/pulls?") ->
          base = Agent.get_and_update(pull_reads, fn count -> {if(count == 0, do: "main", else: "v2"), count + 1} end)

          {:ok,
           %{
             status: 200,
             body: [
               %{
                 "number" => 79,
                 "draft" => true,
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

          {:ok,
           %{
             status: 200,
             body: %{
               "base" => %{"ref" => "main"},
               "head" => %{"sha" => "head-79"}
             }
           }}
      end
    end

    assert {:ok,
            %{
              errors: [],
              results: [
                %{
                  decision: :failed,
                  draft?: true,
                  review_decision: "APPROVED",
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

  test "journals before repair and invalidates the confirmed response head after a concurrent push" do
    parent = self()

    request_fun = fn
      %{method: :post, url: "https://api.github.com/graphql"} ->
        {:ok,
         %{
           status: 200,
           body: %{
             "data" => %{
               "repository" => %{"pullRequest" => %{"reviewDecision" => "APPROVED"}}
             }
           }
         }}

      %{method: :get, url: url} when is_binary(url) ->
        assert String.contains?(url, "/pulls?")

        {:ok,
         %{
           status: 200,
           body: [
             %{
               "number" => 1144,
               "draft" => true,
               "head" => %{"sha" => "head-before-concurrent-push"},
               "base" => %{"ref" => "v2"}
             }
           ]
         }}

      %{method: :patch, url: url, body: body} ->
        send(parent, {:base_repaired, url, body})

        assert %{
                 base_repair_invalidations: %{
                   "1146" => %{
                     head_sha: "head-before-concurrent-push",
                     repair_state: :repairing
                   }
                 }
               } = CIApprovalStore.load()

        {:ok,
         %{
           status: 200,
           body: %{
             "number" => 1144,
             "draft" => true,
             "base" => %{"ref" => "main"},
             "head" => %{"sha" => "head-after-concurrent-push"}
           }
         }}
    end

    assert {:ok,
            %{
              errors: [],
              results: [
                %{
                  decision: :failed,
                  draft?: true,
                  review_decision: "APPROVED",
                  pr_number: 1144,
                  head_sha: "head-after-concurrent-push",
                  base_repair_invalidation: %{
                    head_sha: "head-after-concurrent-push",
                    repair_state: :repaired
                  },
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

    assert %{
             base_repair_invalidations: %{
               "1146" => %{
                 head_sha: "head-after-concurrent-push",
                 repair_state: :repaired
               }
             }
           } = CIApprovalStore.load()
  end

  test "keeps a repaired unchanged head invalid across later polls until fresh CI exists" do
    repair_time = DateTime.to_unix(~U[2026-07-14 23:00:00Z])
    {:ok, base} = Agent.start_link(fn -> "v2" end)
    {:ok, fresh_ci?} = Agent.start_link(fn -> false end)

    request_fun = fn request ->
      cond do
        request.method == :post and request.url == "https://api.github.com/graphql" ->
          {:ok,
           %{
             status: 200,
             body: %{
               "data" => %{
                 "repository" => %{"pullRequest" => %{"reviewDecision" => nil}}
               }
             }
           }}

        request.method == :get and String.contains?(request.url, "/pulls?") ->
          {:ok,
           %{
             status: 200,
             body: [
               %{
                 "number" => 1144,
                 "draft" => true,
                 "head" => %{"sha" => "unchanged-head"},
                 "base" => %{"ref" => Agent.get(base, & &1)}
               }
             ]
           }}

        request.method == :patch ->
          Agent.update(base, fn _ -> "main" end)

          {:ok,
           %{
             status: 200,
             body: %{
               "base" => %{"ref" => "main"},
               "head" => %{"sha" => "unchanged-head"}
             }
           }}

        String.contains?(request.url, "/check-runs?") ->
          started_at =
            if Agent.get(fresh_ci?, & &1),
              do: "2026-07-14T23:01:00Z",
              else: "2026-07-14T22:00:00Z"

          {:ok,
           %{
             status: 200,
             body: %{
               "check_runs" => [
                 %{
                   "name" => "test",
                   "status" => "completed",
                   "conclusion" => "success",
                   "started_at" => started_at
                 },
                 %{
                   "name" => "quarantined tests (non-blocking)",
                   "status" => "completed",
                   "conclusion" => "failure",
                   "started_at" => "2026-07-14T22:00:00Z"
                 }
               ]
             }
           }}

        String.ends_with?(request.url, "/status") ->
          {:ok, %{status: 200, body: %{"state" => "pending", "statuses" => []}}}
      end
    end

    assert {:ok,
            %{
              results: [
                %{
                  decision: :failed,
                  base_repair_invalidation: %{head_sha: "unchanged-head", repaired_at: ^repair_time}
                } = repaired
              ]
            }} =
             GithubCIPoller.poll(["1146"],
               request_fun: request_fun,
               base_branch: "main",
               system_time_fun: fn -> repair_time end
             )

    invalidations = %{"1146" => repaired.base_repair_invalidation}

    assert {:ok,
            %{
              results: [
                %{
                  decision: :pending,
                  head_sha: "unchanged-head",
                  pending_reason: :base_repair_ci_revalidation_required
                }
              ]
            }} =
             GithubCIPoller.poll(["1146"],
               request_fun: request_fun,
               base_branch: "main",
               base_repair_invalidations: invalidations
             )

    Agent.update(fresh_ci?, fn _ -> true end)

    assert {:ok,
            %{
              results: [
                %{
                  decision: :passed,
                  head_sha: "unchanged-head",
                  base_repair_revalidated: true
                }
              ]
            }} =
             GithubCIPoller.poll(["1146"],
               request_fun: request_fun,
               base_branch: "main",
               base_repair_invalidations: invalidations
             )
  end

  test "requires the earliest CI evidence to be strictly after the repair" do
    repair_time = DateTime.to_unix(~U[2026-07-14 23:00:00Z])

    invalidations = %{
      "1146" => %{
        head_sha: "repaired-head",
        repaired_at: repair_time,
        repair_state: :repaired
      }
    }

    {:ok, evidence} =
      Agent.start_link(fn ->
        %{
          "created_at" => "2026-07-14T22:59:59Z",
          "started_at" => "2026-07-14T23:00:01Z"
        }
      end)

    request_fun = fn %{method: :get, url: url} ->
      cond do
        String.contains?(url, "/pulls?") ->
          {:ok,
           %{
             status: 200,
             body: [
               %{
                 "number" => 1174,
                 "head" => %{"sha" => "repaired-head"},
                 "base" => %{"ref" => "main"}
               }
             ]
           }}

        String.contains?(url, "/check-runs?") ->
          check_run =
            Map.merge(
              %{"status" => "completed", "conclusion" => "success"},
              Agent.get(evidence, & &1)
            )

          {:ok, %{status: 200, body: %{"check_runs" => [check_run]}}}

        String.ends_with?(url, "/status") ->
          {:ok, %{status: 200, body: %{"state" => "pending", "statuses" => []}}}
      end
    end

    poll = fn ->
      GithubCIPoller.poll(["1146"],
        request_fun: request_fun,
        base_branch: "main",
        base_repair_invalidations: invalidations
      )
    end

    assert {:ok, %{results: [%{decision: :pending}]}} = poll.()

    Agent.update(evidence, fn _ ->
      %{
        "created_at" => "2026-07-14T23:00:00Z",
        "started_at" => "2026-07-14T23:00:00Z"
      }
    end)

    assert {:ok, %{results: [%{decision: :pending}]}} = poll.()

    Agent.update(evidence, fn _ ->
      %{
        "created_at" => "2026-07-14T23:00:01Z",
        "started_at" => "2026-07-14T23:00:01Z"
      }
    end)

    assert {:ok, %{results: [%{decision: :passed, base_repair_revalidated: true}]}} = poll.()
  end

  test "does not PATCH when the pre-repair journal cannot be written" do
    parent = self()

    request_fun = fn
      %{method: :get} ->
        {:ok,
         %{
           status: 200,
           body: [
             %{
               "number" => 1144,
               "head" => %{"sha" => "journal-failure-head"},
               "base" => %{"ref" => "v2"}
             }
           ]
         }}

      %{method: :patch} ->
        send(parent, :unexpected_patch)
        flunk("GitHub must not be mutated after a journal write failure")
    end

    journal_fun = fn target, marker ->
      CIApprovalStore.journal_base_repair(target, marker, write_fun: fn _path, _payload -> raise "disk full" end)
    end

    assert {:ok,
            %{
              results: [
                %{
                  decision: :failed,
                  failures: [%{result: "repair_failed", excerpt: excerpt}]
                }
              ]
            }} =
             GithubCIPoller.poll(["1146"],
               request_fun: request_fun,
               base_branch: "main",
               base_repair_journal_fun: journal_fun
             )

    refute_receive :unexpected_patch
    assert excerpt =~ "journal"
    assert CIApprovalStore.load().base_repair_invalidations == %{}
  end

  test "a crash after PATCH leaves a durable fail-closed repairing marker" do
    {:ok, journal_calls} = Agent.start_link(fn -> 0 end)

    journal_fun = fn target, marker ->
      case Agent.get_and_update(journal_calls, &{&1, &1 + 1}) do
        0 -> CIApprovalStore.journal_base_repair(target, marker)
        1 -> {:error, :simulated_crash_before_confirmed_head_persist}
      end
    end

    request_fun = fn
      %{method: :get, url: url} ->
        assert String.contains?(url, "/pulls?")

        {:ok,
         %{
           status: 200,
           body: [
             %{
               "number" => 1144,
               "head" => %{"sha" => "pre-patch-head"},
               "base" => %{"ref" => "v2"}
             }
           ]
         }}

      %{method: :patch} ->
        {:ok,
         %{
           status: 200,
           body: %{
             "base" => %{"ref" => "main"},
             "head" => %{"sha" => "concurrent-head"}
           }
         }}
    end

    assert {:ok,
            %{
              results: [
                %{
                  decision: :failed,
                  base_repair_invalidation: %{
                    head_sha: "pre-patch-head",
                    repair_state: :repairing
                  }
                }
              ]
            }} =
             GithubCIPoller.poll(["1146"],
               request_fun: request_fun,
               base_branch: "main",
               base_repair_journal_fun: journal_fun
             )

    assert %{
             base_repair_invalidations: %{
               "1146" => %{
                 head_sha: "pre-patch-head",
                 repair_state: :repairing
               }
             }
           } = CIApprovalStore.load()

    stale_ci_request_fun = fn %{method: :get, url: url} ->
      cond do
        String.contains?(url, "/pulls?") ->
          {:ok,
           %{
             status: 200,
             body: [
               %{
                 "number" => 1144,
                 "head" => %{"sha" => "concurrent-head"},
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
                 %{
                   "status" => "completed",
                   "conclusion" => "success",
                   "started_at" => "2026-07-15T00:00:00Z"
                 }
               ]
             }
           }}

        String.ends_with?(url, "/status") ->
          {:ok, %{status: 200, body: %{"state" => "success", "statuses" => []}}}
      end
    end

    assert {:ok,
            %{
              results: [
                %{
                  decision: :pending,
                  head_sha: "concurrent-head",
                  pending_reason: :base_repair_ci_revalidation_required
                }
              ]
            }} =
             GithubCIPoller.poll(["1146"],
               request_fun: stale_ci_request_fun,
               base_branch: "main",
               base_repair_invalidations: CIApprovalStore.load().base_repair_invalidations
             )

    assert %{
             base_repair_invalidations: %{
               "1146" => %{
                 head_sha: "concurrent-head",
                 repair_state: :repaired
               }
             }
           } = CIApprovalStore.load()
  end

  test "returns actionable CI failure when automatic wrong-base repair fails" do
    parent = self()

    request_fun = fn
      %{method: :post, url: "https://api.github.com/graphql"} ->
        {:ok,
         %{
           status: 200,
           body: %{
             "data" => %{
               "repository" => %{"pullRequest" => %{"reviewDecision" => "APPROVED"}}
             }
           }
         }}

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
                  draft?: true,
                  review_decision: "APPROVED",
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
