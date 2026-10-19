defmodule Aiur.LandingWatch.RuntimeTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog

  alias Aiur.LandingWatch
  alias Aiur.LandingWatch.Journal

  test "poll visits every observation and fails on a malformed census" do
    parent = self()

    assert :ok =
             LandingWatch.poll(
               observe_fun: fn _ -> {:ok, [%{number: 1}, %{number: 2}]} end,
               queue_reconcile_fun: fn _, _ -> :ok end,
               process_fun: fn observation, _ ->
                 send(parent, {:seen, observation.number})
                 :ok
               end
             )

    assert_received {:seen, 1}
    assert_received {:seen, 2}
    assert {:error, :invalid_observations} = LandingWatch.poll(observe_fun: fn _ -> :bad end)
  end

  test "poll waits through an expired shared-budget hold and retries the observation" do
    parent = self()
    reset_at = DateTime.add(DateTime.utc_now(), -1, :second)
    hold = %{reason: :shared_budget, resource: "core", reset_at: reset_at}
    failure = {:error, {:github, :local_hold, %{reason: {:aiur, :locally_held, hold}, hold: hold}}}

    log =
      capture_log(fn ->
        assert :ok =
                 LandingWatch.poll(
                   observe_fun: fn _ ->
                     attempt = Process.get(:landing_watch_poll_attempt, 0)
                     Process.put(:landing_watch_poll_attempt, attempt + 1)
                     send(parent, {:poll_attempt, attempt})
                     if attempt == 0, do: failure, else: {:ok, []}
                   end,
                   queue_reconcile_fun: fn _, _ -> :ok end,
                   local_hold_sleep_fun: fn _ms -> flunk("an expired hold must retry without sleeping") end
                 )
      end)

    refute log =~ "landing watcher poll unavailable"
    assert_received {:poll_attempt, 0}
    assert_received {:poll_attempt, 1}
    refute_received {:poll_attempt, _}
  end

  test "approved human-review PR reruns gate failure caused by cancelled upstream jobs" do
    path = journal_path()
    parent = self()
    observation = approved_observation()

    assert :ok =
             LandingWatch.process(
               observation,
               approved_fun: fn _, _ -> {:ok, true} end,
               required_checks_fun: fn _ -> {:ok, [%{name: "ci gate", app_id: nil}]} end,
               ci_status_fun: fn _, _ -> {:ok, %{check_runs: [failed_gate()], commit_status: %{"state" => "success", "statuses" => []}}} end,
               jobs_fun: fn 99, _ ->
                 {:ok,
                  [
                    %{"name" => "test", "conclusion" => "cancelled", "steps" => [], "started_at" => "2026-10-14T19:04:38Z", "completed_at" => "2026-10-14T19:04:38Z"},
                    %{
                      "name" => "ci gate",
                      "conclusion" => "failure",
                      "steps" => [%{"name" => "Setup", "conclusion" => "success"}, %{"name" => "Require the event's selected jobs", "conclusion" => "failure"}],
                      "started_at" => "2026-10-14T19:34:47Z",
                      "completed_at" => "2026-10-14T19:34:54Z"
                    }
                  ]}
               end,
               rerun_fun: fn 99, _ ->
                 send(parent, :rerun)
                 {:ok, %{}}
               end,
               comment_fun: fn number, body, _ ->
                 send(parent, {:comment, number, body})
                 {:ok, %{}}
               end,
               journal_path: path,
               now_ms: 1_000_000
             )

    assert_received :rerun
    assert_received {:comment, 17, "Landing watcher reran the failed CI (ci gate) on approved head `head-sha`: infrastructure failure."}
    assert %{"17:head-sha" => %{"rerun_count" => 1, "last_rerun_at" => 1_000_000}} = Jason.decode!(File.read!(path))

    assert :ok =
             LandingWatch.process(
               observation,
               approved_fun: fn _, _ -> {:ok, true} end,
               required_checks_fun: fn _ -> {:ok, [%{name: "ci gate", app_id: nil}]} end,
               ci_status_fun: fn _, _ -> {:ok, %{check_runs: [failed_gate()], commit_status: %{"state" => "success", "statuses" => []}}} end,
               jobs_fun: fn 99, _ -> {:ok, [%{"name" => "ci gate", "conclusion" => "failure", "steps" => [%{"conclusion" => "cancelled"}]}]} end,
               rerun_fun: fn _, _ -> flunk("bounded backoff must suppress an immediate duplicate") end,
               journal_path: path,
               now_ms: 1_000_000
             )
  end

  test "infra reruns reserve the per-head budget once for all failed runs in a poll" do
    path = journal_path()
    parent = self()
    observation = approved_observation()
    second_run = failed_gate() |> Map.put("id", 51) |> Map.put("run_id", 100)

    assert :ok =
             LandingWatch.process(
               observation,
               approved_fun: fn _, _ -> {:ok, true} end,
               required_checks_fun: fn _ -> {:ok, [%{name: "ci gate", app_id: nil}]} end,
               ci_status_fun: fn _, _ ->
                 {:ok, %{check_runs: [failed_gate(), second_run], commit_status: %{"state" => "success", "statuses" => []}}}
               end,
               jobs_fun: fn run_id, _ ->
                 assert run_id in [99, 100]
                 {:ok, [%{"name" => "ci gate", "conclusion" => "failure", "steps" => [%{"conclusion" => "cancelled"}]}]}
               end,
               rerun_fun: fn run_id, _ ->
                 send(parent, {:rerun, run_id})
                 {:ok, %{}}
               end,
               comment_fun: fn _, _, _ -> {:ok, %{}} end,
               journal_path: path,
               now_ms: 1_000_000
             )

    assert_received {:rerun, 99}
    assert_received {:rerun, 100}
    refute_received {:rerun, _}
    assert %{"17:head-sha" => %{"rerun_count" => 1, "last_rerun_at" => 1_000_000}} = Jason.decode!(File.read!(path))
  end

  test "real required job failure routes linked ticket to rework" do
    parent = self()

    assert :ok =
             LandingWatch.process(
               approved_observation(),
               approved_fun: fn _, _ -> {:ok, true} end,
               required_checks_fun: fn _ -> {:ok, [%{name: "ci gate", app_id: nil}]} end,
               ci_status_fun: fn _, _ -> {:ok, %{check_runs: [failed_gate()], commit_status: %{"state" => "success", "statuses" => []}}} end,
               jobs_fun: fn 99, _ ->
                 {:ok, [%{"name" => "ci gate", "conclusion" => "failure", "steps" => [%{"conclusion" => "failure"}], "started_at" => "2026-10-14T00:00:00Z", "completed_at" => "2026-10-14T00:00:10Z"}]}
               end,
               rerun_classifier_fun: fn _, _, _, _ -> {:ok, :rework} end,
               journal_path: journal_path(),
               rework_fun: fn observation, failures, _ ->
                 send(parent, {:rework, observation.number, failures})
                 :ok
               end
             )

    assert_received {:rework, 17, [%{name: "ci gate"}]}
  end

  test "a queued ticket can return to rework when its PR conflicts with main" do
    parent = self()
    observation = approved_observation() |> Map.put(:mergeable, "CONFLICTING")

    assert :ok =
             LandingWatch.process(
               observation,
               approved_fun: fn _, _ -> {:ok, true} end,
               required_checks_fun: fn _ -> {:ok, [%{name: "ci gate", app_id: nil}]} end,
               ci_status_fun: fn _, _ -> {:ok, %{check_runs: [%{"name" => "ci gate", "status" => "in_progress"}], commit_status: %{"state" => "pending", "statuses" => []}}} end,
               rework_fun: fn _, failures, _ ->
                 send(parent, {:conflict_rework, failures})
                 :ok
               end
             )

    assert_received {:conflict_rework, [%{name: "Merge conflict with base"}]}
  end

  test "default real-failure path transitions the linked ticket with its observed state" do
    parent = self()

    assert :ok =
             LandingWatch.process(
               approved_observation(),
               approved_fun: fn _, _ -> {:ok, true} end,
               required_checks_fun: fn _ -> {:ok, [%{name: "ci gate", app_id: nil}]} end,
               ci_status_fun: fn _, _ -> {:ok, %{check_runs: [failed_gate()], commit_status: %{"state" => "success", "statuses" => []}}} end,
               jobs_fun: fn 99, _ ->
                 {:ok, [%{"name" => "ci gate", "conclusion" => "failure", "steps" => [%{"conclusion" => "failure"}], "started_at" => "2026-10-14T00:00:00Z", "completed_at" => "2026-10-14T00:00:10Z"}]}
               end,
               rerun_classifier_fun: fn _, _, _, _ -> {:ok, :rework} end,
               journal_path: journal_path(),
               ticket_state_fun: fn "17", _ -> {:ok, "human-review"} end,
               transition_fun: fn id, target, options ->
                 send(parent, {:transition, id, target, options})
                 :ok
               end,
               alert_emitter: fn topic, opts ->
                 send(parent, {:rework_alert, topic, opts})
                 :ok
               end
             )

    assert_received {:transition, "17", "rework", [writer: :landing_watch, expected_state: "human-review"]}
    assert_received {:rework_alert, "system.pr.landing.rework", _}
  end

  test "direct person cancellation raises rerun skipped and stays pending" do
    parent = self()
    observation = approved_observation()
    cancelled = Map.put(failed_gate(), "conclusion", "cancelled")

    assert :ok =
             LandingWatch.process(
               observation,
               approved_fun: fn _, _ -> {:ok, true} end,
               required_checks_fun: fn _ -> {:ok, [%{name: "ci gate", app_id: nil}]} end,
               ci_status_fun: fn _, _ -> {:ok, %{check_runs: [cancelled], commit_status: %{"state" => "success", "statuses" => []}}} end,
               alert_emitter: fn topic, details ->
                 send(parent, {:alert, topic, details})
                 :ok
               end,
               rerun_fun: fn _, _ -> flunk("person-cancelled runs must not be rerun") end
             )

    assert_received {:alert, "ticket.17.pr.ci_recovery.rerun_skipped", details}
    assert Keyword.fetch!(details, :reason) == "cancelled_run"
    assert Keyword.fetch!(details, :durable)
  end

  test "cancelled head CI for a queued PR does not raise a person-cancelled alert" do
    parent = self()
    observation = %{approved_observation() | merge_queue_entry: %{"id" => "MQE_1"}}
    cancelled = Map.put(failed_gate(), "conclusion", "cancelled")

    assert :ok =
             LandingWatch.process(observation,
               approved_fun: fn _, _ -> {:ok, true} end,
               required_checks_fun: fn _ -> {:ok, [%{name: "ci gate", app_id: nil}]} end,
               ci_status_fun: fn _, _ -> {:ok, %{check_runs: [cancelled], commit_status: %{"state" => "success", "statuses" => []}}} end,
               alert_emitter: fn topic, details ->
                 send(parent, {:alert, topic, details})
                 :ok
               end,
               journal_path: journal_path()
             )

    refute_received {:alert, "ticket.17.pr.ci_recovery.rerun_skipped", _}
  end

  test "person-cancelled alert is emitted once per PR head and run across polls" do
    parent = self()
    observation = approved_observation()
    cancelled = Map.put(failed_gate(), "conclusion", "cancelled")

    opts = [
      approved_fun: fn _, _ -> {:ok, true} end,
      required_checks_fun: fn _ -> {:ok, [%{name: "ci gate", app_id: nil}]} end,
      ci_status_fun: fn _, _ -> {:ok, %{check_runs: [cancelled], commit_status: %{"state" => "success", "statuses" => []}}} end,
      alert_emitter: fn topic, details ->
        send(parent, {:alert, topic, details})
        :ok
      end,
      journal_path: journal_path()
    ]

    assert :ok = LandingWatch.process(observation, opts)
    assert :ok = LandingWatch.process(observation, opts)
    assert_received {:alert, "ticket.17.pr.ci_recovery.rerun_skipped", _}
    refute_received {:alert, "ticket.17.pr.ci_recovery.rerun_skipped", _}
  end

  test "failed durable alert publication releases its journal claim for retry" do
    parent = self()
    path = journal_path()
    observation = approved_observation()
    cancelled = Map.put(failed_gate(), "conclusion", "cancelled")

    assert {:error, :unavailable} =
             LandingWatch.process(
               observation,
               approved_fun: fn _, _ -> {:ok, true} end,
               required_checks_fun: fn _ -> {:ok, [%{name: "ci gate", app_id: nil}]} end,
               ci_status_fun: fn _, _ -> {:ok, %{check_runs: [cancelled], commit_status: %{"state" => "success", "statuses" => []}}} end,
               alert_emitter: fn _, _ -> {:error, :unavailable} end,
               journal_path: path
             )

    assert :ok =
             LandingWatch.process(
               observation,
               approved_fun: fn _, _ -> {:ok, true} end,
               required_checks_fun: fn _ -> {:ok, [%{name: "ci gate", app_id: nil}]} end,
               ci_status_fun: fn _, _ -> {:ok, %{check_runs: [cancelled], commit_status: %{"state" => "success", "statuses" => []}}} end,
               alert_emitter: fn topic, _ ->
                 send(parent, {:retried, topic})
                 :ok
               end,
               journal_path: path
             )

    assert_received {:retried, "ticket.17.pr.ci_recovery.rerun_skipped"}
  end

  test "rerun budget exhaustion raises one actionable alert" do
    parent = self()
    path = journal_path()
    assert :ok = Journal.reserve_rerun(17, "head-sha", 1_000_000, journal_path: path)
    assert :ok = Journal.reserve_rerun(17, "head-sha", 1_060_000, journal_path: path)
    observation = approved_observation()

    opts = [
      approved_fun: fn _, _ -> {:ok, true} end,
      required_checks_fun: fn _ -> {:ok, [%{name: "ci gate", app_id: nil}]} end,
      ci_status_fun: fn _, _ -> {:ok, %{check_runs: [failed_gate()], commit_status: %{"state" => "success", "statuses" => []}}} end,
      jobs_fun: fn _, _ -> {:ok, [%{"name" => "ci gate", "conclusion" => "failure", "steps" => [%{"conclusion" => "cancelled"}]}]} end,
      alert_emitter: fn topic, details ->
        send(parent, {:alert, topic, details})
        :ok
      end,
      journal_path: path,
      now_ms: 1_360_000
    ]

    assert :ok = LandingWatch.process(observation, opts)
    assert :ok = LandingWatch.process(observation, opts)
    assert_received {:alert, "ticket.17.pr.ci_recovery.rerun_limit", details}
    assert Keyword.fetch!(details, :needs_attention)
    refute_received {:alert, "ticket.17.pr.ci_recovery.rerun_limit", _}
  end

  test "poll continues after one PR error and still reconciles the queue" do
    parent = self()

    assert {:error, :one_pr_failed} =
             LandingWatch.poll(
               observe_fun: fn _ -> {:ok, [%{number: 1}, %{number: 2}]} end,
               process_fun: fn observation, _ ->
                 send(parent, {:processed, observation.number})
                 if observation.number == 1, do: {:error, :one_pr_failed}, else: :ok
               end,
               queue_reconcile_fun: fn _, _ ->
                 send(parent, :reconciled)
                 :ok
               end
             )

    assert_received {:processed, 1}
    assert_received {:processed, 2}
    assert_received :reconciled
  end

  test "green approved PR is queued and AI-attributed PR routes to rework" do
    path = journal_path()
    parent = self()
    successful = %{"id" => 60, "name" => "ci gate", "status" => "completed", "conclusion" => "success", "check_suite" => %{"id" => 101}}

    assert :ok =
             LandingWatch.process(
               approved_observation(),
               approved_fun: fn _, _ -> {:ok, true} end,
               required_checks_fun: fn _ -> {:ok, [%{name: "ci gate", app_id: nil}]} end,
               ci_status_fun: fn _, _ -> {:ok, %{check_runs: [successful], commit_status: %{"state" => "success", "statuses" => []}}} end,
               revalidate_fun: fn 17, "head-sha", _ -> :ok end,
               attribution_fun: fn _ -> {:ok, :clean} end,
               ticket_state_fun: fn "17", _ -> {:ok, "human-review"} end,
               enqueue_fun: fn pr ->
                 send(parent, {:enqueued, pr.node_id, pr.head})
                 {:ok, "entry-1"}
               end,
               journal_path: path
             )

    assert_received {:enqueued, "PR_node", "head-sha"}
    assert %{"17:head-sha" => %{"landing" => "queued", "entry" => "entry-1"}} = Jason.decode!(File.read!(path))

    assert :ok =
             LandingWatch.process(
               approved_observation(),
               approved_fun: fn _, _ -> {:ok, true} end,
               required_checks_fun: fn _ -> {:ok, [%{name: "ci gate", app_id: nil}]} end,
               ci_status_fun: fn _, _ -> {:ok, %{check_runs: [successful], commit_status: %{"state" => "success", "statuses" => []}}} end,
               revalidate_fun: fn 17, "head-sha", _ -> :ok end,
               attribution_fun: fn _ -> {:ok, {:ai_attribution, "Co-Authored-By: Codex"}} end,
               ticket_state_fun: fn "17", _ -> {:ok, "human-review"} end,
               rework_fun: fn _, failures, _ ->
                 send(parent, {:attribution_rework, failures})
                 :ok
               end
             )

    assert_received {:attribution_rework, [%{name: "AI commit attribution"}]}
  end

  test "pending checks queue only when the approved PR merge state is clean" do
    parent = self()
    observation = approved_observation() |> Map.put(:mergeable, "MERGEABLE") |> Map.put(:merge_state_status, "CLEAN")
    pending = %{"id" => 61, "run_id" => 199, "name" => "ci gate", "status" => "in_progress", "conclusion" => nil}

    assert :ok =
             LandingWatch.process(
               observation,
               approved_fun: fn _, _ -> {:ok, true} end,
               required_checks_fun: fn _ -> {:ok, [%{name: "ci gate", app_id: nil}]} end,
               ci_status_fun: fn _, _ -> {:ok, %{check_runs: [pending], commit_status: %{"state" => "pending", "statuses" => []}}} end,
               revalidate_fun: fn 17, "head-sha", _ -> :ok end,
               attribution_fun: fn _ -> {:ok, :clean} end,
               ticket_state_fun: fn "17", _ -> {:ok, "human-review"} end,
               enqueue_fun: fn _ ->
                 send(parent, :queued_while_pending)
                 {:ok, "entry-pending"}
               end,
               journal_path: journal_path()
             )

    assert_received :queued_while_pending
  end

  test "withdrawn approval at enqueue boundary prevents enqueue" do
    assert {:error, :approval_or_head_changed} =
             LandingWatch.process(
               approved_observation(),
               approved_fun: fn _, _ -> {:ok, true} end,
               required_checks_fun: fn _ -> {:ok, [%{name: "ci gate", app_id: nil}]} end,
               ci_status_fun: fn _, _ ->
                 {:ok, %{check_runs: [%{"name" => "ci gate", "status" => "completed", "conclusion" => "success"}], commit_status: %{"state" => "success", "statuses" => []}}}
               end,
               revalidate_fun: fn _, _, _ -> {:error, :approval_or_head_changed} end,
               attribution_fun: fn _ -> flunk("must revalidate approval before reading attribution") end,
               ticket_state_fun: fn "17", _ -> {:ok, "human-review"} end,
               enqueue_fun: fn _ -> flunk("must not enqueue after approval changed") end
             )
  end

  test "merging state is accepted by the guarded rework transition" do
    parent = self()
    failed = failed_gate()

    assert :ok =
             LandingWatch.process(
               approved_observation(),
               approved_fun: fn _, _ -> {:ok, true} end,
               required_checks_fun: fn _ -> {:ok, [%{name: "ci gate", app_id: nil}]} end,
               ci_status_fun: fn _, _ -> {:ok, %{check_runs: [failed], commit_status: %{"state" => "success", "statuses" => []}}} end,
               jobs_fun: fn _, _ ->
                 {:ok, [%{"name" => "ci gate", "conclusion" => "failure", "steps" => [%{"conclusion" => "failure"}], "started_at" => "2026-10-14T00:00:00Z", "completed_at" => "2026-10-14T00:00:10Z"}]}
               end,
               rerun_classifier_fun: fn _, _, _, _ -> {:ok, :rework} end,
               journal_path: journal_path(),
               ticket_state_fun: fn "17", _ -> {:ok, "merging"} end,
               transition_fun: fn id, target, options ->
                 send(parent, {:transition, id, target, options})
                 :ok
               end
             )

    assert_received {:transition, "17", "rework", [writer: :landing_watch, expected_state: "merging"]}
  end

  test "watcher status distinguishes a missing process" do
    assert LandingWatch.state(:missing_landing_watcher_test).watcher == :not_running
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
    path = Path.join(System.tmp_dir!(), "landing-watch-#{System.unique_integer([:positive])}.json")
    ExUnit.Callbacks.on_exit(fn -> File.rm(path) end)
    path
  end
end
