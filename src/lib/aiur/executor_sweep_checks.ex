defmodule Aiur.ExecutorSweep.Checks do
  @moduledoc """
  Builds prioritized Executor sweep findings from already-observed daemon and
  GitHub snapshot data. This module performs no I/O.
  """

  @type finding :: %{kind: String.t(), priority: pos_integer(), action: String.t(), message: String.t()}

  @doc "Runs all pure checks against one local snapshot."
  @spec all(map(), DateTime.t(), keyword()) :: [finding()]
  def all(snapshot, %DateTime{} = now, opts \\ []) do
    (unreviewed_prs(snapshot, now, Keyword.get(opts, :unreviewed_pr_minutes, 10)) ++
       old_decisions(snapshot, now) ++
       approved_prs(snapshot) ++
       merge_queue(snapshot, now, Keyword.get(opts, :merge_group_stale_minutes, 15)) ++
       queue_sets(snapshot) ++
       queue_order(snapshot) ++
       ticket_hygiene(snapshot, now) ++
       rework_hygiene(snapshot) ++
       service_health(snapshot))
    |> Enum.sort_by(&{&1.priority, -Map.get(&1, :age_ms, 0), &1.kind, &1.message})
  end

  @doc "Returns unreviewed human-review PR findings, oldest first."
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

  defp approved_prs(snapshot) do
    snapshot
    |> Map.get(:pull_requests, [])
    |> Enum.flat_map(&approved_pr_findings/1)
  end

  defp approved_pr_findings(pr) do
    failures = Enum.filter(value(pr, :required_checks, []), &red_check?/1)
    approved = approved_current_head?(pr)
    landing = value(pr, :in_merge_queue, false) or value(pr, :auto_merge, false)

    if value(pr, :state, "open") == "open" and approved and (failures != [] or not landing) do
      [approved_pr_finding(pr, failures)]
    else
      []
    end
  end

  defp red_check?(check), do: value(check, :conclusion, nil) in ["failure", "cancelled", "timed_out", "startup_failure"]

  defp approved_current_head?(pr) do
    value(pr, :review_decision, "") == "APPROVED" and
      (is_nil(value(pr, :head_sha, nil)) or value(pr, :approved_head_sha, nil) == value(pr, :head_sha, nil))
  end

  defp approved_pr_finding(pr, failures) do
    red = failures != []
    kind = if red, do: "approved_pr_red", else: "approved_pr_not_landing"
    classifications = Enum.map(failures, &failure_class(&1, value(pr, :failure_class, nil)))
    cause = classifications |> Enum.map(& &1.class) |> Enum.uniq() |> single_or_mixed()
    problem = if red, do: "has a red required check (#{cause})", else: "is not queued or auto-merging"

    finding(kind, 3, 0, "Inspect the check cause or restore merge queue/auto-merge progress.", "Approved PR ##{value(pr, :number, "?")} #{problem}.",
      pull_request: value(pr, :number, nil),
      failure_class: cause,
      failed_checks: classifications
    )
  end

  defp single_or_mixed([single]), do: single
  defp single_or_mixed(_), do: "mixed"

  defp merge_queue(snapshot, now, stale_minutes) do
    unmergeable =
      snapshot
      |> Map.get(:merge_queue, [])
      |> Enum.flat_map(fn entry ->
        if value(entry, :mergeable, "") == "UNMERGEABLE" do
          [
            finding("unmergeable_queue_entry", 4, 0, "Resolve the reported merge conflict or remove the entry from queue.", "PR ##{value(entry, :number, "?")} is UNMERGEABLE in the merge queue.",
              pull_request: value(entry, :number, nil)
            )
          ]
        end
      end)

    stale =
      snapshot
      |> Map.get(:merge_groups, [])
      |> Enum.flat_map(fn group ->
        age = age_ms(date(value(group, :started_at, nil)), now)

        if value(group, :state, "") in ["queued", "in_progress"] and age >= stale_minutes * 60_000 do
          [
            finding(
              "stale_merge_group",
              5,
              age,
              "Inspect the merge-group run and start a fresh required run if needed.",
              "Merge group #{value(group, :name, "?")} is #{value(group, :state, "stale")} for #{duration(age)}.",
              merge_group: value(group, :name, nil)
            )
          ]
        end
      end)

    unmergeable ++ stale
  end

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
    state_labels = ~w(todo in-progress ci-wait human-review rework error done)

    labels_findings =
      snapshot
      |> Map.get(:tickets, [])
      |> Enum.flat_map(fn ticket ->
        states = labels(ticket) |> Enum.filter(&(&1 in state_labels))

        if length(states) == 1 do
          []
        else
          [
            finding("invalid_state_labels", 9, 0, "Leave exactly one agent state label on the ticket.", "Ticket #{value(ticket, :number, "?")} has #{length(states)} agent state labels.",
              ticket: value(ticket, :number, nil),
              state_labels: states
            )
          ]
        end
      end)

    stale_triage =
      snapshot
      |> Map.get(:tickets, [])
      |> Enum.flat_map(fn ticket ->
        age = age_ms(date(value(ticket, :created_at, nil)), now)

        if "needs-triage" in labels(ticket) and age > 60 * 60_000 do
          [finding("stale_needs_triage", 10, age, "Triage the ticket and set its queue state.", "Ticket #{value(ticket, :number, "?")} has needed triage for #{duration(age)}.")]
        else
          []
        end
      end)

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

  defp failure_class(check, explicit) when explicit in ["infra", "pr", "caused_by_pr"] do
    %{name: value(check, :name, "required check"), class: if(explicit == "infra", do: "infra", else: "caused_by_pr")}
  end

  defp failure_class(check, _explicit) do
    conclusion = value(check, :conclusion, nil)
    class = if conclusion in ["cancelled", "timed_out", "startup_failure"], do: "infra", else: "caused_by_pr"
    %{name: value(check, :name, "required check"), class: class}
  end

  defp unreviewed_pr_finding(pr, snapshot, now, threshold_minutes) when is_map(pr) do
    with false <- value(pr, :draft, false),
         "open" <- value(pr, :state, "open"),
         number when is_integer(number) <- value(pr, :issue_number, nil),
         true <- human_review_ticket?(snapshot, number),
         sha when is_binary(sha) and sha != "" <- value(pr, :head_sha, nil),
         reviewed when reviewed != sha <- value(pr, :reviewed_head_sha, nil),
         %DateTime{} = ready_at <- value(pr, :ready_at, nil),
         age_ms when age_ms > threshold_minutes * 60_000 <- DateTime.diff(now, ready_at, :millisecond) do
      [
        %{
          kind: "unreviewed_human_review_pr",
          priority: 1,
          pull_request: value(pr, :number, nil),
          issue_number: number,
          head_sha: sha,
          age_ms: age_ms,
          action: "Review the current PR head or move its ticket out of agent:human-review.",
          message: "PR ##{value(pr, :number, "?")} has waited #{duration(age_ms)} for review at its current head."
        }
      ]
    else
      _not_due -> []
    end
  end

  defp unreviewed_pr_finding(_pr, _snapshot, _now, _threshold_minutes), do: []

  defp human_review_ticket?(snapshot, number) do
    snapshot
    |> Map.get(:tickets, [])
    |> Enum.any?(fn ticket ->
      value(ticket, :number, nil) == number and "human-review" in labels(ticket)
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
  defp age_ms(_, _), do: 0

  defp duration(ms) do
    total_minutes = div(ms, 60_000)
    hours = div(total_minutes, 60)
    minutes = rem(total_minutes, 60)
    if hours > 0, do: "#{hours}h #{minutes}m", else: "#{minutes}m"
  end
end
