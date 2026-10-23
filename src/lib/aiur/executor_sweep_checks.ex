defmodule Aiur.ExecutorSweep.Checks do
  @moduledoc "Builds prioritized Executor sweep findings from observed daemon and GitHub snapshot data."

  alias Aiur.ExecutorSweep.{CacheFreshness, FailureCause, StaleCiWait, StateLabels, TriageBacklog}
  alias Aiur.Instance.SweepFilter

  @type finding :: %{kind: String.t(), priority: pos_integer(), action: String.t(), message: String.t()}

  @doc "Runs pure checks against one snapshot. Nil sources are unknown; a failing check doesn't drop other findings."
  @spec all(map(), DateTime.t(), keyword()) :: [finding()]
  def all(snapshot, %DateTime{} = now, opts \\ []) do
    unreviewed_minutes = Keyword.get(opts, :unreviewed_pr_minutes, 10)
    stale_minutes = Keyword.get(opts, :merge_group_stale_minutes, 15)
    github_freshness_ms = Keyword.get(opts, :github_freshness_ms, 5 * 60_000)
    snapshot = SweepFilter.own(snapshot)

    [
      {"unreviewed_prs", [:pull_requests, :tickets], fn -> unreviewed_prs(snapshot, now, unreviewed_minutes) end},
      {"old_decisions", [:decisions], fn -> old_decisions(snapshot, now) end},
      {"approved_prs", [:pull_requests], fn -> approved_prs(snapshot, github_freshness_ms) end},
      {"conflicting_waiting_prs", [:pull_requests, :tickets], fn -> conflicting_waiting_prs(snapshot) end},
      {"stale_ci_wait_prs", [:pull_requests, :tickets], fn -> stale_ci_wait_prs(snapshot, now) end},
      {"landing_rerun_backlog", [:landing_rerun_backlog], fn -> landing_rerun_backlog(snapshot, now) end},
      {"unmergeable_queue_entries", [:merge_queue], fn -> unmergeable_queue_entries(snapshot) end},
      {"stale_merge_groups", [:merge_groups], fn -> CacheFreshness.stale_merge_groups(snapshot, now, stale_minutes, github_freshness_ms) end},
      {"queue_sets", [:queue_sets, :idle_slots], fn -> queue_sets(snapshot) end},
      {"queue_order", [:queue_order, :feature_order], fn -> queue_order(snapshot) end},
      {"ticket_hygiene", [:tickets, :pull_requests], fn -> ticket_hygiene(snapshot, now) end},
      {"rework_hygiene", [:tickets], fn -> rework_hygiene(snapshot) end},
      {"service_health", [:services], fn -> service_health(snapshot) end}
    ]
    |> Enum.flat_map(fn {check, sources, run} -> run_check(snapshot, check, sources, run) end)
    |> Enum.sort_by(&{&1.priority, -Map.get(&1, :age_ms, 0), &1.kind, &1.message})
  end

  defp run_check(snapshot, check, sources, run) do
    case Enum.filter(sources, &(Map.has_key?(snapshot, &1) and is_nil(Map.get(snapshot, &1)))) do
      [] ->
        run.()

      unknown ->
        [
          finding(
            "sweep_source_unavailable",
            15,
            0,
            "Restore the snapshot source; this check's state is unknown.",
            "Executor sweep check #{check} skipped: #{Enum.join(unknown, ", ")} unavailable.",
            check: check,
            sources: unknown
          )
        ]
    end
  rescue
    error ->
      [
        finding(
          "sweep_check_failed",
          15,
          0,
          "Inspect the daemon log and fix the failing sweep check.",
          "Executor sweep check #{check} failed: #{Exception.format_banner(:error, error, __STACKTRACE__)}",
          check: check
        )
      ]
  end

  @doc "Returns findings for ready PRs unreviewed at their head, whatever their ticket state, oldest first."
  @spec unreviewed_prs(map(), DateTime.t(), pos_integer()) :: [finding()]
  def unreviewed_prs(snapshot, %DateTime{} = now, threshold_minutes) when is_integer(threshold_minutes) and threshold_minutes > 0 do
    snapshot
    |> Map.get(:pull_requests, [])
    |> Enum.flat_map(&unreviewed_pr_finding(&1, snapshot, now, threshold_minutes))
    |> Enum.sort_by(&{-&1.age_ms, &1.message})
  end

  defp old_decisions(snapshot, now) do
    snapshot
    |> Map.get(:decisions, [])
    |> Enum.flat_map(fn decision ->
      created = date(value(decision, :created_at, nil))
      age = age_ms(created, now)

      if value(decision, :blocking, false) and value(decision, :status, "open") in ["open", "deferred"] and age > 15 * 60_000 do
        [
          finding("unanswered_blocking_decision", 2, age, "Answer or resolve the blocking decision.", "Blocking decision #{value(decision, :id, "?")} has been open #{duration(age)}.",
            decision: value(decision, :id, nil)
          )
        ]
      else
        []
      end
    end)
  end

  defp approved_prs(snapshot, max_age_ms) do
    snapshot
    |> Map.get(:pull_requests, [])
    |> Enum.flat_map(fn pr ->
      age = cache_age(snapshot, :pull_requests, value(pr, :number, nil))
      approved_pr_findings(pr, Map.get(snapshot, :base_checks, []), age, max_age_ms)
    end)
  end

  defp conflicting_waiting_prs(snapshot) do
    base_branch = Aiur.Config.base_branch()

    waiting =
      snapshot
      |> Map.get(:tickets, [])
      |> Enum.filter(fn ticket ->
        labels = value(ticket, :labels, [])
        "agent:ci-wait" in labels or "agent:human-review" in labels
      end)
      |> MapSet.new(&value(&1, :number, nil))

    snapshot
    |> Map.get(:pull_requests, [])
    |> Enum.flat_map(fn pr ->
      issue_number = value(pr, :issue_number, nil)

      if issue_number in waiting and value(pr, :state, "") == "open" and value(pr, :mergeable, nil) == "CONFLICTING" do
        [
          finding(
            "conflicting_waiting_pr",
            2,
            0,
            "Merge #{base_branch} into the PR branch and resolve the conflicts.",
            "Ticket ##{issue_number} is waiting while PR ##{value(pr, :number, "?")} is conflicting with #{base_branch}.",
            pull_request: value(pr, :number, nil),
            ticket: issue_number
          )
        ]
      else
        []
      end
    end)
  end

  defp stale_ci_wait_prs(snapshot, now), do: StaleCiWait.findings(snapshot, now)

  defp approved_pr_findings(pr, base_checks, cache_age_ms, max_age_ms) do
    failures = Enum.filter(value(pr, :required_checks, []), &red_check?/1)

    # A cached row can keep "open" after the merge; merged_at is the landing proof (#5119).
    if approved_pr_current_and_open?(pr) and (failures != [] or approved_pr_not_landing?(pr)) do
      [approved_pr_finding(pr, failures, base_checks, cache_age_ms, max_age_ms)]
    else
      []
    end
  end

  defp approved_pr_current_and_open?(pr) do
    value(pr, :state, "open") == "open" and is_nil(value(pr, :merged_at, nil)) and approved_current_head?(pr)
  end

  defp approved_pr_not_landing?(pr) do
    landing = value(pr, :in_merge_queue, false) or value(pr, :auto_merge, false)
    landing_known = value(pr, :landing_state_known?, Map.has_key?(pr, :in_merge_queue) and Map.has_key?(pr, :auto_merge))

    landing_known and not landing and value(pr, :mergeable, nil) != "CONFLICTING"
  end

  defp red_check?(check), do: value(check, :conclusion, nil) in ["failure", "cancelled", "timed_out", "startup_failure"]

  defp approved_current_head?(pr) do
    value(pr, :review_decision, "") == "APPROVED" and
      (is_nil(value(pr, :head_sha, nil)) or value(pr, :approved_head_sha, nil) == value(pr, :head_sha, nil))
  end

  defp approved_pr_finding(pr, failures, base_checks, cache_age_ms, max_age_ms) do
    red = failures != []
    kind = if red, do: "approved_pr_red", else: "approved_pr_not_landing"
    classifications = Enum.map(failures, &FailureCause.classify(&1, value(pr, :base_sha, nil), base_checks))
    cause = classifications |> Enum.map(& &1.class) |> Enum.uniq() |> single_or_mixed()
    problem = if red, do: "has a red required check (#{cause})", else: "is not queued or auto-merging"

    stale? = not fresh_github_age?(cache_age_ms, max_age_ms)
    verification = if stale?, do: "unverified", else: "verified"
    action = if stale?, do: "Verify the PR and its checks in GitHub before taking action.", else: "Inspect the check cause or restore merge queue/auto-merge progress."

    finding(kind, 3, 0, action, "Approved PR ##{value(pr, :number, "?")} #{problem}; #{verification} (GitHub cache age: #{cache_age(cache_age_ms)}).",
      pull_request: value(pr, :number, nil),
      failure_class: cause,
      failed_checks: classifications,
      cache_age_ms: cache_age_ms,
      verification: verification
    )
  end

  # Approved heads whose automatic rerun waits behind the shared 4-per-15-minute cap, or that need a fresh merge ref.
  defp landing_rerun_backlog(snapshot, now) do
    snapshot
    |> Map.get(:landing_rerun_backlog, [])
    |> Enum.map(fn row ->
      since = value(row, :since_ms, nil)
      age = if is_integer(since), do: max(DateTime.to_unix(now, :millisecond) - since, 0), else: 0
      checks = Enum.join(value(row, :checks, []), ", ")
      {pr, reason} = {value(row, :pr, "?"), value(row, :reason, "non-PR failure")}

      {kind, action, message} =
        if value(row, :action, nil) == "refresh" do
          {"approved_pr_refresh_pending", "Wait for the landing watcher's next update-branch slot, or update the branch from the base manually. The push may dismiss the approval.",
           "Approved PR ##{pr} needs a fresh merge ref for #{checks} (#{reason}); waiting #{duration(age)}."}
        else
          {"approved_pr_rerun_pending", "Wait for the landing watcher's next rerun slot, or rerun the failed checks manually.",
           "Approved PR ##{pr} awaits an automatic CI rerun of #{checks} (#{reason}) for #{duration(age)}."}
        end

      finding(
        kind,
        3,
        age,
        action,
        message,
        pull_request: value(row, :pr, nil),
        head_sha: value(row, :head, nil)
      )
    end)
  end

  defp single_or_mixed([single]), do: single
  defp single_or_mixed(_), do: "mixed"

  defp unmergeable_queue_entries(snapshot) do
    snapshot
    |> Map.get(:merge_queue, [])
    |> Enum.flat_map(fn entry ->
      if value(entry, :mergeable, "") == "UNMERGEABLE" do
        [
          finding("unmergeable_queue_entry", 4, 0, "Resolve the reported merge conflict or remove the entry from queue.", "PR ##{value(entry, :number, "?")} is UNMERGEABLE in the merge queue.",
            pull_request: value(entry, :number, nil)
          )
        ]
      else
        []
      end
    end)
  end

  defp cache_age(snapshot, type, subject), do: get_in(snapshot, [:github_cache_ages, type, subject])
  defp fresh_github_age?(age, max_age_ms), do: is_integer(age) and age <= max_age_ms
  defp cache_age(age) when is_integer(age), do: duration(age)
  defp cache_age(_), do: "unknown"

  defp queue_sets(snapshot) do
    slots_idle = value(snapshot, :idle_slots, 0) > 0

    held =
      Enum.flat_map(Map.get(snapshot, :queue_sets, []), fn set ->
        if slots_idle and value(set, :held, false),
          do: [
            finding(
              "held_queue_set_idle_slots",
              6,
              0,
              "Release the hold or fill the idle agent slots.",
              "Queue set #{value(set, :id, "?")} is held while #{value(snapshot, :idle_slots, 0)} slots are idle.",
              queue_set: value(set, :id, nil)
            )
          ],
          else: []
      end)

    focus = value(snapshot, :focus_set, nil)

    focus_findings =
      if is_map(focus) and value(focus, :startable_count, 0) > 0 and value(focus, :claimed_count, 0) == 0 do
        [
          finding("focus_set_unclaimed", 7, 0, "Claim a startable member of the focus set.", "Focus set #{value(focus, :id, "?")} has startable members but none claimed.",
            queue_set: value(focus, :id, nil)
          )
        ]
      else
        []
      end

    held ++ focus_findings
  end

  defp queue_order(snapshot) do
    actual = Map.get(snapshot, :queue_order, [])
    expected = Map.get(snapshot, :feature_order, [])

    if value(snapshot, :queue_order_declared?, false) and actual != [] and expected != [] and actual != expected do
      [finding("queue_order_mismatch", 8, 0, "Reorder the queue to match declared feature order.", "Queue order differs from the declared feature order.", actual: actual, expected: expected)]
    else
      []
    end
  end

  defp ticket_hygiene(snapshot, now) do
    labels_findings =
      snapshot
      |> Map.get(:tickets, [])
      |> Enum.map(&%{number: value(&1, :number, nil), created_at: value(&1, :created_at, nil), labels: labels(&1)})
      |> StateLabels.findings()

    stale_triage =
      stale_triage_finding(Map.get(snapshot, :open_tickets), now)

    open_prs = MapSet.new(snapshot |> Map.get(:pull_requests, []) |> Enum.filter(&(value(&1, :state, "") == "open")) |> Enum.map(&value(&1, :issue_number, nil)))

    error_prs =
      Enum.flat_map(Map.get(snapshot, :tickets, []), fn ticket ->
        if "error" in labels(ticket) and MapSet.member?(open_prs, value(ticket, :number, nil)) do
          [finding("error_ticket_open_pr", 11, 0, "Inspect the ticket error and open PR together.", "Error ticket #{value(ticket, :number, "?")} still has an open PR.")]
        else
          []
        end
      end)

    parked_closed_blocker =
      Enum.flat_map(Map.get(snapshot, :tickets, []), fn ticket ->
        if Enum.any?(labels(ticket), &(&1 in ["paused", "parked"])) and value(ticket, :closed_blockers, []) != [] do
          [finding("parked_ticket_closed_blocker", 10, 0, "Resume or remove the stale blocker from the parked ticket.", "Parked ticket #{value(ticket, :number, "?")} has a blocker that is closed.")]
        else
          []
        end
      end)

    labels_findings ++ stale_triage ++ parked_closed_blocker ++ error_prs
  end

  defp stale_triage_finding(%Aiur.OpenTicketSource.Snapshot{} = snapshot, now) do
    case TriageBacklog.stale_tickets(snapshot, now) do
      [] ->
        []

      [oldest | _] = tickets ->
        age = age_ms(oldest.created_at, now)
        count = if snapshot.truncated?, do: ">=#{length(tickets)}", else: "#{length(tickets)}"

        number =
          case Integer.parse(oldest.identifier) do
            {n, ""} -> n
            _ -> oldest.identifier
          end

        [
          finding(
            "stale_needs_triage",
            10,
            age,
            "Triage the listed tickets and set their queue states.",
            "#{count} open ticket(s) have needed triage for over an hour (oldest ##{oldest.identifier}, #{duration(age)}).",
            ticket: number,
            ticket_count: length(tickets),
            oldest_ticket: number,
            truncated?: snapshot.truncated?
          )
        ]
    end
  end

  defp stale_triage_finding(_snapshot, _now), do: []

  defp rework_hygiene(snapshot) do
    open_blockers =
      Enum.flat_map(Map.get(snapshot, :tickets, []), fn ticket ->
        if "rework" in labels(ticket) and value(ticket, :open_blocked_by, []) != [] do
          [
            finding(
              "rework_ticket_blocked",
              12,
              0,
              "Resolve or remove the open GitHub blocker before continuing rework.",
              "Rework ticket #{value(ticket, :number, "?")} has open blocked_by dependencies."
            )
          ]
        else
          []
        end
      end)

    repeat_handoffs =
      Enum.flat_map(Map.get(snapshot, :tickets, []), fn ticket ->
        if value(ticket, :unchanged_pr_handoffs, 0) > 2 do
          [
            finding(
              "unchanged_pr_handoff_loop",
              13,
              0,
              "Inspect the repeated handoff and identify the missing transition.",
              "Ticket #{value(ticket, :number, "?")} handed back the unchanged PR more than twice."
            )
          ]
        else
          []
        end
      end)

    open_blockers ++ repeat_handoffs
  end

  defp service_health(snapshot) do
    snapshot
    |> Map.get(:services, [])
    |> Enum.flat_map(fn service ->
      if value(service, :status, "up") in ["down", "stalled"] do
        [
          finding("service_unhealthy", 14, 0, "Restore the reported watcher or dispatcher service.", "#{value(service, :name, "Executor service")} is #{value(service, :status, "unavailable")}.",
            service: value(service, :name, nil)
          )
        ]
      else
        []
      end
    end)
  end

  defp finding(kind, priority, age, action, message, extra \\ []) do
    Map.merge(%{kind: kind, priority: priority, age_ms: age, action: action, message: message}, Map.new(extra))
  end

  defp unreviewed_pr_finding(pr, snapshot, now, threshold_minutes) when is_map(pr) do
    with false <- value(pr, :draft, false),
         "open" <- value(pr, :state, "open"),
         number when is_integer(number) <- value(pr, :issue_number, nil),
         sha when is_binary(sha) and sha != "" <- value(pr, :head_sha, nil),
         reviewed when reviewed != sha <- value(pr, :reviewed_head_sha, nil),
         %DateTime{} = ready_at <- value(pr, :ready_at, nil),
         age_ms when age_ms > threshold_minutes * 60_000 <- DateTime.diff(now, ready_at, :millisecond) do
      state = ticket_state(snapshot, number)

      [
        %{
          kind: "unreviewed_pr",
          priority: 1,
          pull_request: value(pr, :number, nil),
          issue_number: number,
          ticket_state: state,
          head_sha: sha,
          age_ms: age_ms,
          action: unreviewed_pr_action(state),
          message: "PR ##{value(pr, :number, "?")} (ticket ##{number}, agent:#{state}) has waited #{duration(age_ms)} for review at its current head."
        }
      ]
    else
      _not_due -> []
    end
  end

  defp unreviewed_pr_finding(_pr, _snapshot, _now, _threshold_minutes), do: []

  defp unreviewed_pr_action("human-review"), do: "Review the current PR head or move its ticket out of agent:human-review."

  defp unreviewed_pr_action(state),
    do: "Review the current PR head, or have the agent:#{state} ticket hand off or return its PR to draft."

  @ticket_states ~w(todo in-progress ci-wait human-review rework merging done cancelled canceled error)

  defp ticket_state(snapshot, number) do
    snapshot
    |> Map.get(:tickets, [])
    |> Enum.find_value("unknown", fn ticket ->
      value(ticket, :number, nil) == number and Enum.find(labels(ticket), "unknown", &(&1 in @ticket_states))
    end)
  end

  defp labels(ticket) do
    ticket
    |> value(:labels, [])
    |> Enum.map(fn label ->
      if is_map(label), do: value(label, :name, ""), else: label
    end)
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim_leading(&1, "agent:"))
  end

  defp value(map, key, default) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp date(%DateTime{} = datetime), do: datetime
  # MainWatch run timestamps are Unix milliseconds.
  defp date(ms) when is_integer(ms), do: DateTime.from_unix!(ms, :millisecond)

  defp date(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp date(_), do: nil

  defp age_ms(%DateTime{} = timestamp, %DateTime{} = now), do: max(DateTime.diff(now, timestamp, :millisecond), 0)
  defp age_ms(_, _), do: nil

  defp duration(ms) do
    total_minutes = div(ms, 60_000)
    hours = div(total_minutes, 60)
    minutes = rem(total_minutes, 60)
    if hours > 0, do: "#{hours}h #{minutes}m", else: "#{minutes}m"
  end
end
