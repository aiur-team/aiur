defmodule Aiur.ExecutorSweep.SnapshotCache do
  @moduledoc "Reads the current repository's already-cached GitHub resources."

  alias Aiur.GitHub.{Config, ResourceStore}

  @spec read((-> Aiur.OpenTicketSource.Snapshot.t())) :: map()
  def read(open_ticket_snapshot \\ &Aiur.OpenTicketSource.snapshot/0) do
    with repo when is_binary(repo) <- Config.repo(),
         [owner, name] <- String.split(repo, "/", parts: 2) do
      pull_requests = entries(:pull_request, owner, name)
      branch_pull_requests = entries(:branch_pull_request, owner, name)
      reviews = entries(:pull_request_reviews, owner, name)
      tickets = open_tickets(open_ticket_snapshot)
      issues = Map.new(entries(:issue, owner, name))
      blocked_by = Map.new(entries(:issue_blocked_by, owner, name))
      timelines = Map.new(entries(:issue_timeline, owner, name))
      snapshot = build(pull_requests, reviews, tickets, issues, blocked_by, branch_pull_requests, timelines)
      local = local_snapshot()

      snapshot =
        snapshot
        |> Map.merge(local)
        |> Map.update!(:tickets, &(&1 && attach_rework_attempts(&1, snapshot.pull_requests, local.rework_attempts)))

      pull_requests = Enum.map(snapshot.pull_requests, &attach_ci(&1, local.ci_wait))

      snapshot
      |> Map.put(:pull_requests, pull_requests)
      |> Map.put(:merge_queue, merge_queue_entries(pull_requests))
    else
      _ -> Map.merge(%{pull_requests: [], tickets: []}, local_snapshot())
    end
  end

  # The store keeps label rows for closed issues and merged PRs, so ticket checks
  # read the open-ticket projection, which excludes both. Before a full listing
  # the projection is partial, so tickets read as unknown (nil), not as none.
  @doc false
  @spec open_tickets((-> Aiur.OpenTicketSource.Snapshot.t())) :: [{integer(), [String.t()]}] | nil
  def open_tickets(snapshot_fun \\ &Aiur.OpenTicketSource.snapshot/0) do
    case snapshot_fun.() do
      %{status: :available, tickets: tickets} -> for %{identifier: identifier, labels: labels} <- tickets, {number, ""} <- [Integer.parse(identifier)], do: {number, labels}
      _not_listed -> nil
    end
  catch
    :exit, _reason -> nil
  end

  defp local_snapshot do
    decisions =
      Enum.map(list_decisions(), fn decision ->
        %{id: decision.decision_id, blocking: decision.blocking, status: Atom.to_string(decision.decision_status), created_at: decision.created_at}
      end)

    queue = Aiur.BuildQueue.show()
    {fleet, dispatcher_service} = fleet_snapshot()
    queues = Map.get(queue, :queues, [])
    focus = focus_queue(queues, fleet)
    order = Map.get(queue, :order, %{})
    declared_order = value(order, :declared, nil)
    actual_order = value(order, :actual, [])
    declared_order? = is_list(declared_order) and value(order, :source, :none) != :none
    main_watch = if Aiur.MainWatch.enabled?(), do: safe_state(&Aiur.MainWatch.state/0), else: %{}

    %{
      decisions: decisions,
      open_tickets: Aiur.OpenTicketSource.snapshot(),
      queue_sets: Enum.map(queues, &%{id: &1.queue_id, held: &1.held}),
      idle_slots: idle_slots(fleet),
      focus_set: focus,
      queue_order: actual_order,
      feature_order: if(declared_order?, do: declared_order, else: []),
      queue_order_declared?: declared_order?,
      merge_groups:
        Enum.map(value(main_watch, :merge_groups, []), fn run ->
          %{name: "run #{value(run, :id, "?")}", state: value(run, :status, "unknown"), started_at: value(run, :started_at, nil)}
        end),
      ci_wait: Map.get(fleet, :ci_wait, []),
      rework_attempts: Map.get(fleet, :rework_attempts, []),
      landing_rerun_backlog: landing_rerun_backlog(safe_state(&Aiur.LandingWatch.state/0)),
      services: watcher_services() ++ List.wrap(dispatcher_service)
    }
  rescue
    _ -> %{decisions: [], queue_sets: [], idle_slots: 0, focus_set: nil, ci_wait: [], rework_attempts: [], services: []}
  end

  # A running watcher whose journal read failed is unknown (nil); no watcher has no backlog.
  @doc false
  @spec landing_rerun_backlog(map()) :: [map()] | nil
  def landing_rerun_backlog(%{rerun_backlog: {:ok, rows}}), do: rows
  def landing_rerun_backlog(%{rerun_backlog: {:error, _}}), do: nil
  def landing_rerun_backlog(_state), do: []

  defp list_decisions do
    Aiur.Commands.list_decisions()
  catch
    :exit, _ -> []
  end

  @doc false
  @spec attach_rework_attempts([map()], [map()], [map()]) :: [map()]
  def attach_rework_attempts(tickets, pull_requests, attempts) do
    Enum.map(tickets, fn ticket ->
      Map.put(ticket, :unchanged_pr_handoffs, attempt_count(ticket.number, pull_requests, attempts))
    end)
  end

  defp attempt_count(ticket_number, pull_requests, attempts) do
    case Enum.find(pull_requests, &(&1.issue_number == ticket_number and &1.state == "open")) do
      %{head_sha: head_sha} when is_binary(head_sha) -> find_attempt_count(attempts, to_string(ticket_number), head_sha)
      _ -> 0
    end
  end

  defp find_attempt_count(attempts, ticket_number, head_sha) do
    case Enum.find(attempts, &(Map.get(&1, :issue_id, Map.get(&1, "issue_id")) == ticket_number and Map.get(&1, :head_sha, Map.get(&1, "head_sha")) == head_sha)) do
      nil -> 0
      attempt -> Map.get(attempt, :count, Map.get(attempt, "count", 0))
    end
  end

  defp fleet_snapshot do
    case Aiur.Orchestrator.fleet_view(Aiur.Orchestrator, 2_000) do
      {:ok, snapshot, _freshness} -> {snapshot, nil}
      _ -> {%{}, %{name: "dispatcher", status: "stalled"}}
    end
  catch
    :exit, _ -> {%{}, %{name: "dispatcher", status: "stalled"}}
  end

  defp watcher_services do
    ([watcher_service("landing watcher", safe_state(&Aiur.LandingWatch.state/0))] ++
       if(Aiur.MainWatch.enabled?(), do: [watcher_service("default-branch watcher", safe_state(&Aiur.MainWatch.state/0))], else: []))
    |> Enum.reject(&is_nil/1)
  rescue
    _ -> []
  end

  defp safe_state(fun) do
    fun.()
  rescue
    _ -> %{watcher: :unavailable}
  catch
    :exit, _ -> %{watcher: :unavailable}
  end

  defp watcher_service(name, %{watcher: :running} = state) do
    cond do
      not is_nil(value(state, :last_error, nil)) -> %{name: name, status: "down"}
      is_integer(value(state, :last_poll_at_ms, nil)) and System.system_time(:millisecond) - value(state, :last_poll_at_ms, 0) > 15 * 60_000 -> %{name: name, status: "stalled"}
      true -> nil
    end
  end

  defp watcher_service(name, %{watcher: status}) when status in [:unavailable, :not_running], do: %{name: name, status: "down"}
  defp watcher_service(name, _), do: %{name: name, status: "down"}

  defp idle_slots(%{capacity: capacity, running: running}) when is_integer(capacity) and is_list(running),
    do: max(capacity - length(running), 0)

  defp idle_slots(_), do: 0

  defp focus_queue([], _fleet), do: nil

  defp focus_queue(queues, fleet) do
    queue = Enum.min_by(queues, &Map.get(&1, :set_rank, 0))
    claimed = fleet |> Map.get(:running, []) |> Enum.map(&value(&1, :identifier, nil)) |> MapSet.new()
    startable = Enum.filter(queue.items, &(value(&1, :state, nil) in [:ready, :promoted, :overridden] and value(&1, :verdict, nil) == :ready))

    %{
      id: queue.queue_id,
      startable_count: length(startable),
      claimed_count: Enum.count(startable, &MapSet.member?(claimed, to_string(value(&1, :number, ""))))
    }
  end

  defp attach_ci(pr, ci_wait) do
    case Enum.find(ci_wait, fn ci ->
           (value(ci, :pr_number, nil) == pr.number or value(ci, :identifier, nil) == to_string(pr.issue_number)) and
             value(ci, :head_sha, nil) == pr.head_sha
         end) do
      nil ->
        pr

      ci ->
        failures = value(ci, :failures, [])
        required = Enum.map(failures, &%{name: value(&1, :name, "required check"), conclusion: value(&1, :result, value(&1, :conclusion, nil))})
        Map.merge(pr, %{required_checks: required, failure_class: to_string(value(ci, :failure_class, "unknown"))})
    end
  end

  defp merge_queue_entries(pull_requests) do
    pull_requests
    |> Enum.filter(& &1.in_merge_queue)
    |> Enum.map(fn pr -> %{number: pr.number, mergeable: if(pr.mergeable == "CONFLICTING", do: "UNMERGEABLE", else: pr.mergeable)} end)
  end

  @doc false
  @spec build([{integer(), map()}], [{integer(), list()}], [{integer(), list()}] | nil, map(), map(), [{integer(), map()}], map()) :: map()
  def build(pull_requests, reviews, tickets, issues \\ %{}, blocked_by \\ %{}, branch_pull_requests \\ [], timelines \\ %{}) do
    reviews = Map.new(reviews)
    branch_prs = Map.new(branch_pull_requests)
    pull_requests = merge_pr_sources(pull_requests, branch_pull_requests)

    pull_requests =
      Enum.map(pull_requests, &normalize_snapshot_pr(&1, reviews, branch_prs, timelines))
      |> Enum.reject(&is_nil/1)

    %{
      pull_requests: pull_requests,
      merge_queue: merge_queue_entries(pull_requests),
      tickets: tickets && Enum.map(tickets, &normalize_ticket(&1, issues, blocked_by))
    }
  end

  defp normalize_ticket({number, labels}, issues, blocked_by) do
    issue = Map.get(issues, number, %{})
    blockers = Map.get(blocked_by, number, [])
    blockers = if is_list(blockers), do: blockers, else: []
    closed? = fn blocker -> value(Map.get(issues, value(blocker, "number", nil), %{}), "state", "") == "closed" end

    %{
      number: number,
      labels: labels,
      created_at: value(issue, "created_at", nil),
      open_blocked_by: Enum.reject(blockers, closed?),
      closed_blockers: blockers |> Enum.filter(closed?) |> Enum.map(&value(&1, "number", nil))
    }
  end

  defp merge_pr_sources(pull_requests, branch_pull_requests) do
    direct = Map.new(pull_requests)

    Enum.reduce(branch_pull_requests, direct, fn {_ticket, pr}, acc ->
      case positive_number(value(pr, "number", nil)) do
        nil -> acc
        number -> Map.update(acc, number, pr, &Map.merge(&1, pr))
      end
    end)
    |> Enum.to_list()
  end

  defp normalize_snapshot_pr({number, pr}, reviews, branch_prs, timelines) do
    case normalize_pr(number, pr, reviews) do
      nil ->
        nil

      normalized ->
        case Map.get(branch_prs, normalized.issue_number) do
          nil -> normalized
          branch_pr -> attach_branch_metadata(normalized, branch_pr, Map.get(timelines, number))
        end
    end
  end

  defp attach_branch_metadata(normalized, branch_pr, timeline) do
    metadata = normalize_branch_metadata(branch_pr) |> Enum.reject(fn {_key, value} -> is_nil(value) end) |> Map.new()
    normalized = Map.merge(normalized, metadata)
    Map.put(normalized, :ready_at, timeline_ready_at(timeline, normalized))
  end

  defp positive_number(number) when is_integer(number) and number > 0, do: number

  defp positive_number(number) when is_binary(number) do
    case Integer.parse(number) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> nil
    end
  end

  defp positive_number(_), do: nil

  defp normalize_branch_metadata(pr) do
    merge_queue = value(pr, "mergeQueueEntry", nil)
    auto_merge = value(pr, "autoMergeRequest", false)

    %{
      review_decision: value(pr, "review_decision", nil),
      approved_head_sha: value(pr, "approved_head_sha", nil),
      reviewed_head_sha: value(pr, "reviewed_head_sha", nil),
      in_merge_queue: not is_nil(merge_queue),
      auto_merge: auto_merge not in [nil, false],
      mergeable: value(pr, "mergeable", nil),
      ready_at: timestamp(value(pr, "ready_for_review_at", nil)) || timestamp(value(pr, "created_at", nil))
    }
  end

  defp timeline_ready_at(%{"events" => events}, pr) when is_list(events) do
    events
    |> Enum.filter(&(value(&1, "event", "") == "ready_for_review"))
    |> Enum.max_by(&value(&1, "created_at", ""), fn -> nil end)
    |> case do
      %{} = event -> timestamp(value(event, "created_at", nil))
      nil -> pr.ready_at
    end
  end

  defp timeline_ready_at(_timeline, pr), do: pr.ready_at

  @spec entries(atom(), String.t(), String.t()) :: [{integer(), map()}]
  defp entries(type, owner, repo) do
    type
    |> ResourceStore.list(owner, repo)
    |> Enum.flat_map(fn {{^type, _owner, _repo, id}, %{data: data}} ->
      case Integer.parse(to_string(id)) do
        {number, ""} when is_map(data) or is_list(data) -> [{number, data}]
        _ -> []
      end
    end)
  end

  defp normalize_pr(number, pr, reviews) when is_map(pr) do
    head = value(pr, "head", %{})
    sha = value(head, "sha", nil)
    branch = value(head, "ref", "")
    issue_number = issue_number(branch)
    review_rows = Map.get(reviews, number, [])
    reviewed = Enum.any?(review_rows, &(value(&1, "commit_id", nil) == sha))
    approved = Enum.any?(review_rows, &(value(&1, "commit_id", nil) == sha and value(&1, "state", "") == "APPROVED"))

    %{
      number: number,
      issue_number: issue_number,
      state: value(pr, "state", "closed"),
      draft: value(pr, "draft", false),
      head_sha: sha,
      reviewed_head_sha: if(reviewed, do: sha),
      approved_head_sha: value(pr, "approved_head_sha", nil) || if(approved, do: sha),
      ready_at: timestamp(value(pr, "ready_for_review_at", nil)) || timestamp(value(pr, "created_at", nil)),
      review_decision: value(pr, "review_decision", nil) || if(approved, do: "APPROVED", else: ""),
      in_merge_queue: not is_nil(value(pr, "mergeQueueEntry", value(pr, "merge_queue_entry", nil))),
      auto_merge: value(pr, "autoMergeRequest", value(pr, "auto_merge", false)) not in [nil, false],
      required_checks: value(pr, "required_checks", []),
      mergeable: value(pr, "mergeable", nil),
      failure_class: value(pr, "failure_class", "unknown")
    }
  end

  defp normalize_pr(_number, _pr, _reviews), do: nil

  defp issue_number(branch) do
    case Regex.run(~r/(?:^|\/)aiur\/(\d+)(?:-|$)/, branch) do
      [_, number] -> String.to_integer(number)
      _ -> nil
    end
  end

  defp timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp timestamp(_), do: nil

  # Cached GitHub rows use string keys and local state uses atom keys; accept either spelling.
  defp value(map, key, default) when is_map(map), do: Map.get(map, key, Map.get(map, other_key(key), default))
  defp value(_map, _key, default), do: default

  defp other_key(key) when is_atom(key), do: Atom.to_string(key)
  defp other_key(key) when is_binary(key), do: String.to_atom(key)
end
