defmodule Aiur.LandingWatch.PrRefreshSafetyTest do
  use ExUnit.Case, async: true

  alias Aiur.LandingWatch.PrRefreshSafety
  alias Aiur.LandingWatch.PrRerun

  @started "2026-10-14T10:00:00Z"
  @started_ms 1_791_972_000_000

  test "a base fix refreshes an unapproved open PR with a current head and disjoint changes" do
    observation = observation("REVIEW_REQUIRED")

    assert :ok =
             PrRefreshSafety.apply(observation,
               refresh_observation_fun: fn _, _ -> {:ok, live_pr("REVIEW_REQUIRED")} end,
               base_branch: "main",
               base_changes_fun: fn _, _, _ -> {:ok, ["README.md"]} end,
               changed_paths_fun: fn _, _ -> {:ok, ["src/lib/feature.ex"]} end
             )

    assert :ok = PrRefreshSafety.verify_updated_head(observation, observe_refresh_fun: fn _, _ -> {:ok, %{"headRefOid" => "refreshed-sha"}} end)
    refute_received {:approval_carry_checked, _}
  end

  test "a refresh refuses when the live PR observation is unavailable" do
    observation = observation("REVIEW_REQUIRED")

    assert {:error, {:pr_observation_unavailable, {:error, :unavailable}}} =
             PrRefreshSafety.apply(observation, refresh_observation_fun: fn _, _ -> {:error, :unavailable} end)
  end

  test "a refresh refuses when the base changed files in the PR" do
    observation = observation("REVIEW_REQUIRED")

    opts = [
      refresh_observation_fun: fn _, _ -> {:ok, live_pr("REVIEW_REQUIRED")} end,
      base_branch: "main",
      base_changes_fun: fn _, _, _ -> {:ok, ["src/lib/feature.ex"]} end,
      changed_paths_fun: fn _, _ -> {:ok, ["src/lib/feature.ex"]} end
    ]

    assert {:error, :base_changed_pr_files} = PrRefreshSafety.apply(observation, opts)
  end

  test "an approved refresh still requires the approval to carry to the refreshed head" do
    observation = observation("APPROVED")

    assert :ok =
             PrRefreshSafety.apply(observation,
               refresh_observation_fun: fn _, _ -> {:ok, live_pr("APPROVED")} end,
               base_branch: "main",
               base_changes_fun: fn _, _, _ -> {:ok, ["README.md"]} end,
               changed_paths_fun: fn _, _ -> {:ok, []} end
             )

    assert {:error, {:approval_not_carried, ["src/lib/feature.ex"]}} =
             PrRefreshSafety.verify_updated_head(observation,
               observe_refresh_fun: fn _, _ -> {:ok, %{"headRefOid" => "refreshed-sha"}} end,
               approval_carry_classifier: fn _, _, _, _ -> {:changed, ["src/lib/feature.ex"]} end
             )
  end

  test "transient CI recovery reruns the failed check without refreshing the PR" do
    parent = self()
    observation = observation("REVIEW_REQUIRED")
    run = %{"run_id" => 99, "status" => "completed", "conclusion" => "failure", "started_at" => @started, "name" => "ci gate"}

    assert :ok =
             PrRerun.recover_main_ci(observation, [run], {@started_ms - 60_000, @started_ms + 60_000},
               main_history_fun: fn -> [] end,
               rerun_classifier_fun: fn _, _, _, _ -> {:ok, {:rerun, "main CI recovered"}} end,
               rerun_fun: fn 99, _ -> send(parent, {:rerun, 99}) && {:ok, %{}} end,
               comment_fun: fn _, _, _ -> {:ok, %{}} end,
               journal_path: journal_path(),
               now_ms: @started_ms + 90_000
             )

    assert_received {:rerun, 99}
    refute_received {:update_branch, _, _}
  end

  defp observation(decision) do
    %{number: 17, head: "head-sha", draft?: false, review_decision: decision, reviews: if(decision == "APPROVED", do: [%{"commit" => %{"oid" => "head-sha"}}], else: [])}
  end

  defp live_pr(decision) do
    %{"state" => "OPEN", "headRefOid" => "head-sha", "isDraft" => false, "reviewDecision" => decision, "mergeQueueEntry" => nil}
  end

  defp journal_path do
    path = Path.join(System.tmp_dir!(), "landing-pr-refresh-safety-#{System.unique_integer([:positive])}.json")
    ExUnit.Callbacks.on_exit(fn -> Aiur.TestCleanup.rm_rf!(path) end)
    path
  end
end
