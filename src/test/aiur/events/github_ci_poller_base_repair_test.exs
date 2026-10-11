defmodule Aiur.Events.GithubCIPollerBaseRepairTest do
  use Aiur.TestSupport
  import Aiur.TestSupport.CIPollerFixture

  setup :ci_poller_env

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
                 "head" => pr_head("aiur/79", "head-79"),
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
                  failures: [%{name: "pull request base branch", result: "repaired"}]
                }
              ]
            }} = poll(["79"], request_fun: request_fun, base_branch: "main")

    assert_receive {:base_repaired_during_observation, %{"base" => "main"}}, 1000
  end

  test "keeps a repaired unchanged head invalid across later polls until fresh CI exists" do
    repair_time = DateTime.to_unix(~U[2026-07-14 23:00:00Z])
    {:ok, base} = Agent.start_link(fn -> "v2" end)
    {:ok, fresh_ci?} = Agent.start_link(fn -> false end)

    request_fun = fn request ->
      cond do
        request.method == :get and String.contains?(request.url, "/pulls?") ->
          {:ok,
           %{
             status: 200,
             body: [
               %{
                 "number" => 1144,
                 "draft" => not Agent.get(fresh_ci?, & &1),
                 "head" => pr_head("aiur/1146", "unchanged-head"),
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
             poll(["1146"],
               request_fun: request_fun,
               base_branch: "main",
               system_time_fun: fn -> repair_time end
             )

    invalidations = %{"1146" => repaired.base_repair_invalidation}

    assert {:ok,
            %{
              results: [
                # `draft?` is pinned here on purpose. It is read off the listing
                # entry (`pr_draft?/1`), never off the PATCH response, so a
                # fixture losing the draft flag would otherwise flip this to
                # false with every assertion still green.
                %{
                  decision: :pending,
                  head_sha: "unchanged-head",
                  pending_reason: :base_repair_ci_revalidation_required,
                  draft?: true
                }
              ]
            }} =
             poll(["1146"],
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
                  base_repair_revalidated: true,
                  draft?: false
                }
              ]
            }} =
             poll(["1146"],
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
                 "head" => pr_head("aiur/1146", "repaired-head"),
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
      poll(["1146"],
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
end
