defmodule AiurWeb.Build.Timeline do
  @moduledoc "Builds the ticket timeline from durable per-ticket event markers."

  alias Aiur.BuildOrder.TicketTimelineProvider
  alias Aiur.TrackerIdentity

  @page_size 200

  @spec read(TrackerIdentity.t(), non_neg_integer(), keyword()) :: {:ok, map()} | {:error, term()}
  def read(identity, after_id \\ 0, opts \\ [])

  def read(%TrackerIdentity{} = identity, after_id, opts) when is_integer(after_id) and after_id >= 0 do
    read_fun = Keyword.get(opts, :read_fun, &TicketTimelineProvider.read_page/2)
    read_history(identity, after_id, read_fun)
  end

  def read(_identity, _after_id, _opts), do: {:error, :invalid_identity}

  @spec present(TrackerIdentity.t(), [map()]) :: map()
  def present(identity, events) do
    items =
      events
      |> Enum.flat_map(&item(identity, &1))
      |> Enum.sort_by(&{&1.at, &1.id, &1.kind})
      |> number_rework_rounds()

    %{items: pair_consumes(items), high_water: Enum.reduce(events, 0, &max(&2, event_id(&1))), phases: phases(items), progress: progress(items), truncated: false}
  end

  @spec append_cache(map(), [map()]) :: map()
  def append_cache(%{events: cached, high_water: high_water}, incoming) when is_list(cached) and is_integer(high_water) do
    appended = Enum.filter(incoming, &(event_id(&1) > high_water))
    events = Enum.uniq_by(cached ++ appended, &event_id/1)
    %{events: events, appended: appended, high_water: Enum.reduce(events, high_water, &max(&2, event_id(&1)))}
  end

  def append_cache(_cache, incoming) when is_list(incoming), do: append_cache(%{events: [], high_water: 0}, incoming)

  defp read_history(identity, after_id, read_fun) do
    read_pages(identity, after_id, read_fun, [])
  end

  defp read_pages(identity, after_id, read_fun, accumulated) do
    case read_fun.(identity, after_id: after_id, kinds: [:emit, :emit_alert, :consumed, :self, :command], limit: @page_size) do
      {:ok, %{events: events, high_water: high_water, has_more: has_more}} when is_list(events) ->
        pages = accumulated ++ events

        if has_more and high_water > after_id do
          read_pages(identity, high_water, read_fun, pages)
        else
          {:ok, %{events: pages, high_water: high_water, truncated: false}}
        end

      {:ok, events} when is_list(events) ->
        {:ok, %{events: accumulated ++ events, truncated: length(events) == @page_size}}

      events when is_list(events) ->
        {:ok, %{events: accumulated ++ events, truncated: length(events) == @page_size}}

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, :unavailable}
    end
  end

  defp item(identity, event) do
    with true <- String.starts_with?(event.topic || "", "ticket.#{identity.identifier}."),
         {:ok, at, _offset} <- DateTime.from_iso8601(event.ts),
         actor when not is_nil(actor) <- actor(event),
         {:ok, kind, extra} <- classify(event) do
      label = label(event)
      base = %{id: event.id, at: DateTime.to_unix(at, :millisecond), actor: actor, kind: kind, label: label, topic: event.topic}
      event_items(base, extra)
    else
      _ -> []
    end
  end

  defp event_items(base, %{status: :ci_failure, checks: [_ | _] = checks}) do
    Enum.map(checks, fn check ->
      base
      |> Map.put(:label, "#{check.name} failed")
      |> Map.put(:status, :ci_failure)
      |> Map.put(:run_url, check[:url])
    end)
  end

  defp event_items(base, extra), do: [Map.merge(base, extra)]

  defp actor(%{actor: actor}) when actor in ["Executor", "CI", "Aiur agent", "Aiur daemon"], do: actor

  defp actor(%{kind: "consumed", topic: "ticket." <> rest}) do
    case String.split(rest, ".", parts: 2) do
      [_id, "operator." <> _] -> "Aiur agent"
      [_id, "agent." <> _] -> "Aiur daemon"
      [_id, "pr." <> _] -> "Executor"
      _ -> "Aiur daemon"
    end
  end

  defp actor(%{topic: "ticket." <> rest}) do
    case String.split(rest, ".", parts: 2) do
      [_id, "agent." <> _] -> "Aiur agent"
      [_id, "ci." <> _] -> "CI"
      [_id, suffix] when suffix in ["pr.merged", "pr.review_comment", "issue.commented"] -> "Executor"
      [_id, suffix] when suffix in ["issue.label.added.agent.human-review", "issue.label.added.agent.rework", "issue.label.added.agent.ci-wait"] -> "Executor"
      [_id, suffix] when suffix in ["pr.opened", "pr.ready_for_review"] -> "Aiur agent"
      _ -> "Aiur daemon"
    end
  end

  defp actor(_), do: nil

  defp classify(%{kind: "consumed"}), do: {:ok, :consume, %{}}

  defp classify(%{topic: topic} = event) do
    cond do
      String.ends_with?(topic, ".progress") or String.ends_with?(topic, ".progress.checkin") ->
        value = Map.get(event, :percent) || percent(event.summary)
        {:ok, :emit, Map.merge(%{status: :progress}, if(is_integer(value), do: %{percent: value}, else: %{}))}

      String.contains?(topic, ".agent.phase.") ->
        {:ok, :emit, %{status: :phase}}

      true ->
        classify_topic(topic, event)
    end
  end

  defp classify_topic(topic, event) do
    suffix = topic |> String.split(".") |> Enum.drop(2) |> Enum.join(".")

    [rework_class(suffix, event), ci_class(suffix, event), failure_class(suffix, event), orchestration_class(suffix)]
    |> Enum.find(& &1)
    |> case do
      nil -> {:ok, event_kind(event.kind), %{}}
      classification -> classification
    end
  end

  defp rework_class(suffix, event) do
    if suffix in ["pr.review_comment", "agent.rework"] and changes_requested?(event), do: {:ok, :emit, %{status: :rework}}
  end

  defp ci_class(suffix, event) do
    if String.starts_with?(suffix, "ci.") and ci_failure?(event), do: {:ok, :emit, %{status: :ci_failure, checks: event[:ci_checks] || []}}
  end

  defp failure_class(suffix, event) do
    cond do
      String.contains?(suffix, "merge_group") and failure?(event) -> {:ok, :emit, %{status: :merge_group_failure, run_url: event[:run_url] || event[:url]}}
      String.contains?(suffix, "retry_exhausted") or String.contains?(suffix, "error-retry_exhausted") -> {:ok, :emit, %{status: :retry_exhausted}}
      String.contains?(suffix, "paused") -> {:ok, :emit, %{status: :pause}}
      true -> nil
    end
  end

  defp orchestration_class(suffix) do
    cond do
      dispatch_decline?(suffix) -> {:ok, :emit, %{status: :dispatch_decline}}
      budget_hold?(suffix) -> {:ok, :emit, %{status: :budget_hold}}
      capacity_wait?(suffix) -> {:ok, :emit, %{status: :capacity_wait}}
      label_transition?(suffix) -> {:ok, :emit, %{status: :label_transition}}
      lifecycle_change?(suffix) -> {:ok, :emit, %{status: :lifecycle}}
      true -> nil
    end
  end

  defp dispatch_decline?(suffix), do: String.contains?(suffix, "dispatch-declined") or String.contains?(suffix, "dispatch_declined")
  defp budget_hold?(suffix), do: String.contains?(suffix, "budget-hold") or String.contains?(suffix, "github-budget.wait")
  defp capacity_wait?(suffix), do: String.contains?(suffix, "capacity-wait") or String.contains?(suffix, "capacity_wait")
  defp label_transition?(suffix), do: String.starts_with?(suffix, "issue.label.")
  defp lifecycle_change?(suffix), do: String.ends_with?(suffix, "lifecycle.changed")

  defp changes_requested?(event), do: String.contains?(String.downcase(event[:summary] || ""), "changes requested")
  defp ci_failure?(event), do: failure?(event) or String.ends_with?(event[:topic] || "", ".ci.failed")
  defp failure?(event), do: String.contains?(String.downcase(event[:summary] || ""), "fail")

  defp number_rework_rounds(items) do
    {items, _round} =
      Enum.map_reduce(items, 0, fn
        %{status: :rework} = item, round ->
          next = round + 1
          {Map.merge(item, %{label: "#{item.label} · rework round #{next}", round: next}), next}

        item, round ->
          {item, round}
      end)

    items
  end

  defp event_kind("consumed"), do: :consume
  defp event_kind("command"), do: :command
  defp event_kind(kind) when kind in ["emit", "emit_alert", "self"], do: :emit
  defp event_kind(_), do: :note

  defp percent(summary) when is_binary(summary) do
    case Regex.run(~r/\b(\d{1,3})%/, summary, capture: :all_but_first) do
      [value] -> String.to_integer(value)
      _ -> nil
    end
  end

  defp percent(_summary), do: nil

  defp label(%{topic: topic, summary: summary} = event) do
    suffix = topic |> String.split(".") |> Enum.drop(2) |> Enum.join(".")
    summary = if is_integer(event[:percent]), do: "Progress #{event.percent}%", else: summary
    if is_binary(summary) and summary != "", do: "#{suffix}: #{summary}", else: suffix
  end

  defp phases(items), do: phase_intervals(items)

  defp phase_intervals(items) do
    starts = Enum.filter(items, &(Map.get(&1, :status) == :phase and String.ends_with?(&1.topic, ".start")))

    Enum.map(starts, fn start ->
      finish = Enum.find(items, &(&1.topic == String.replace_suffix(start.topic, ".start", ".end") and &1.at >= start.at))
      %{label: phase_name(start.topic), start: start.at, finish: if(finish, do: finish.at)}
    end)
  end

  defp phase_name(topic) do
    case String.split(topic, ".") do
      ["ticket", _id, "agent", "phase", name, _transition] -> String.capitalize(name)
      _ -> "Phase"
    end
  end

  defp progress(items) do
    items
    |> Enum.filter(&(Map.get(&1, :status) == :progress))
    |> Enum.map(fn item ->
      item
    end)
  end

  defp event_id(%{id: id}) when is_integer(id), do: id
  defp event_id(_), do: 0

  defp pair_consumes(items) do
    emits = Enum.filter(items, &(&1.kind == :emit))

    Enum.map(items, fn
      %{kind: :consume} = item ->
        match = Enum.find(emits, &(&1.topic == item.topic and &1.at == item.at))
        if match, do: Map.put(item, :paired_id, match.id), else: item

      item ->
        item
    end)
  end
end
