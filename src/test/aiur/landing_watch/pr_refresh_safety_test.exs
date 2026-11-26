defmodule Aiur.LandingWatch.PrRefreshSafetyTest do
  use ExUnit.Case, async: true

  alias Aiur.LandingWatch.PrRefreshSafety
  alias Aiur.LandingWatch.PrRerun

  @started "2026-10-14T10:00:00Z"
  @started_ms 1_791_972_000_000

  test "a base fix refreshes an unapproved open PR with a current head and disjoint changes" do
    observation = observation("REVIEW_REQUIRED")
    parent = self()

    assert :ok =
             PrRerun.recover_main_ci(
               observation,
               [%{"run_id" => 170, "status" => "completed", "conclusion" => "failure", "started_at" => @started, "name" => "ci gate"}],
               {@started_ms - 60_000, @started_ms + 60_000},
               stale_merge_ref_fun: fn _, _ -> true end,
               main_history_fun: fn ->
                 [
                   %{completed_at: @started_ms - 10_000, checks: [%{name: "ci gate", conclusion: "failure"}]},
                   %{completed_at: @started_ms + 30_000, checks: [%{name: "ci gate", conclusion: "success"}]}
                 ]
               end,
               refresh_observation_fun: fn _, _ -> {:ok, live_pr("REVIEW_REQUIRED")} end,
               base_branch: "main",
               base_changes_fun: fn _, _, _ -> {:ok, ["README.md"]} end,
               changed_paths_fun: fn _, _ -> {:ok, ["src/lib/feature.ex"]} end,
               update_branch_fun: fn _, _, _ -> send(parent, :updated) && {:ok, %{}} end,
               observe_refresh_fun: fn _, _ -> {:ok, %{"headRefOid" => "refreshed-head"}} end,
               comment_fun: fn _, _, _ -> {:ok, %{}} end,
               journal_path: journal_path(),
               now_ms: @started_ms + 90_000
             )

    assert_received :updated
    refute_received {:approval_carry_checked, _}
  end

  test "LandingWatch refreshes an unapproved PR only in the main-fix recovery window" do
    parent = self()

    observation = %{
      number: 71,
      head: "unapproved-head",
      draft?: false,
      review_decision: "REVIEW_REQUIRED",
      reviews: [],
      raw: %{"reviewDecision" => "REVIEW_REQUIRED", "headRefOid" => "unapproved-head", "isDraft" => false},
      mergeable: "MERGEABLE",
      merge_state_status: "UNSTABLE",
      merge_queue_entry: nil,
      auto_merge_request: nil,
      rest: %{"head" => %{"ref" => "team/71-work"}}
    }

    recovery_window = {@started_ms - 60_000, @started_ms + 60_000}
    run = %{"run_id" => 171, "status" => "completed", "conclusion" => "failure", "started_at" => @started, "name" => "ci gate"}

    assert :ok =
             Aiur.LandingWatch.process(observation,
               main_ci_recovery_window: recovery_window,
               retry_arm_fun: fn _, _ -> :ok end,
               recovery_runs_fun: fn _, _ -> {:ok, [run]} end,
               stale_merge_ref_fun: fn _, _ -> true end,
               refresh_observation_fun: fn 71, _ ->
                 {:ok, %{"state" => "OPEN", "headRefOid" => "unapproved-head", "isDraft" => false, "reviewDecision" => "REVIEW_REQUIRED", "mergeQueueEntry" => nil}}
               end,
               base_branch: "main",
               base_changes_fun: fn _, _, _ -> {:ok, ["README.md"]} end,
               changed_paths_fun: fn _, _ -> {:ok, ["src/lib/feature.ex"]} end,
               update_branch_fun: fn 71, "unapproved-head", _ -> send(parent, :updated) && {:ok, %{}} end,
               observe_refresh_fun: fn _, _ -> {:ok, %{"headRefOid" => "refreshed-head"}} end,
               comment_fun: fn _, _, _ -> {:ok, %{}} end,
               journal_path: journal_path(),
               now_ms: @started_ms + 90_000
             )

    assert_received :updated

    assert :ok = Aiur.LandingWatch.process(observation, retry_arm_fun: fn _, _ -> :ok end, recovery_runs_fun: fn _, _ -> flunk("ordinary polls must not read unapproved PR CI") end)
    refute_received :updated
  end

  test "LandingWatch skips draft unapproved PRs before reading CI" do
    observation =
      "REVIEW_REQUIRED"
      |> observation()
      |> Map.put(:draft?, true)
      |> Map.put(:raw, %{"reviewDecision" => "REVIEW_REQUIRED", "isDraft" => true})

    assert :ok =
             Aiur.LandingWatch.process(observation,
               main_ci_recovery_window: {@started_ms - 60_000, @started_ms + 60_000},
               retry_arm_fun: fn _, _ -> :ok end,
               recovery_runs_fun: fn _, _ -> flunk("draft PRs must not trigger recovery reads") end
             )
  end

  test "LandingWatch skips changes-requested unapproved PRs before reading CI" do
    observation =
      "CHANGES_REQUESTED"
      |> observation()
      |> Map.put(:raw, %{"reviewDecision" => "CHANGES_REQUESTED", "isDraft" => false})

    assert :ok =
             Aiur.LandingWatch.process(observation,
               main_ci_recovery_window: {@started_ms - 60_000, @started_ms + 60_000},
               retry_arm_fun: fn _, _ -> :ok end,
               recovery_runs_fun: fn _, _ -> flunk("changes-requested PRs must not trigger recovery reads") end
             )
  end

  test "main-fix recovery skips a conflicting unapproved PR" do
    parent = self()

    observation = %{
      number: 72,
      head: "conflicting-head",
      draft?: false,
      review_decision: "REVIEW_REQUIRED",
      reviews: [],
      raw: %{"reviewDecision" => "REVIEW_REQUIRED", "headRefOid" => "conflicting-head", "isDraft" => false},
      mergeable: "CONFLICTING",
      merge_state_status: "DIRTY",
      merge_queue_entry: nil,
      auto_merge_request: nil
    }

    assert :ok =
             Aiur.LandingWatch.process(observation,
               main_ci_recovery_window: {@started_ms - 60_000, @started_ms + 60_000},
               retry_arm_fun: fn _, _ -> :ok end,
               recovery_runs_fun: fn _, _ -> send(parent, :read) && {:ok, []} end,
               update_branch_fun: fn _, _, _ -> send(parent, :updated) && {:ok, %{}} end
             )

    refute_received :read
    refute_received :updated
  end

  test "a base overlap during main-fix recovery routes the unapproved PR to rework" do
    parent = self()
    observation = observation("REVIEW_REQUIRED")
    runs = [%{"run_id" => 77, "status" => "completed", "conclusion" => "failure", "started_at" => @started, "name" => "ci gate"}]

    assert :ok =
             PrRerun.recover_main_ci(observation, runs, {@started_ms - 60_000, @started_ms + 60_000},
               main_history_fun: fn ->
                 [
                   %{completed_at: @started_ms - 10_000, checks: [%{name: "ci gate", conclusion: "failure"}]},
                   %{completed_at: @started_ms + 30_000, checks: [%{name: "ci gate", conclusion: "success"}]}
                 ]
               end,
               stale_merge_ref_fun: fn _, _ -> true end,
               journal_path: journal_path(),
               now_ms: @started_ms + 90_000,
               refresh_observation_fun: fn _, _ -> {:ok, live_pr("REVIEW_REQUIRED")} end,
               base_branch: "main",
               base_changes_fun: fn _, _, _ -> {:ok, ["src/lib/feature.ex"]} end,
               changed_paths_fun: fn _, _ -> {:ok, ["src/lib/feature.ex"]} end,
               rework_fun: fn _, failures, _ -> send(parent, {:rework, failures}) && :ok end
             )

    assert_received {:rework, [%{excerpt: excerpt}]}
    assert excerpt =~ "src/lib/feature.ex"
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

    assert {:error, {:base_changed_pr_files, ["src/lib/feature.ex"]}} = PrRefreshSafety.apply(observation, opts)
  end

  test "a GitHub compare response that overlaps the PR files refuses refresh" do
    observation = observation("REVIEW_REQUIRED")

    assert {:error, {:base_changed_pr_files, ["src/lib/feature.ex"]}} =
             PrRefreshSafety.apply(observation,
               refresh_observation_fun: fn _, _ -> {:ok, live_pr("REVIEW_REQUIRED")} end,
               base_branch: "main",
               base_changes_fun: fn _, _, _ -> {:ok, %{"files" => [%{"filename" => "src/lib/feature.ex"}]}} end,
               changed_paths_fun: fn _, _ -> {:ok, ["src/lib/feature.ex"]} end
             )
  end

  test "a recovery overlap check is reused by refresh verification" do
    observation = observation("REVIEW_REQUIRED")
    parent = self()

    assert :ok =
             PrRerun.recover_main_ci(
               observation,
               [%{"run_id" => 172, "status" => "completed", "conclusion" => "failure", "started_at" => @started, "name" => "ci gate"}],
               {@started_ms - 60_000, @started_ms + 60_000},
               stale_merge_ref_fun: fn _, _ -> true end,
               main_history_fun: fn ->
                 [
                   %{completed_at: @started_ms - 10_000, checks: [%{name: "ci gate", conclusion: "failure"}]},
                   %{completed_at: @started_ms + 30_000, checks: [%{name: "ci gate", conclusion: "success"}]}
                 ]
               end,
               refresh_observation_fun: fn _, _ -> {:ok, live_pr("REVIEW_REQUIRED")} end,
               base_branch: "main",
               base_changes_fun: fn _, _, _ -> send(parent, :compare) && {:ok, ["README.md"]} end,
               changed_paths_fun: fn _, _ -> send(parent, :paths) && {:ok, []} end,
               update_branch_fun: fn _, _, _ -> {:ok, %{}} end,
               observe_refresh_fun: fn _, _ -> {:ok, %{"headRefOid" => "refreshed-head"}} end,
               comment_fun: fn _, _, _ -> {:ok, %{}} end,
               journal_path: journal_path(),
               now_ms: @started_ms + 90_000
             )

    assert_received :compare
    assert_received :paths
    refute_received :compare
    refute_received :paths
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
    update_parent = self()
    observation = observation("REVIEW_REQUIRED")
    run = %{"run_id" => 99, "status" => "completed", "conclusion" => "failure", "started_at" => @started, "name" => "ci gate"}

    assert :ok =
             PrRerun.recover_main_ci(observation, [run], {@started_ms - 60_000, @started_ms + 60_000},
               main_history_fun: fn -> [] end,
               rerun_classifier_fun: fn _, _, _, _ -> {:ok, {:rerun, "main CI recovered"}} end,
               rerun_fun: fn 99, _ -> send(parent, {:rerun, 99}) && {:ok, %{}} end,
               update_branch_fun: fn _, _, _ -> send(update_parent, :updated) && {:ok, %{}} end,
               comment_fun: fn _, _, _ -> {:ok, %{}} end,
               journal_path: journal_path(),
               now_ms: @started_ms + 90_000
             )

    assert_received {:rerun, 99}
    refute_received :updated
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
