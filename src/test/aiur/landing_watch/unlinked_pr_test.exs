defmodule Aiur.LandingWatch.UnlinkedPrTest do
  use ExUnit.Case, async: true

  alias Aiur.LandingWatch
  alias Aiur.TestSupport.Isolation

  test "unlinked approved PR is skipped while linked PRs route and the watcher stays running" do
    parent = self()
    linked = approved_observation()
    unlinked = put_in(approved_observation().rest["head"]["ref"], "executor/skill-meta-landing-sweep")

    assert :ok =
             LandingWatch.poll(
               observe_fun: fn _ -> {:ok, [unlinked, linked]} end,
               queue_reconcile_fun: fn _, _ -> :ok end,
               approved_fun: fn _, _ -> {:ok, true} end,
               required_checks_fun: fn _ -> {:ok, [%{name: "ci gate", app_id: nil}]} end,
               ci_status_fun: fn _, _ -> {:ok, %{check_runs: [failed_gate()], commit_status: %{"state" => "success", "statuses" => []}}} end,
               jobs_fun: fn _, _ ->
                 {:ok, [%{"name" => "ci gate", "conclusion" => "failure", "steps" => [%{"conclusion" => "failure"}], "started_at" => "2026-10-14T00:00:00Z", "completed_at" => "2026-10-14T00:00:10Z"}]}
               end,
               rerun_classifier_fun: fn _, _, _, _ -> {:ok, :rework} end,
               ticket_state_fun: fn "17", _ -> {:ok, "human-review"} end,
               transition_fun: fn issue, state, _ ->
                 send(parent, {:transition, issue, state})
                 :ok
               end,
               journal_path: journal_path()
             )

    assert_receive {:transition, "17", "rework"}, 1_000
    refute_received {:transition, _, _}

    server = {:global, {__MODULE__, make_ref()}}

    {[:aiur, :landing_watch, :poll, :stop], _measurements, %{result: :ok}} =
      Isolation.await_telemetry!([:aiur, :landing_watch, :poll, :stop], fn ->
        start_supervised!(
          {LandingWatch,
           [
             name: server,
             interval_ms: 60_000,
             subscribe: false,
             observe_fun: fn _ -> {:ok, [unlinked, linked]} end,
             journal_prune_fun: fn _, _ -> :ok end,
             process_fun: fn observation, _ ->
               send(parent, {:watcher_processed, observation.number})
               :ok
             end,
             queue_reconcile_fun: fn _, _ -> :ok end
           ]}
        )
      end)

    assert_received {:watcher_processed, 17}
    assert is_integer(LandingWatch.state(server).last_poll_at_ms)
    assert LandingWatch.state(server).watcher == :running
  end

  test "unlinked PRs still get infra reruns" do
    parent = self()
    unlinked = put_in(approved_observation().rest["head"]["ref"], "executor/skill-meta-landing-sweep")
    cancelled_jobs = [%{"name" => "ci gate", "conclusion" => "failure", "steps" => [%{"conclusion" => "cancelled"}]}]

    assert :ok =
             LandingWatch.process(
               unlinked,
               approved_fun: fn _, _ -> {:ok, true} end,
               required_checks_fun: fn _ -> {:ok, [%{name: "ci gate", app_id: nil}]} end,
               ci_status_fun: fn _, _ -> {:ok, %{check_runs: [failed_gate()], commit_status: %{"state" => "success", "statuses" => []}}} end,
               jobs_fun: fn _, _ -> {:ok, cancelled_jobs} end,
               rerun_fun: fn 99, _ ->
                 send(parent, :rerun)
                 {:ok, %{}}
               end,
               comment_fun: fn _, _, _ -> {:ok, %{}} end,
               journal_path: journal_path()
             )

    assert_receive :rerun, 1_000
  end

  test "unlinked rework is logged once per PR head" do
    observation = put_in(approved_observation().rest["head"]["ref"], "executor/skill-meta-landing-sweep")
    opts = [journal_path: journal_path()]

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert :ok = LandingWatch.rework(observation, [%{name: "CI failure"}], opts)
        assert :ok = LandingWatch.rework(observation, [%{name: "CI failure"}], opts)
      end)

    assert length(Regex.scan(~r/landing watcher skipped rework routing for unlinked PR #17 head head-sha/, log)) == 1
  end

  defp approved_observation do
    %{
      number: 17,
      node_id: "PR_node",
      head: "head-sha",
      draft?: false,
      review_decision: "APPROVED",
      merge_queue_entry: nil,
      auto_merge_request: nil,
      rest: %{"head" => %{"ref" => "aiur/17-work"}},
      raw: %{"reviewDecision" => "APPROVED", "headRefOid" => "head-sha", "isDraft" => false, "reviews" => %{"nodes" => [%{"commit" => %{"oid" => "head-sha"}}]}}
    }
  end

  defp failed_gate do
    %{"id" => 50, "run_id" => 99, "name" => "ci gate", "status" => "completed", "conclusion" => "failure", "check_suite" => %{"id" => 100}}
  end

  defp journal_path do
    path = Path.join(System.tmp_dir!(), "landing-watch-unlinked-#{System.unique_integer([:positive])}.json")
    ExUnit.Callbacks.on_exit(fn -> File.rm(path) end)
    path
  end
end
