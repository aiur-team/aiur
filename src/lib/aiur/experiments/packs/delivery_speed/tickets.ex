defmodule Aiur.Experiments.Packs.DeliverySpeed.Tickets do
  @moduledoc false
  alias Aiur.Experiments.{Coverage, Observation}
  alias Aiur.Experiments.Sources.Common

  @spec observations(String.t(), map(), map()) :: {[Observation.t()], non_neg_integer()}
  def observations(id, data, window) do
    rows = data.tickets |> Map.values() |> Enum.sort_by(& &1.ticket)

    observations =
      Enum.flat_map(rows, fn ticket ->
        if ticket.at && Common.in_window?(ticket.at, window), do: observation(ticket, value(id, ticket, data, window)), else: []
      end)

    {observations, length(rows) - length(observations)}
  end

  @spec missing_open?(map(), map()) :: boolean()
  def missing_open?(data, window) do
    Enum.any?(data.tickets, fn {_id, ticket} -> ticket.at && Common.in_window?(ticket.at, window) && event_at(ticket, "pr_merged") && is_nil(ticket.pr_opened_at) end)
  end

  defp value("start_to_pr_open", ticket, _data, window) do
    if ticket.pr_opened_at || is_nil(event_at(ticket, "pr_merged")), do: duration(ticket.at, ticket.pr_opened_at, window, true)
  end

  defp value("pr_open_to_merge", ticket, _data, window) do
    if ticket.pr_source?, do: duration(ticket.pr_opened_at, event_at(ticket, "pr_merged"), window, false)
  end

  defp value("start_to_merge", ticket, _data, window), do: duration(ticket.at, event_at(ticket, "pr_merged"), window, false)

  defp value("blocker_merge_to_dependent_start", ticket, data, window) do
    blockers = if is_list(ticket.blockers), do: Enum.map(ticket.blockers, &event_at(data.tickets[to_string(&1)], "pr_merged")), else: []
    if blockers != [] and Enum.all?(blockers, &is_struct(&1, DateTime)), do: duration(Enum.max(blockers, DateTime), ticket.at, window, false)
  end

  defp value("gap_between_prs", ticket, data, window) do
    merged = event_at(ticket, "pr_merged")
    epic = ticket.attrs["epic"]

    previous =
      data.tickets
      |> Map.values()
      |> Enum.filter(&(&1.ticket != ticket.ticket and &1.attrs["epic"] == epic))
      |> Enum.map(&event_at(&1, "pr_merged"))
      |> Enum.filter(&(merged && &1 && DateTime.compare(&1, merged) == :lt))

    if epic && previous != [], do: duration(Enum.max(previous, DateTime), merged, window, false)
  end

  defp value("pr_ready_to_first_review", ticket, _data, window) do
    opened = ticket.pr_opened_at
    review = Enum.find(ticket.reviews, &(opened && DateTime.compare(&1, opened) != :lt))
    if ticket.pr_source?, do: duration(opened, review, window, true)
  end

  defp value("review_rounds", ticket, _data, _window) do
    if merged = event_at(ticket, "pr_merged") do
      {Enum.count(ticket.events, &(&1.event == "review_pause" and &1.boundary in ["start", "point"] and DateTime.compare(&1.timestamp_dt, merged) != :gt)), merged, false}
    end
  end

  defp value("rework_time", ticket, _data, _window) do
    if merged = event_at(ticket, "pr_merged") do
      spans =
        ticket.events
        |> Enum.filter(&(&1.event == "rework_start" and DateTime.compare(&1.timestamp_dt, merged) == :lt))
        |> Enum.map(&rework_span(&1, ticket.events))

      {Enum.sum(spans), merged, false}
    end
  end

  defp value(_id, _ticket, _data, _window), do: nil

  defp rework_span(start, events) do
    finish = Enum.find(events, &(&1.event in ["pr_opened", "pr_merged"] and &1.timestamp_ms >= start.timestamp_ms))
    if finish, do: finish.timestamp_ms - start.timestamp_ms, else: 0
  end

  defp duration(nil, _finish, _window, _censor), do: nil
  defp duration(_start, nil, _window, false), do: nil
  defp duration(start, nil, window, true), do: {DateTime.diff(window.end, start, :millisecond), nil, true}

  defp duration(start, finish, _window, _censor) do
    if DateTime.compare(finish, start) != :lt, do: {DateTime.diff(finish, start, :millisecond), finish, false}
  end

  @spec event_at(map() | nil, String.t()) :: DateTime.t() | nil
  def event_at(nil, _name), do: nil

  def event_at(ticket, name) do
    case Enum.find(ticket.events, &(&1.event == name)) do
      nil -> nil
      event -> event.timestamp_dt
    end
  end

  defp observation(_ticket, nil), do: []

  defp observation(ticket, {value, finished, censored}) do
    attrs = Map.merge(ticket.attrs, %{"finished_at" => if(finished, do: DateTime.to_iso8601(finished)), "censored" => censored})
    [%Observation{unit_id: "ticket:" <> ticket.ticket, at: ticket.at, value: value, attrs: attrs}]
  end

  @spec cost(String.t(), map(), map(), map()) :: map()
  def cost(id, data, usage, window) do
    tickets = data.tickets |> Map.values() |> Enum.filter(&(&1.at && Common.in_window?(&1.at, window) && event_at(&1, "pr_merged")))
    values = Enum.map(tickets, fn ticket -> {ticket, cost_value(id, Map.get(usage, ticket.ticket, {:error, :accounting_identity_missing}))} end)
    missing = Enum.count(values, fn {_ticket, value} -> not is_number(value) end)
    coverage = Coverage.classify([], [], window, data.earliest_at)

    coverage =
      cond do
        missing > 0 and missing == length(values) -> %{state: :unavailable, reason: :accounting_incomplete}
        missing > 0 or data.partial? -> Map.merge(coverage, %{state: :partial, reason: :accounting_incomplete})
        true -> coverage
      end

    rows = Enum.flat_map(values, fn {ticket, value} -> if is_number(value), do: observation(ticket, {value, event_at(ticket, "pr_merged"), false}), else: [] end)
    Common.result(Map.merge(coverage, %{filtered: map_size(data.tickets) - length(rows)}), rows)
  end

  defp cost_value("spend_per_merged_ticket", {:ok, totals}) do
    case totals.money[{:provider_reported_estimate, "USD"}] do
      %Decimal{} = value -> Decimal.to_float(value)
      _missing -> nil
    end
  end

  defp cost_value("tokens_per_merged_ticket", {:ok, %{token_total: total}}), do: total

  defp cost_value(_id, _missing), do: nil
end
