defmodule Aiur.LandingWatch.MergeGroupLastingFailureTest do
  use ExUnit.Case, async: true

  alias Aiur.LandingWatch.{Journal, MergeGroups}

  @forbidden {:github, :http, %{status: 403}}

  test "a completed run for a deleted group is ignored for queue health" do
    options = options(fn _, _ -> flunk("dead group failure log was read") end)
    request = options[:request_fun]

    opts =
      Keyword.put(options, :request_fun, fn call ->
        if String.contains?(call.url, "matching-refs") do
          {:ok, %{status: 200, body: []}}
        else
          request.(call)
        end
      end)

    assert :ok = MergeGroups.cancel_stale([], opts)
    refute_received {:log_read, _}
    refute_received {:rework, _}
  end

  test "a run that keeps failing does not hold back later runs in the same poll" do
    options = options(fn %{"id" => 5010}, _ -> {:error, @forbidden} end)

    assert {:error, {:job_log, 5010, @forbidden}} = MergeGroups.cancel_stale([], options)
    assert_received {:log_read, 5010}
    assert_received {:rework, 18}
  end

  test "a lasting non-transient error keeps the claim and raises an attention after five polls" do
    options = options(fn %{"id" => 5010}, _ -> {:error, @forbidden} end)

    for _poll <- 1..4 do
      assert {:error, {:job_log, 5010, @forbidden}} = MergeGroups.cancel_stale([], options)
      assert_received {:log_read, 5010}
      refute_received {:alert, _, _}
      # The landing poll prunes the journal between polls; the failure count must survive it.
      assert :ok = Journal.retain_current_heads([], options)
    end

    assert :ok = MergeGroups.cancel_stale([], options)
    assert_received {:log_read, 5010}
    assert_received {:alert, "system.pr.landing.merge_group_unclassified", alert}
    assert alert[:needs_attention]
    assert alert[:message] =~ "run 501"
    assert alert[:message] =~ "PR #17"
    assert alert[:message] =~ "status: 403"

    assert :ok = MergeGroups.cancel_stale([], options)
    refute_received {:log_read, 5010}
    refute_received {:alert, _, _}
    assert {:ok, state} = Journal.state(options)
    assert Map.get(state, "merge_group_run_failures", %{}) == %{}
  end

  for {label, reason} <- [
        {"a budget hold", {:aiur, :locally_held, %{reset_at: 0}}},
        {"a wrapped budget hold", {:github, :transport, %{reason: {:aiur, :locally_held, %{reset_at: 0}}}}},
        {"a GitHub rate limit", {:github, :rate_limited, %{status: 403}}}
      ] do
    test "#{label} past the limit is retried without counting or an attention" do
      reason = unquote(Macro.escape(reason))
      options = options(fn %{"id" => 5010}, _ -> {:error, reason} end)

      for _poll <- 1..7 do
        assert {:error, {:job_log, 5010, ^reason}} = MergeGroups.cancel_stale([], options)
        assert_received {:log_read, 5010}
        refute_received {:alert, _, _}
      end

      assert {:ok, state} = Journal.state(options)
      assert Map.get(state, "merge_group_run_failures", %{}) == %{}
    end
  end

  test "a run that recovers before the limit is classified and its failure count is cleared" do
    recovered = :atomics.new(1, [])

    options =
      options(fn %{"id" => 5010}, _ ->
        if :atomics.get(recovered, 1) == 0,
          do: {:error, @forbidden},
          else: {:ok, "mix test src/test/aiur/changed_test.exs:12 failed"}
      end)

    assert {:error, _} = MergeGroups.cancel_stale([], options)
    assert {:error, _} = MergeGroups.cancel_stale([], options)
    assert {:ok, %{"merge_group_run_failures" => %{"501" => 2}}} = Journal.state(options)

    :atomics.put(recovered, 1, 1)
    assert :ok = MergeGroups.cancel_stale([], options)
    assert_received {:rework, 17}
    refute_received {:alert, _, _}
    assert {:ok, state} = Journal.state(options)
    assert Map.get(state, "merge_group_run_failures", %{}) == %{}
  end

  defp options(failing_log) do
    parent = self()
    journal = Path.join(System.tmp_dir!(), "landing-watch-lasting-#{System.unique_integer([:positive])}.json")
    on_exit(fn -> File.rm(journal) end)

    request = fn
      %{url: "https://api.github.com/repos/test-org/test-repo/git/matching-refs/heads/gh-readonly-queue/" <> _} ->
        {:ok, %{status: 200, body: [%{"ref" => "refs/heads/gh-readonly-queue/main/pr-17-a"}, %{"ref" => "refs/heads/gh-readonly-queue/main/pr-18-b"}]}}

      %{method: :get, url: url} ->
        if String.contains?(url, "event=merge_group") and String.contains?(url, "status=completed"),
          do: {:ok, %{status: 200, body: %{"workflow_runs" => [group_run(501, "pr-17-a"), group_run(502, "pr-18-b")]}}},
          else: {:ok, %{status: 200, body: %{"workflow_runs" => []}}}
    end

    [
      base_branch: "main",
      token: "test-gh-token",
      request_fun: request,
      journal_path: journal,
      live_observations_fun: fn _, _ -> {:ok, [pr(17), pr(18)]} end,
      jobs_fun: fn run_id, _ -> {:ok, [%{"id" => run_id * 10, "name" => "test", "conclusion" => "failure"}]} end,
      job_log_fun: fn job, opts ->
        send(parent, {:log_read, job["id"]})
        if job["id"] == 5010, do: failing_log.(job, opts), else: {:ok, "mix test src/test/aiur/changed_test.exs:12 failed"}
      end,
      changed_paths_fun: fn _, _ -> {:ok, ["src/test/aiur/changed_test.exs"]} end,
      known_failure_patterns: [],
      repo_fun: fn -> {:ok, {"aiur-team", "aiur"}} end,
      alert_emitter: fn name, opts -> send(parent, {:alert, name, opts}) end,
      rework_fun: fn observation, _failures, _opts ->
        send(parent, {:rework, observation.number})
        :ok
      end
    ]
  end

  defp group_run(id, prs) do
    %{
      "id" => id,
      "event" => "merge_group",
      "status" => "completed",
      "conclusion" => "failure",
      "head_branch" => "gh-readonly-queue/main/#{prs}"
    }
  end

  defp pr(number) do
    %{
      number: number,
      base: "main",
      head: "current",
      node_id: "PR_#{number}",
      draft?: false,
      review_decision: "APPROVED",
      merge_queue_entry: nil,
      auto_merge_request: nil,
      rest: %{"head" => %{"ref" => "aiur/#{number}-work"}}
    }
  end
end
