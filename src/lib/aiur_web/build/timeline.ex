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

    %{items: pair_consumes(items), high_water: Enum.reduce(events, 0, &max(&2, event_id(&1))), phases: phases(items), progress: progress(items), truncated: false}
  end

  @spec append_cache(map(), [map()]) :: map()
  def append_cache(%{events: cached, high_water: high_water}, incoming) when is_list(cached) and is_integer(high_water) do
    appended = Enum.filter(incoming, &(event_id(&1) > high_water))
    events = Enum.uniq_by(cached ++ appended, &event_id/1)
    %{events: events, high_water: Enum.reduce(events, high_water, &max(&2, event_id(&1)))}
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
      [%{id: event.id, at: DateTime.to_unix(at, :millisecond), actor: actor, kind: kind, label: label, topic: event.topic} |> Map.merge(extra)]
    else
      _ -> []
    end
  end

  defp actor(%{kind: "consumed"}), do: "Aiur daemon"

  defp actor(%{topic: "ticket." <> rest}) do
    case String.split(rest, ".", parts: 2) do
      [_id, "agent." <> _] -> "Aiur agent"
      [_id, "ci." <> _] -> "CI"
      [_id, suffix] when suffix in ["pr.opened", "pr.merged", "pr.ready_for_review", "pr.review_comment", "issue.commented"] -> "Executor"
      _ -> "Aiur daemon"
    end
  end

  defp actor(_), do: nil

  defp classify(%{topic: topic} = event) do
    cond do
      event.kind == "consumed" ->
        {:ok, :consume, %{}}

      String.ends_with?(topic, ".progress") or String.ends_with?(topic, ".progress.checkin") ->
        value = Map.get(event, :percent) || percent(event.summary)
        {:ok, :progress, if(is_integer(value), do: %{percent: value}, else: %{})}

      String.contains?(topic, ".agent.phase.") ->
        {:ok, :phase, %{}}

      true ->
        {:ok, event_kind(event.kind), %{}}
    end
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
    starts = Enum.filter(items, &(&1.kind != :consume and String.ends_with?(&1.topic, ".start")))

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
    |> Enum.filter(&(&1.kind == :progress))
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
