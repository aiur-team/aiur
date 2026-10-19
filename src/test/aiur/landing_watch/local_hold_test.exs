defmodule Aiur.LandingWatch.LocalHoldTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog

  alias Aiur.LandingWatch

  test "an expired observation hold retries without logging the poll as unavailable" do
    parent = self()
    server = {:global, {__MODULE__, make_ref()}}
    hold = %{reason: :shared_budget, resource: "core", reset_at: DateTime.add(DateTime.utc_now(), -1, :second)}
    failure = {:error, {:github, :local_hold, %{reason: {:aiur, :locally_held, hold}, hold: hold}}}

    log =
      capture_log(fn ->
        {:ok, pid} =
          LandingWatch.start_link(
            name: server,
            interval_ms: 60_000,
            subscribe: false,
            observe_fun: fn _ ->
              attempt = Process.get(:landing_watch_server_attempt, 0)
              Process.put(:landing_watch_server_attempt, attempt + 1)
              send(parent, {:observe, attempt})
              if attempt == 0, do: failure, else: {:ok, []}
            end,
            local_hold_sleep_fun: fn _ms -> :ok end,
            queue_reconcile_fun: fn _, _ -> :ok end
          )

        assert_receive {:observe, 0}, 1_000
        assert_receive {:observe, 1}, 1_000
        assert eventually(fn -> not is_nil(LandingWatch.state(server).last_poll_at_ms) end)
        assert LandingWatch.state(server).watcher == :running
        GenServer.stop(pid)
      end)

    refute log =~ "landing watcher poll unavailable"
  end

  test "a hold beyond the wait ceiling remains an error without retrying the poll" do
    parent = self()
    reset_at = DateTime.add(DateTime.utc_now(), 30, :second)
    hold = %{reason: :shared_budget, resource: "core", reset_at: reset_at}
    failure = {:error, {:github, :local_hold, %{reason: {:aiur, :locally_held, hold}, hold: hold}}}

    assert ^failure =
             LandingWatch.poll(
               observe_fun: fn _ ->
                 send(parent, :observe)
                 failure
               end,
               local_hold_max_wait_ms: 100,
               local_hold_sleep_fun: fn _ms -> flunk("a hold beyond the wait ceiling must fail closed") end
             )

    assert_received :observe
    refute_received :observe
  end

  test "a late poll error does not rerun already completed work" do
    parent = self()
    hold = %{reason: :shared_budget, resource: "core", reset_at: DateTime.add(DateTime.utc_now(), -1, :second)}
    failure = {:error, {:github, :local_hold, %{reason: {:aiur, :locally_held, hold}, hold: hold}}}

    assert ^failure =
             LandingWatch.poll(
               observe_fun: fn _ ->
                 send(parent, :observe)
                 {:ok, [%{number: 17}]}
               end,
               journal_prune_fun: fn _, _ ->
                 send(parent, :journal_pruned)
                 :ok
               end,
               process_fun: fn _, _ ->
                 send(parent, :write)
                 failure
               end,
               queue_reconcile_fun: fn _, _ -> :ok end,
               local_hold_sleep_fun: fn _ms -> flunk("poll-level retries must not repeat work") end
             )

    assert_received :observe
    assert_received :journal_pruned
    assert_received :write
    refute_received :observe
    refute_received :journal_pruned
    refute_received :write
  end

  test "a per-PR CI read retries an expired hold without repeating the journal write" do
    parent = self()
    observation = approved_observation()
    hold = %{reason: :shared_budget, resource: "core", reset_at: DateTime.add(DateTime.utc_now(), -1, :second)}
    failure = {:error, {:github, :local_hold, %{reason: {:aiur, :locally_held, hold}, hold: hold}}}

    log =
      capture_log(fn ->
        assert :ok =
                 LandingWatch.poll(
                   observe_fun: fn _ -> {:ok, [observation]} end,
                   journal_prune_fun: fn _, _ ->
                     send(parent, :journal_pruned)
                     :ok
                   end,
                   approved_fun: fn _, _ -> {:ok, true} end,
                   required_checks_fun: fn _ -> {:ok, []} end,
                   ci_status_fun: fn _, _ ->
                     attempt = Process.get(:landing_watch_ci_status_attempt, 0)
                     Process.put(:landing_watch_ci_status_attempt, attempt + 1)
                     send(parent, {:ci_status, attempt})
                     if attempt == 0, do: failure, else: pending_ci()
                   end,
                   queue_reconcile_fun: fn _, _ -> :ok end,
                   local_hold_sleep_fun: fn _ms -> flunk("an expired per-PR hold must retry without sleeping") end
                 )
      end)

    refute log =~ "landing watcher poll unavailable"
    assert_received :journal_pruned
    refute_received :journal_pruned
    assert_received {:ci_status, 0}
    assert_received {:ci_status, 1}
    refute_received {:ci_status, _}
  end

  test "a per-PR CI hold beyond the wait ceiling fails closed without sleeping" do
    observation = approved_observation()
    hold = %{reason: :shared_budget, resource: "core", reset_at: DateTime.add(DateTime.utc_now(), 30, :second)}
    failure = {:error, {:github, :local_hold, %{reason: {:aiur, :locally_held, hold}, hold: hold}}}

    assert ^failure =
             LandingWatch.poll(
               observe_fun: fn _ -> {:ok, [observation]} end,
               journal_prune_fun: fn _, _ -> :ok end,
               approved_fun: fn _, _ -> {:ok, true} end,
               required_checks_fun: fn _ -> {:ok, []} end,
               ci_status_fun: fn _, _ -> failure end,
               queue_reconcile_fun: fn _, _ -> :ok end,
               local_hold_max_wait_ms: 100,
               local_hold_sleep_fun: fn _ms -> flunk("a hold beyond the wait ceiling must fail closed") end
             )
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.(),
      do: true,
      else:
        (
          Process.sleep(10)
          eventually(fun, attempts - 1)
        )
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

  defp pending_ci do
    {:ok, %{check_runs: [], commit_status: %{"state" => "pending", "statuses" => []}}}
  end
end
