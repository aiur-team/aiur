defmodule Aiur.LandingWatch.ConflictRoutingTest do
  use ExUnit.Case, async: true

  alias Aiur.LandingWatch
  alias Aiur.LandingWatch.Journal

  @green %{"id" => 60, "name" => "ci gate", "status" => "completed", "conclusion" => "success", "check_suite" => %{"id" => 101}}

  test "one cycle moves an approved green PR that conflicts with main to rebase-only rework" do
    parent = self()

    assert :ok = LandingWatch.poll(cycle_opts(parent, conflicting(nil), "human-review"))

    refute_received {:withdraw, _}
    assert_received {:transition, "17", "rework", [writer: :landing_watch, expected_state: "human-review"]}
    assert_received {:comment, "17", body}
    assert body =~ "Rebase only"
    assert body =~ "conflicts with `main`"
    assert body =~ "Make no other change"
    assert body =~ "approval at `head-sha`"
    assert_received {:remove_label, "17", "agent:paused"}
    refute_received {:enqueued, _}
  end

  test "a conflicting merge queue entry is dequeued before its ticket is routed the same way" do
    parent = self()

    assert :ok = LandingWatch.poll(cycle_opts(parent, conflicting(%{"id" => "MQE_1"}), "merging"))

    assert {:messages, [{:withdraw, 17}, {:transition, "17", "rework", _}, {:comment, "17", body}, {:remove_label, "17", "agent:paused"}]} =
             Process.info(self(), :messages)

    assert body =~ "Rebase only"
  end

  test "a persistent unmergeable queue entry routes an UNKNOWN PR to rebase-only rework" do
    parent = self()
    opts = cycle_opts(parent, queue_conflict("UNKNOWN"), "human-review") |> Keyword.put(:queue_prs_ahead_fun, fn _, _ -> {:ok, [5009, 5414, 5007]} end)

    assert :ok = LandingWatch.poll(Keyword.put(opts, :now_ms, 1_000_000))
    refute_received {:withdraw, _}

    assert :ok = LandingWatch.poll(Keyword.put(opts, :now_ms, 1_300_000))

    assert_received {:withdraw, 17}
    assert_received {:transition, "17", "rework", _}
    assert_received {:comment, "17", body}
    assert body =~ "queued behind PRs #5009, #5414, #5007"
  end

  test "a transient unmergeable queue entry that clears is not routed" do
    parent = self()
    opts = cycle_opts(parent, queue_conflict("UNKNOWN"), "human-review")

    assert :ok = LandingWatch.poll(Keyword.put(opts, :now_ms, 1_000_000))
    cleared = %{queue_conflict("UNKNOWN") | merge_queue_entry: %{"id" => "MQE_1", "state" => "AWAITING_CHECKS"}}
    assert :ok = LandingWatch.poll(Keyword.put(opts, :observe_fun, fn _ -> {:ok, [cleared]} end) |> Keyword.put(:now_ms, 1_060_000))

    assert :ok = LandingWatch.poll(Keyword.put(opts, :now_ms, 1_400_000))
    refute_received {:withdraw, _}
    refute_received {:transition, _, _, _}
    refute_received {:comment, _, _}
  end

  test "an operator-held conflicting ticket stays paused and raises attention" do
    parent = self()

    opts =
      cycle_opts(parent, conflicting(nil), "human-review")
      |> Keyword.put(:ticket_state_fun, fn "17", _ -> {:ok, %{state: "human-review", paused?: true}} end)
      |> Keyword.put(:alert_emitter, fn topic, alert_opts ->
        send(parent, {:attention, topic, alert_opts})
        :ok
      end)

    assert :ok = Journal.record_pause_writer("17", :pause_resume, journal_path: Keyword.fetch!(opts, :journal_path))
    assert :ok = LandingWatch.poll(opts)
    refute_received {:remove_label, "17", "agent:paused"}
    assert_received {:attention, "ticket.17.agent.attention.conflicting_held_pr", alert_opts}
    assert alert_opts[:needs_attention]
    assert alert_opts[:reason] =~ "Conflicting approved PR #17"
  end

  test "a failed dequeue leaves the ticket alone so the next cycle retries" do
    parent = self()
    opts = Keyword.put(cycle_opts(parent, conflicting(%{"id" => "MQE_1"}), "merging"), :withdraw_fun, fn _ -> {:error, :boom, []} end)

    assert {:error, {:conflict_withdrawal_failed, :boom}} = LandingWatch.poll(opts)
    refute_received {:transition, _, _, _}
    refute_received {:comment, _, _}
  end

  test "a ticket already in rework is not commented again" do
    parent = self()

    assert :ok = LandingWatch.poll(cycle_opts(parent, conflicting(nil), "rework"))

    refute_received {:transition, _, _, _}
    refute_received {:comment, _, _}
    refute_received {:enqueued, _}
  end

  test "a failed follow-up is retried when the ticket is already in rework" do
    parent = self()
    Process.put(:conflict_comment_attempt, 0)

    opts = cycle_opts(parent, conflicting(nil), "human-review")

    failing_comment = fn id, body ->
      attempt = Process.get(:conflict_comment_attempt) + 1
      Process.put(:conflict_comment_attempt, attempt)
      send(parent, {:comment_attempt, id, body})
      if attempt == 1, do: {:error, :temporary}, else: :ok
    end

    assert {:error, {:conflict_follow_up, :temporary}} = LandingWatch.poll(Keyword.put(opts, :comment_fun, failing_comment))
    assert_received {:transition, "17", "rework", _}
    assert_received {:comment_attempt, "17", _}
    refute_received {:remove_label, _, _}

    assert :ok =
             LandingWatch.poll(
               Keyword.put(opts, :ticket_state_fun, fn "17", _ -> {:ok, %{state: "rework", paused?: true}} end)
               |> Keyword.put(:comment_fun, failing_comment)
             )

    assert_received {:comment_attempt, "17", _}
    assert_received {:remove_label, "17", "agent:paused"}
    refute_received {:transition, _, _, _}
  end

  test "a completed route is not repeated when the ticket returns to review at the same head" do
    parent = self()
    path = journal_path()
    opts = cycle_opts(parent, conflicting(nil), "human-review") |> Keyword.put(:journal_path, path)

    assert :ok = LandingWatch.poll(opts)
    assert_received {:transition, "17", "rework", _}
    assert_received {:comment, "17", _}

    assert :ok = LandingWatch.poll(Keyword.put(opts, :ticket_state_fun, fn "17", _ -> {:ok, "human-review"} end))
    refute_received {:transition, _, _, _}
    refute_received {:comment, _, _}
  end

  test "a ticket that was not routed does not receive a later rework follow-up" do
    parent = self()
    path = journal_path()
    opts = cycle_opts(parent, conflicting(nil), "in-progress") |> Keyword.put(:journal_path, path)

    assert :ok = LandingWatch.poll(opts)
    refute_received {:transition, _, _, _}
    refute_received {:comment, _, _}
    refute_received {:remove_label, _, _}

    assert :ok = LandingWatch.poll(Keyword.put(opts, :ticket_state_fun, fn "17", _ -> {:ok, "rework"} end))
    refute_received {:transition, _, _, _}
    refute_received {:comment, _, _}
    refute_received {:remove_label, _, _}
  end

  defp cycle_opts(parent, observation, ticket_state) do
    [
      observe_fun: fn _ -> {:ok, [observation]} end,
      journal_prune_fun: fn _, _ -> :ok end,
      queue_reconcile_fun: fn _, _ -> :ok end,
      approved_fun: fn _, _ -> {:ok, true} end,
      required_checks_fun: fn _ -> {:ok, [%{name: "ci gate", app_id: nil}]} end,
      ci_status_fun: fn _, _ -> {:ok, %{check_runs: [@green], commit_status: %{"state" => "success", "statuses" => []}}} end,
      revalidate_fun: fn _, _, _ -> :ok end,
      attribution_fun: fn _ -> {:ok, :clean} end,
      enqueue_fun: fn pr ->
        send(parent, {:enqueued, pr.head})
        {:ok, "entry-1"}
      end,
      ticket_state_fun: fn "17", _ -> {:ok, %{state: ticket_state, paused?: true}} end,
      withdraw_fun: fn number ->
        send(parent, {:withdraw, number})
        {:ok, [:dequeued]}
      end,
      transition_fun: fn id, target, options ->
        send(parent, {:transition, id, target, options})
        :ok
      end,
      comment_fun: fn id, body ->
        send(parent, {:comment, id, body})
        :ok
      end,
      write_marker_fun: fn id, :remove, label, writer_opts ->
        assert writer_opts[:writer] == :landing_watch
        send(parent, {:remove_label, id, label})
        :ok
      end,
      pause_label: "agent:paused",
      journal_path: journal_path(),
      alert_emitter: fn _, _ -> :ok end
    ]
    |> then(fn opts ->
      :ok = Journal.record_pause_writer("17", :approval_pause, journal_path: Keyword.fetch!(opts, :journal_path))
      opts
    end)
  end

  defp conflicting(entry) do
    %{
      number: 17,
      node_id: "PR_node",
      head: "head-sha",
      base: "main",
      draft?: false,
      review_decision: "APPROVED",
      mergeable: "CONFLICTING",
      merge_state_status: "DIRTY",
      merge_queue_entry: entry,
      auto_merge_request: nil,
      rest: %{"head" => %{"ref" => "aiur/17-work"}},
      raw: %{"reviewDecision" => "APPROVED", "headRefOid" => "head-sha", "isDraft" => false, "reviews" => %{"nodes" => [%{"commit" => %{"oid" => "head-sha"}}]}}
    }
  end

  defp queue_conflict(mergeable) do
    %{conflicting(%{"id" => "MQE_1", "state" => "UNMERGEABLE", "position" => 4}) | mergeable: mergeable, merge_state_status: "UNKNOWN"}
  end

  defp journal_path do
    path = Path.join(System.tmp_dir!(), "landing-watch-conflict-#{System.unique_integer([:positive])}.json")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(path) end)
    path
  end
end
