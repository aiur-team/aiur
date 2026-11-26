defmodule Aiur.TicketReopen do
  @moduledoc """
  `aiur ticket reopen`: reopens a closed ticket and restores the Build Order links Aiur recorded for it.

  Closing a ticket keeps its feature membership and its native `blocked_by` edges, but two links
  can still be lost. A completed build-queue item loses its `<prefix>:queued` marker, so once it is
  open again the queue planner would dequeue it, dropping its position and its queue edges. An
  agent's `aiur_unblock` can also have removed a native edge the Build Order graph still records.
  Reopen re-marks the item before the issue opens, which puts the planner's list, feature and epic
  edges back in force, then re-declares only Build Order graph edges whose native GitHub edge is
  missing, so open dependents are held behind it again. Planner edges are never written to GitHub:
  they belong to the queue, and `queue reorder` / `queue remove` must still be able to drop them.

  Reopen refuses before any write when the queue read model is unavailable or stale (the planner
  would dequeue the unmarked item) and when the ticket was never in a Build Order.
  The reason is posted on the issue and raised as an Executor attention.
  """

  alias Aiur.BuildOrder.Features
  alias Aiur.BuildQueue
  alias Aiur.GitHub.Config
  alias Aiur.GitHub.IssueDependencies
  alias Aiur.Orchestrator.TicketTransition
  alias Aiur.Signal

  @states ~w(todo rework)
  @options [:id, :reason, :state, :by, :json, :error_fun, :tracker, :queue_fun, :feature_fun, :declare_fun, :alert_fun, :label_prefix]

  @spec run(keyword()) :: 0 | 1
  def run(opts) do
    error_fun = Keyword.get(opts, :error_fun, &IO.puts(:stderr, &1))

    case reopen(opts) do
      {:ok, result} ->
        if opts[:json], do: IO.puts(Jason.encode!(Aiur.JSONSafe.normalize(result))), else: IO.puts(human(result))
        0

      {:error, reason} ->
        error_fun.("aiur: #{error(reason, opts[:id])}")
        1
    end
  end

  @doc "Reopens the ticket and returns what was restored; never touches an open ticket."
  @spec reopen(keyword()) :: {:ok, map()} | {:error, term()}
  def reopen(opts) do
    tracker = Keyword.get(opts, :tracker, Aiur.Tracker)

    with {:ok, request} <- request(opts),
         id = Integer.to_string(request.id),
         :ok <- closed(tracker, id),
         {:ok, model} <- usable(Keyword.get(opts, :queue_fun, &BuildQueue.show/0).()),
         {placement, edges} = recorded(id, model),
         feature = feature(request.id, placement, opts),
         :ok <- member(placement, feature, edges),
         :ok <- step(:queue_marker, mark_queued(placement, id, tracker, opts)),
         :ok <- step(:reopen, tracker.reopen_issue(id)),
         :ok <- step(:state, TicketTransition.write_state(id, request.state, writer: :ticket_reopen, tracker: tracker)),
         :ok <- step(:comment, tracker.create_comment(id, comment(request))) do
      declare = Keyword.get(opts, :declare_fun, &IssueDependencies.declare/2)
      links = Enum.map(edges, &restore(&1, id, tracker, declare))
      result = %{id: request.id, state: request.state, reason: request.reason, feature: feature, queue: placement, links: links}
      alert(result, Keyword.get(opts, :alert_fun, &Signal.alert/2))
      {:ok, result}
    end
  end

  defp request(opts) do
    state = Keyword.get(opts, :state, "todo")
    reason = opts[:reason]

    cond do
      Keyword.keys(opts) -- @options != [] -> {:error, :unknown_option}
      not (is_integer(opts[:id]) and opts[:id] > 0) -> {:error, :invalid_id}
      state not in @states -> {:error, :invalid_state}
      not valid_reason?(reason) -> {:error, :invalid_reason}
      true -> {:ok, %{id: opts[:id], state: state, reason: reason, by: Keyword.get(opts, :by, "cli:#{System.get_env("USER", "unknown")}")}}
    end
  end

  defp valid_reason?(reason), do: is_binary(reason) and String.trim(reason) != "" and String.length(reason) <= 500 and not String.match?(reason, ~r/[[:cntrl:]]/u)

  defp closed(tracker, id) do
    case tracker.issue_closure(id, 1) do
      {:ok, %{open?: false}} -> :ok
      {:ok, %{open?: true}} -> {:error, :already_open}
      {:error, reason} -> {:error, {:closure, reason}}
    end
  end

  # Without a current read model the item looks unqueued, and reopen would skip its marker.
  defp usable(%{status: :running, sources: %{"tracker_observation" => %{freshness: :current}}} = model), do: {:ok, model}
  defp usable(_model), do: {:error, :queue_unavailable}

  defp member(nil, nil, []), do: {:error, :not_in_build_order}
  defp member(_placement, _feature, _edges), do: :ok

  # The queue read model carries Aiur's recorded edges beside the native ones it mirrors.
  defp recorded(id, model) do
    queues = Map.get(model, :queues, [])

    placement =
      Enum.find_value(queues, fn queue ->
        item = Enum.find(queue.items, &(to_string(&1.number) == id))
        item && %{queue: queue.queue_id, feature: queue.feature, epic: queue.epic, position: item.position}
      end)

    edges =
      for queue <- queues, edge <- queue.edges, edge.source != :native, id in [edge.prerequisite, edge.dependent], uniq: true do
        {edge.prerequisite, edge.dependent, edge.source}
      end

    {placement, edges}
  end

  defp mark_queued(nil, _id, _tracker, _opts), do: :ok

  defp mark_queued(_placement, id, tracker, opts) do
    prefix = Keyword.get_lazy(opts, :label_prefix, &Config.label_prefix/0)
    TicketTransition.write_marker(id, :add, "#{prefix}:queued", writer: :ticket_reopen, tracker: tracker)
  end

  defp step(_name, :ok), do: :ok
  defp step(name, {:error, reason}), do: {:error, {name, reason}}

  defp comment(request) do
    "Reopened as `#{request.state}` by `aiur ticket reopen` (#{request.by}).\n\nReason: #{request.reason}"
  end

  # List, feature and epic edges are the planner's own; the restored queue marker holds them.
  defp restore({prerequisite, dependent, source}, _id, _tracker, _declare) when source != :build_order,
    do: %{prerequisite: prerequisite, dependent: dependent, outcome: :held_by_queue}

  defp restore({prerequisite, dependent, :build_order}, id, tracker, declare) do
    other = if prerequisite == id, do: dependent, else: prerequisite
    link = %{prerequisite: prerequisite, dependent: dependent}

    Map.put(link, :outcome, outcome(tracker.issue_closure(other, 1), tracker.blocked_by(dependent), prerequisite, dependent, declare))
  end

  defp outcome({:ok, %{open?: false}}, _blockers, _prerequisite, _dependent, _declare), do: :other_closed

  defp outcome({:ok, %{open?: true}}, {:ok, blockers}, prerequisite, dependent, declare) do
    if prerequisite in blockers, do: :present, else: declared(declare.(dependent, prerequisite))
  end

  defp outcome({:error, reason}, _blockers, _prerequisite, _dependent, _declare), do: {:unknown, reason}
  defp outcome(_closure, {:error, reason}, _prerequisite, _dependent, _declare), do: {:unknown, reason}

  defp declared({:ok, _}), do: :restored
  defp declared({:error, reason}), do: {:failed, reason}

  defp feature(id, placement, opts) do
    case Keyword.get(opts, :feature_fun, &Features.owner/1).(id) do
      {:ok, %{feature: slug}} -> slug
      _none -> placement && placement.feature
    end
  end

  defp alert(result, alert_fun) do
    alert_fun.("ticket.#{result.id}.agent.attention.reopened",
      issue: "#{result.id}",
      message: "Ticket ##{result.id} was reopened as #{result.state}",
      reason: "Reason: #{result.reason}. #{links_line(result.links)} Re-plan the ticket and check any dependent that already started.",
      needs_attention: true,
      severity: "info"
    )
  end

  defp links_line([]), do: "No recorded Build Order links."
  defp links_line(links), do: "Links: " <> Enum.map_join(links, ", ", &"##{&1.prerequisite} -> ##{&1.dependent} #{label(&1.outcome)}") <> "."

  defp label({kind, reason}), do: "#{kind} (#{inspect(reason)})"
  defp label(outcome), do: Atom.to_string(outcome)

  defp human(result) do
    queue = if q = result.queue, do: "queue #{q.queue} position #{inspect(q.position)}", else: "not in a build queue"

    Enum.join(
      ["Reopened ##{result.id} as #{result.state}.", "Feature: #{result.feature || "none"}; #{queue}."] ++
        Enum.map(result.links, &"  ##{&1.prerequisite} -> ##{&1.dependent}: #{label(&1.outcome)}"),
      "\n"
    )
  end

  defp error(:already_open, id), do: "ticket ##{id} is already open; reopen only applies to a closed ticket"
  defp error(:queue_unavailable, _id), do: "build queue unavailable; retry"
  defp error(:not_in_build_order, id), do: "ticket ##{id} was never in a Build Order; reopen it with gh issue reopen"
  defp error(:invalid_reason, _id), do: "--reason requires 1..500 characters without controls"
  defp error(:invalid_state, _id), do: "--state must be todo or rework"
  defp error(:invalid_id, _id), do: "ticket reopen expects a positive numeric id"
  defp error({:closure, reason}, id), do: "could not read whether ticket ##{id} is closed: #{inspect(reason)}"
  defp error({step, reason}, id), do: "reopen of ##{id} stopped at #{step}: #{inspect(reason)}; nothing after it ran"
  defp error(reason, _id), do: inspect(reason)
end
