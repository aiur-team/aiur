defmodule Aiur.Events.GithubCIPollerBaseRepairJournalTest do
  use Aiur.TestSupport
  import Aiur.TestSupport.CIPollerFixture

  alias Aiur.CIApprovalStore

  setup :ci_poller_env

  test "journals before repair and invalidates the confirmed response head after a concurrent push" do
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
               "head" => pr_head("aiur/1146", "head-before-concurrent-push"),
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
            }} = poll(["1146"], request_fun: request_fun, base_branch: "main")

    assert_receive {:base_repaired, url, %{"base" => "main"}}, 1000
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
               "head" => pr_head("aiur/1146", "journal-failure-head"),
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
             poll(["1146"],
               request_fun: request_fun,
               base_branch: "main",
               base_repair_journal_fun: journal_fun
             )

    refute_receive :unexpected_patch, 100
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
               "head" => pr_head("aiur/1146", "pre-patch-head"),
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
             poll(["1146"],
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
                 "head" => pr_head("aiur/1146", "concurrent-head"),
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
             poll(["1146"],
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
      %{method: :get, url: url} ->
        assert String.contains?(url, "/pulls?")

        {:ok,
         %{
           status: 200,
           body: [
             %{
               "number" => 1145,
               "draft" => true,
               "head" => pr_head("aiur/1146", "head-1145"),
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
            }} = poll(["1146"], request_fun: request_fun, base_branch: "main")

    assert_receive :base_repair_attempted, 1000
    assert excerpt =~ ~s(targets "v2")
    assert excerpt =~ ~s(tracker.base_branch is "main")
    assert excerpt =~ "baseRefName"
  end
end
