defmodule Aiur.ExecutorSweep.ChecksTest do
  use ExUnit.Case, async: true

  alias Aiur.ExecutorSweep.Checks
  alias Aiur.ExecutorSweep.SnapshotCache
  alias Aiur.GitHub.ResourceStore

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
    snapshot = %{merge_groups: [%{id: 44, name: "run 44", state: "in_progress", started_at: started_at}], github_cache_ages: %{merge_group_runs: %{44 => 0}}}

    assert [%{kind: "stale_merge_group", age_ms: 8_400_000}] = Enum.filter(Checks.all(snapshot, now), &(&1.kind == "stale_merge_group"))
  end

  test "reports cache age on fresh GitHub findings and suppresses findings older than five minutes" do
    now = ~U[2026-10-15 18:20:00Z]
    old = ~U[2026-10-15 16:00:00Z]
    group = %{name: "run 44", state: "in_progress", started_at: old}
    pr = %{number: 12, state: "open", review_decision: "APPROVED", head_sha: "head", approved_head_sha: "head", required_checks: [%{name: "ci", conclusion: "failure"}]}
    group = Map.put(group, :id, 44)
    fresh = %{pull_requests: [pr], merge_groups: [group], github_cache_ages: %{pull_requests: %{12 => 120_000}, merge_group_runs: %{44 => 240_000}}}

    findings = Checks.all(fresh, now)
    assert [%{kind: "approved_pr_red", cache_age_ms: 120_000, message: pr_message}] = Enum.filter(findings, &(&1.kind == "approved_pr_red"))
    assert pr_message =~ "GitHub cache age: 2m"
    assert [%{kind: "stale_merge_group", cache_age_ms: 240_000, message: group_message}] = Enum.filter(findings, &(&1.kind == "stale_merge_group"))
    assert group_message =~ "GitHub cache age: 4m"

    stale = %{fresh | github_cache_ages: %{pull_requests: %{12 => 300_001}, merge_group_runs: %{44 => 300_001}}}
    stale_findings = Checks.all(stale, now)
    assert [%{verification: "unverified", message: stale_pr_message}] = Enum.filter(stale_findings, &(&1.kind == "approved_pr_red"))
    assert stale_pr_message =~ "unverified"
    assert [%{verification: "unverified", message: stale_group_message}] = Enum.filter(stale_findings, &(&1.kind == "stale_merge_group"))
    assert stale_group_message =~ "unverified"

    old_pr = %{pr | number: 99}
    mixed = %{fresh | pull_requests: [pr, old_pr], github_cache_ages: %{pull_requests: %{12 => 120_000, 99 => 800_000}, merge_group_runs: %{44 => 240_000}}}
    pr_findings = Enum.filter(Checks.all(mixed, now), &(&1.kind == "approved_pr_red"))
    assert [%{pull_request: 12, verification: "verified"}, %{pull_request: 99, verification: "unverified"}] = Enum.sort_by(pr_findings, & &1.pull_request)
  end

  test "does not make GitHub run or check findings when source cache age is unavailable" do
    now = ~U[2026-10-15 18:20:00Z]

    snapshot = %{
      pull_requests: [%{number: 13, state: "open", review_decision: "APPROVED", head_sha: "head", approved_head_sha: "head", required_checks: [%{conclusion: "failure"}]}],
      merge_groups: [%{id: 46, name: "run 46", state: "queued", started_at: ~U[2026-10-15 16:00:00Z]}],
      github_cache_ages: %{pull_requests: %{13 => nil}, merge_group_runs: %{}}
    }

    findings = Checks.all(snapshot, now)
    assert [%{verification: "unverified"}] = Enum.filter(findings, &(&1.kind == "approved_pr_red"))
    assert [%{verification: "unverified"}] = Enum.filter(findings, &(&1.kind == "stale_merge_group"))
  end

  test "a snapshot read carries body fetch ages for GitHub-derived sources" do
    now_ms = System.system_time(:millisecond)

    pr_key = {:pull_request, "aiur-team", "aiur", "87"}
    run_key = {:landing_merge_group_runs, "aiur-team", "aiur", "87"}
    :ok = ResourceStore.put_resource(pr_key, %{"number" => 87}, source: :fetch)
    :ok = ResourceStore.put_resource(run_key, [%{"id" => 87}], source: :fetch)
    [{^pr_key, pr_entry}] = :ets.lookup(Aiur.GitHub.ResourceStore.Table, pr_key)
    [{^run_key, run_entry}] = :ets.lookup(Aiur.GitHub.ResourceStore.Table, run_key)

    :ets.insert(Aiur.GitHub.ResourceStore.Table, [
      {pr_key, Map.put(pr_entry, :fetched_at_ms, now_ms - 90_000)},
      {run_key, Map.put(run_entry, :fetched_at_ms, now_ms - 30_000)}
    ])

    assert %{pull_requests: %{87 => 90_000}, merge_group_runs: %{87 => 30_000}} =
             SnapshotCache.github_cache_ages("aiur-team", "aiur", now_ms)
  end

  test "cache age uses the newest body among many entries of the same type" do
    now_ms = System.system_time(:millisecond)
    suffix = Integer.to_string(System.unique_integer([:positive]))
    repo = "aiur-sweep-#{suffix}"
    old_key = {:pull_request, "aiur-team", repo, "88"}
    fresh_key = {:pull_request, "aiur-team", repo, "89"}

    :ok = ResourceStore.put_resource(old_key, %{"number" => 88}, source: :fetch)
    :ok = ResourceStore.put_resource(fresh_key, %{"number" => 89}, source: :fetch)
    [{^old_key, old_entry}] = :ets.lookup(Aiur.GitHub.ResourceStore.Table, old_key)
    [{^fresh_key, fresh_entry}] = :ets.lookup(Aiur.GitHub.ResourceStore.Table, fresh_key)

    :ets.insert(Aiur.GitHub.ResourceStore.Table, [
      {old_key, Map.put(old_entry, :fetched_at_ms, now_ms - 900_000)},
      {fresh_key, Map.put(fresh_entry, :fetched_at_ms, now_ms - 15_000)}
    ])

    assert %{pull_requests: %{88 => 900_000, 89 => 15_000}} = SnapshotCache.github_cache_ages("aiur-team", repo, now_ms)
  end

  test "a mergeable queue entry and a fresh merge group produce no finding" do
    now = ~U[2026-10-15 18:20:00Z]

    snapshot = %{
      merge_queue: [%{number: 9, mergeable: "MERGEABLE"}],
      merge_groups: [%{id: 45, name: "run 45", state: "in_progress", started_at: now}],
      github_cache_ages: %{merge_group_runs: %{45 => 0}}
    }

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

  test "finds ci-wait tickets older than two hours when required checks are terminal" do
    now = ~U[2026-10-21 18:00:00Z]

    snapshot = %{
      tickets: [%{number: 5579, labels: ["agent:ci-wait"], updated_at: ~U[2026-10-21 15:59:59Z]}],
      pull_requests: [%{number: 6000, issue_number: 5579, state: "open", head_sha: "head", ci_head_sha: "head", ci_decision: :passed, required_checks: [%{name: "test", conclusion: "success"}]}]
    }

    assert [%{kind: "stale_ci_wait_without_pending_checks", issue_number: 5579, pull_request: 6000, age_ms: 7_201_000}] =
             Enum.filter(Checks.all(snapshot, now), &(&1.kind == "stale_ci_wait_without_pending_checks"))

    snapshot = update_in(snapshot.tickets, &[Map.put(hd(&1), :updated_at, ~U[2026-10-21 16:00:00Z])])
    assert [] = Enum.filter(Checks.all(snapshot, now), &(&1.kind == "stale_ci_wait_without_pending_checks"))

    snapshot = put_in(snapshot.pull_requests, [%{hd(snapshot.pull_requests) | required_checks: [%{name: "test", conclusion: "in_progress"}]}])
    assert [] = Enum.filter(Checks.all(snapshot, now), &(&1.kind == "stale_ci_wait_without_pending_checks"))
  end

  test "stale ci-wait sweep ignores a pending current-head CI observation" do
    now = DateTime.utc_now()
    started = DateTime.add(now, -3 * 60 * 60, :second)

    snapshot = %{
      tickets: [%{number: 5579, labels: ["ci-wait"], ci_wait_since: started}],
      pull_requests: [%{number: 6000, issue_number: 5579, state: "open", head_sha: "head", ci_head_sha: "head", ci_decision: :pending, required_checks: []}]
    }

    assert [] = Enum.filter(Checks.all(snapshot, now), &(&1.kind == "stale_ci_wait_without_pending_checks"))
  end

  test "snapshot tracks the latest ci-wait label time from the issue timeline" do
    ticket =
      SnapshotCache.build(
        [],
        [],
        [{5579, ["agent:ci-wait"]}],
        %{5579 => %{"updated_at" => "2026-10-21T17:59:00Z"}},
        %{},
        [],
        %{5579 => %{"events" => [%{"event" => "labeled", "label" => %{"name" => "agent:ci-wait"}, "created_at" => "2026-10-21T15:30:00Z"}]}},
        %{status: :available, tickets: [], truncated?: false}
      )
      |> Map.fetch!(:tickets)
      |> hd()

    assert ticket.ci_wait_since == "2026-10-21T15:30:00Z"
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

    assert [%{failure_class: "unknown"}] =
             Checks.all(%{pull_requests: [pr], github_cache_ages: %{pull_requests: %{5018 => 0}}}, ~U[2026-10-18 14:00:00Z]) |> Enum.filter(&(&1.kind == "approved_pr_red"))

    assert [%{failure_class: "unknown"}] =
             Checks.all(
               %{pull_requests: [pr], base_checks: [%{name: "test", base_sha: "other-base", conclusion: "success"}], github_cache_ages: %{pull_requests: %{5018 => 0}}},
               ~U[2026-10-18 14:00:00Z]
             )
             |> Enum.filter(&(&1.kind == "approved_pr_red"))

    assert [%{failure_class: "caused_by_pr"}] =
             Checks.all(
               %{pull_requests: [pr], base_checks: [%{name: "test", base_sha: "base-sha", conclusion: "success"}], github_cache_ages: %{pull_requests: %{5018 => 0}}},
               ~U[2026-10-18 14:00:00Z]
             )
             |> Enum.filter(&(&1.kind == "approved_pr_red"))
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
      github_cache_ages: %{pull_requests: %{99 => 0}, merge_group_runs: %{}},
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
