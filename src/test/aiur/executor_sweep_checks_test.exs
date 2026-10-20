defmodule Aiur.ExecutorSweep.ChecksTest do
  use ExUnit.Case, async: true

  alias Aiur.ExecutorSweep.Checks
  alias Aiur.ExecutorSweep.SnapshotCache

  test "puts the 23-hour unreviewed PR first and includes age" do
    now = ~U[2026-10-15 18:20:00Z]

    snapshot = %{
      tickets: [%{number: 4429, labels: ["agent:human-review"]}],
      pull_requests: [
        %{number: 4447, issue_number: 4429, state: "open", draft: false, head_sha: "abc", reviewed_head_sha: nil, ready_at: ~U[2026-10-14 19:08:00Z]}
      ]
    }

    assert [finding] = Checks.unreviewed_prs(snapshot, now, 10)
    assert finding.kind == "unreviewed_human_review_pr"
    assert finding.priority == 1
    assert finding.age_ms == 23 * 60 * 60 * 1_000 + 12 * 60 * 1_000
    assert finding.message =~ "23h 12m"
  end

  test "requires a review on the current head and a strict threshold exceedance" do
    now = ~U[2026-10-15 18:20:00Z]
    ticket = %{number: 4, labels: ["agent:human-review"]}
    base = %{number: 5, issue_number: 4, state: "open", draft: false, head_sha: "new", reviewed_head_sha: nil, ready_at: ~U[2026-10-15 18:10:00Z]}
    snapshot = %{tickets: [ticket], pull_requests: [base]}
    assert [] = Checks.unreviewed_prs(snapshot, now, 10)
    assert [finding] = Checks.unreviewed_prs(%{snapshot | pull_requests: [%{base | ready_at: ~U[2026-10-15 18:09:59Z]}]}, now, 10)
    assert finding.age_ms == 10 * 60 * 1_000 + 1_000

    assert [] = Checks.unreviewed_prs(%{snapshot | pull_requests: [%{base | reviewed_head_sha: "new"}]}, now, 1)
  end

  test "threshold boundaries hold at 10, 10+1 and a configured value" do
    now = ~U[2026-10-15 18:20:00Z]
    pr = fn minutes -> %{number: 5, issue_number: 4, state: "open", draft: false, head_sha: "h", reviewed_head_sha: nil, ready_at: DateTime.add(now, -minutes * 60)} end
    snapshot = fn minutes -> %{tickets: [%{number: 4, labels: ["agent:human-review"]}], pull_requests: [pr.(minutes)]} end

    assert [] = Checks.unreviewed_prs(snapshot.(10), now, 10)
    assert [%{age_ms: 660_000}] = Checks.unreviewed_prs(snapshot.(11), now, 10)
    assert [] = Checks.unreviewed_prs(snapshot.(25), now, 25)
    assert [_] = Checks.unreviewed_prs(snapshot.(26), now, 25)
    assert [] = Aiur.ExecutorSweep.findings(snapshot: snapshot.(11), now: now, unreviewed_pr_minutes: 25)
  end

  test "flags a stale merge-group run reported by MainWatch in Unix milliseconds" do
    now = ~U[2026-10-15 18:20:00Z]
    started_at = DateTime.to_unix(~U[2026-10-15 16:00:00Z], :millisecond)
    snapshot = %{merge_groups: [%{name: "run 44", state: "in_progress", started_at: started_at}]}

    assert [%{kind: "stale_merge_group", age_ms: 8_400_000}] = Enum.filter(Checks.all(snapshot, now), &(&1.kind == "stale_merge_group"))
  end

  test "a mergeable queue entry and a fresh merge group produce no finding" do
    now = ~U[2026-10-15 18:20:00Z]
    snapshot = %{merge_queue: [%{number: 9, mergeable: "MERGEABLE"}], merge_groups: [%{name: "run 45", state: "in_progress", started_at: now}]}

    assert [] = Checks.all(snapshot, now)
  end

  test "names conflicting PRs that strand ci-wait and human-review tickets" do
    snapshot = %{
      tickets: [%{number: 5267, labels: ["agent:ci-wait"]}, %{number: 5268, labels: ["agent:human-review"]}],
      pull_requests: [
        %{
          number: 5172,
          issue_number: 5267,
          state: "open",
          mergeable: "CONFLICTING",
          review_decision: "APPROVED",
          head_sha: "head",
          approved_head_sha: "head",
          in_merge_queue: false,
          auto_merge: false,
          required_checks: []
        },
        %{number: 5173, issue_number: 5268, state: "open", mergeable: "CONFLICTING"}
      ]
    }

    findings = Checks.all(snapshot, ~U[2026-10-19 12:00:00Z])

    assert [%{kind: "conflicting_waiting_pr", ticket: 5267, pull_request: 5172, message: message, action: action}, %{kind: "conflicting_waiting_pr", ticket: 5268, pull_request: 5173}] = findings

    assert message =~ "conflicting"
    assert action =~ "Merge main"
    refute Enum.any?(findings, &(&1.kind == "approved_pr_not_landing"))
  end

  test "does not treat an old-head approval as current approval" do
    snapshot = %{pull_requests: [%{number: 10, state: "open", head_sha: "new", approved_head_sha: "old", review_decision: "APPROVED", in_merge_queue: false, auto_merge: false, required_checks: []}]}

    refute Enum.any?(Checks.all(snapshot, ~U[2026-10-15 18:20:00Z]), &(&1.kind == "approved_pr_not_landing"))
  end

  test "does not report an approved PR with a cached merge timestamp as not landing" do
    cached_pr = %{
      number: 4574,
      state: "open",
      merged_at: "2026-10-16T01:07:00Z",
      review_decision: "APPROVED",
      head_sha: "head",
      approved_head_sha: "head",
      in_merge_queue: false,
      auto_merge: false,
      required_checks: []
    }

    cached_body = %{
      "state" => "open",
      "merged_at" => cached_pr.merged_at,
      "head" => %{"ref" => "aiur/4574-fix", "sha" => "head"}
    }

    [normalized_pr] = SnapshotCache.build([{4574, cached_body}], [], []).pull_requests
    pr = Map.merge(normalized_pr, Map.drop(cached_pr, [:state, :merged_at]))

    refute Enum.any?(Checks.all(%{pull_requests: [pr]}, ~U[2026-10-18 14:00:00Z]), fn finding ->
             finding.kind == "approved_pr_not_landing" and finding.pull_request == 4574
           end)
  end

  test "red required check cause is unknown unless the same check passes on base" do
    pr = %{
      number: 5018,
      state: "open",
      review_decision: "APPROVED",
      head_sha: "head",
      base_sha: "base-sha",
      approved_head_sha: "head",
      in_merge_queue: false,
      auto_merge: false,
      required_checks: [%{name: "test", conclusion: "failure"}]
    }

    assert [%{failure_class: "unknown"}] = Checks.all(%{pull_requests: [pr]}, ~U[2026-10-18 14:00:00Z]) |> Enum.filter(&(&1.kind == "approved_pr_red"))

    assert [%{failure_class: "unknown"}] =
             Checks.all(%{pull_requests: [pr], base_checks: [%{name: "test", base_sha: "other-base", conclusion: "success"}]}, ~U[2026-10-18 14:00:00Z]) |> Enum.filter(&(&1.kind == "approved_pr_red"))

    assert [%{failure_class: "caused_by_pr"}] =
             Checks.all(%{pull_requests: [pr], base_checks: [%{name: "test", base_sha: "base-sha", conclusion: "success"}]}, ~U[2026-10-18 14:00:00Z]) |> Enum.filter(&(&1.kind == "approved_pr_red"))
  end

  test "summarizes invalid labels and excludes parked tickets" do
    tickets = [
      %{number: 1767, labels: [], created_at: "2026-02-01T00:00:00Z"},
      %{number: 1800, labels: ["agent:todo", "agent:rework"], created_at: "2026-01-01T00:00:00Z"},
      %{number: 1900, labels: ["needs-triage"]},
      %{number: 1901, labels: ["human:todo"]},
      %{number: 1902, labels: ["Epic"]},
      %{number: 1903, labels: ["agent:parked"]}
    ]

    assert [%{ticket: 1800, ticket_count: 2, message: message}] = Checks.all(%{tickets: tickets}, ~U[2026-10-18 14:00:00Z]) |> Enum.filter(&(&1.kind == "invalid_state_labels"))
    assert message =~ "2 open ticket(s)"
    assert message =~ "oldest ticket #1800"
  end

  test "summarizes a stale triage backlog in one finding with its count and oldest ticket" do
    snapshot = %{
      open_tickets: %Aiur.OpenTicketSource.Snapshot{
        status: :available,
        tickets: [
          %{identifier: "4466", labels: ["needs-triage"], created_at: ~U[2026-10-15 09:00:00Z]},
          %{identifier: "4500", labels: ["needs-triage"], created_at: ~U[2026-10-16 10:30:00Z]},
          %{identifier: "4511", labels: ["agent:todo"], created_at: ~U[2026-10-15 09:00:00Z]}
        ]
      }
    }

    assert [%{kind: "stale_needs_triage", ticket: 4466, oldest_ticket: 4466, ticket_count: 2, message: message}] =
             Enum.filter(Checks.all(snapshot, ~U[2026-10-16 12:00:00Z]), &(&1.kind == "stale_needs_triage"))

    assert message =~ "2 open ticket(s)"
    assert message =~ "oldest #4466"
  end

  test "2026-10-15 fixture produces every operational finding family" do
    now = ~U[2026-10-15 18:20:00Z]
    old = ~U[2026-10-15 16:00:00Z]

    snapshot = %{
      decisions: [%{id: "decision-1", blocking: true, status: "open", created_at: ~U[2026-10-15 18:00:00Z]}],
      pull_requests: [
        %{number: 4447, issue_number: 4429, state: "open", draft: false, head_sha: "current", reviewed_head_sha: nil, ready_at: ~U[2026-10-14 19:08:00Z]},
        %{
          number: 9,
          issue_number: 3,
          state: "open",
          review_decision: "APPROVED",
          auto_merge: false,
          in_merge_queue: false,
          required_checks: [%{conclusion: "startup_failure"}],
          failure_class: "infra"
        },
        %{number: 10, issue_number: 4, state: "open", review_decision: "APPROVED", auto_merge: true, in_merge_queue: false, required_checks: [%{conclusion: "failure"}], failure_class: "pr"},
        %{number: 11, issue_number: 8, state: "open", review_decision: "APPROVED", auto_merge: false, in_merge_queue: false, required_checks: []}
      ],
      merge_queue: [%{number: 9, mergeable: "UNMERGEABLE"}],
      merge_groups: [%{name: "merge-group-1", state: "in_progress", started_at: old}],
      idle_slots: 2,
      queue_sets: [%{id: "held-set", held: true}],
      focus_set: %{id: "focus-set", startable_count: 2, claimed_count: 0},
      queue_order_declared?: true,
      queue_order: ["later", "focus"],
      feature_order: ["focus", "later"],
      tickets: [
        %{number: 4429, labels: ["agent:human-review"]},
        %{number: 3, labels: ["agent:error"]},
        %{number: 4, labels: ["agent:human-review"], created_at: old, unchanged_pr_handoffs: 3},
        %{number: 5, labels: ["agent:rework"], open_blocked_by: [99]},
        %{number: 7, labels: ["agent:todo", "agent:rework"]},
        %{number: 12, labels: ["agent:paused"], closed_blockers: [90]}
      ],
      open_tickets: %Aiur.OpenTicketSource.Snapshot{status: :available, tickets: [%{identifier: "6", labels: ["needs-triage"], created_at: ~U[2026-10-15 16:00:00Z]}]},
      services: [%{name: "watchers", status: "down"}, %{name: "dispatcher", status: "stalled"}]
    }

    kinds = Checks.all(snapshot, now) |> Enum.map(& &1.kind)
    findings = Checks.all(snapshot, now)

    assert hd(kinds) == "unreviewed_human_review_pr"

    for kind <- [
          "unanswered_blocking_decision",
          "approved_pr_red",
          "approved_pr_not_landing",
          "unmergeable_queue_entry",
          "stale_merge_group",
          "held_queue_set_idle_slots",
          "focus_set_unclaimed",
          "queue_order_mismatch",
          "invalid_state_labels",
          "stale_needs_triage",
          "error_ticket_open_pr",
          "parked_ticket_closed_blocker",
          "rework_ticket_blocked",
          "unchanged_pr_handoff_loop",
          "service_unhealthy"
        ] do
      assert kind in kinds
    end

    assert Enum.find(findings, &(Map.get(&1, :pull_request) == 9 and &1.kind == "approved_pr_red")).failure_class == "infra"
    assert Enum.find(findings, &(Map.get(&1, :pull_request) == 10 and &1.kind == "approved_pr_red")).failure_class == "unknown"
  end

  @snapshot_keys [:pull_requests, :tickets, :decisions, :merge_queue, :merge_groups, :queue_sets, :idle_slots, :queue_order, :feature_order, :services]

  defp healthy_snapshot do
    %{
      pull_requests: [%{number: 1, issue_number: 1, state: "open", in_merge_queue: true}],
      tickets: [%{number: 1, labels: ["agent:human-review"]}],
      decisions: [],
      merge_queue: [%{number: 1, mergeable: "MERGEABLE"}, %{number: 2, mergeable: "UNMERGEABLE"}],
      merge_groups: [%{name: "run 1", state: "completed", started_at: ~U[2026-10-15 18:19:00Z]}],
      queue_sets: [],
      idle_slots: 0,
      focus_set: nil,
      queue_order: [],
      feature_order: [],
      services: [%{name: "watchers", status: "down"}]
    }
  end

  test "mergeable queue entries and fresh merge groups produce no findings instead of crashing" do
    kinds = healthy_snapshot() |> Checks.all(~U[2026-10-15 18:20:00Z]) |> Enum.map(& &1.kind)

    assert "unmergeable_queue_entry" in kinds
    refute "stale_merge_group" in kinds
    refute "sweep_check_failed" in kinds
  end

  test "a nil snapshot key reports its checks unknown and keeps the other checks running" do
    for key <- @snapshot_keys do
      findings = Checks.all(Map.put(healthy_snapshot(), key, nil), ~U[2026-10-15 18:20:00Z])
      unknown = Enum.filter(findings, &(&1.kind == "sweep_source_unavailable"))

      assert unknown != [], "#{key}: no unknown finding"
      assert Enum.all?(unknown, &(&1.sources == [key])), "#{key}: #{inspect(unknown)}"
      refute Enum.any?(findings, &(&1.kind == "sweep_check_failed")), "#{key}: #{inspect(findings)}"

      if key != :services, do: assert(Enum.any?(findings, &(&1.kind == "service_unhealthy")), "#{key}: services check skipped")
    end
  end

  test "a raising check is reported without skipping the cycle" do
    snapshot = %{healthy_snapshot() | decisions: [:not_a_map]}
    findings = Aiur.ExecutorSweep.findings(snapshot: snapshot, now: ~U[2026-10-15 18:20:00Z], unreviewed_pr_minutes: 10)

    assert [%{check: "old_decisions"}] = Enum.filter(findings, &(&1.kind == "sweep_check_failed"))
    assert Enum.any?(findings, &(&1.kind == "service_unhealthy"))
    assert Enum.any?(findings, &(&1.kind == "unmergeable_queue_entry"))
  end

  test "lists approved PRs waiting on the landing watcher's shared rerun cap" do
    now = ~U[2026-10-15 18:20:00Z]
    since = DateTime.to_unix(now, :millisecond) - 12 * 60_000
    row = %{"pr" => 4610, "head" => "abc", "reason" => "known flake", "checks" => ["ci gate"], "since_ms" => since}

    assert [finding] = Checks.all(%{landing_rerun_backlog: [row]}, now) |> Enum.filter(&(&1.kind == "approved_pr_rerun_pending"))
    assert %{pull_request: 4610, head_sha: "abc", priority: 3, age_ms: 720_000} = finding
    assert finding.message == "Approved PR #4610 awaits an automatic CI rerun of ci gate (known flake) for 12m."
    assert [%{kind: "sweep_source_unavailable", sources: [:landing_rerun_backlog]}] = Checks.all(%{landing_rerun_backlog: nil}, now)

    refresh = Map.merge(row, %{"action" => "refresh", "reason" => "superseded job name"})
    assert [finding] = Checks.all(%{landing_rerun_backlog: [refresh]}, now) |> Enum.filter(&(&1.kind == "approved_pr_refresh_pending"))
    assert finding.message == "Approved PR #4610 needs a fresh merge ref for ci gate (superseded job name); waiting 12m."
  end
end
