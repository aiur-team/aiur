defmodule Aiur.CodingAgent.CapacityReasonText do
  @moduledoc """
  Operator text for a `capacity/v1` dispatch decision record (plan
  `docs/plans/2026-11-08-7881-provider-capacity-policy.md`, section 5): the
  reason the chosen source was picked, and one clause per source when no
  source is authorized.

  Accepts atom or string keys, so a record read back from the agent event
  stream renders the same as the live one. A candidate's reading is either a
  `reading` map (`remaining_percent`, `age_s`) or the flat `remaining_percent`
  and `age_seconds` of a headroom row. An unknown reading renders as `usage
  unknown`, never as a number; an exhausted one (a limited source) as
  `exhausted`; one with no observation time as `age unknown`. A chosen
  source's reading is the one taken at dispatch, and says so. A `limited` candidate keeps
  verdict `allow` in the record but cannot take work, so it counts as held.
  """

  @reasons %{
    "preferred" => "preferred",
    "only_allowed" => "only allowed source",
    "last_resort_used" => "last resort",
    "pinned" => "pinned",
    "reserve" => "Executor reserve",
    "limit_daily" => "daily spend limit reached",
    "limit_weekly" => "weekly spend limit reached",
    "limit_monthly" => "monthly spend limit reached",
    "limit_global" => "global spend limit reached",
    "balance_exhausted" => "balance exhausted",
    "spend_unknown" => "spend unknown under a limit",
    "reading_unknown" => "usage unknown",
    "floor" => "below usage floor",
    "limited" => "limited",
    "not_served" => "does not serve this work",
    "last_resort" => "last resort only"
  }

  @doc "The text for one reason code; an unrecognized code renders as itself."
  @spec reason(atom() | String.t() | nil) :: String.t()
  def reason(nil), do: "no reason recorded"
  def reason(code), do: Map.get(@reasons, to_string(code), to_string(code))

  @doc """
  `codex/default (preferred; 62% left at dispatch, reading 40s old)` for the chosen candidate, with
  the held sources after a `last_resort_used` choice, or `nil` without a choice.
  """
  @spec chosen(map() | nil) :: String.t() | nil
  def chosen(%{} = record) do
    case get(record, :chosen) do
      %{} = chosen ->
        reading = record |> candidates() |> Enum.find(&same_source?(&1, chosen)) |> reading(true)
        held = if to_string(get(chosen, :reason)) == "last_resort_used", do: held_clauses(record, true), else: []
        details = Enum.reject([reason(get(chosen, :reason)), reading | held], &is_nil/1)
        "#{source(chosen)} (#{Enum.join(details, "; ")})"

      _none ->
        nil
    end
  end

  def chosen(_record), do: nil

  @doc """
  `waiting: no authorized source: claude/default Executor reserve (…); codex limited`
  for a record with no allowed candidate, or `nil` when one is allowed.
  """
  @spec waiting(map() | nil) :: String.t() | nil
  def waiting(%{} = record) do
    candidates = candidates(record)

    if candidates != [] and Enum.all?(candidates, &held?/1),
      do: "waiting: no authorized source: " <> Enum.join(held_clauses(record), "; ")
  end

  def waiting(_record), do: nil

  defp held_clauses(record, at_dispatch? \\ false) do
    record
    |> candidates()
    |> Enum.filter(&held?/1)
    |> Enum.map(&clause(&1, at_dispatch?))
  end

  defp held?(candidate), do: to_string(get(candidate, :verdict)) != "allow" or to_string(get(candidate, :reason)) == "limited"

  defp clause(candidate, at_dispatch?) do
    detail = get(candidate, :detail)
    details = Enum.reject([present(detail), reading(candidate, at_dispatch?, get(candidate, :reason))], &(&1 in [nil, ""]))
    base = "#{source(candidate)} #{reason(get(candidate, :reason) || get(candidate, :verdict))}"
    if details == [], do: base, else: base <> " (" <> Enum.join(details, ", ") <> ")"
  end

  defp reading(candidate, at_dispatch?, reason \\ nil)
  defp reading(nil, _at_dispatch?, _reason), do: nil

  defp reading(candidate, at_dispatch?, reason) do
    {percent, age, stale?} =
      case get(candidate, :reading) do
        %{} = reading -> {get(reading, :remaining_percent), get(reading, :age_s), get(reading, :stale) == true}
        _flat -> {get(candidate, :remaining_percent), get(candidate, :age_seconds), get(candidate, :stale) == true}
      end

    if is_map(get(candidate, :reading)) or has?(candidate, :remaining_percent) do
      value = value_text(to_string(get(candidate, :status)), percent, to_string(reason))
      value = value && if(at_dispatch?, do: value <> " at dispatch", else: value)
      age = age_text(age, if(at_dispatch?, do: "reading ", else: ""))
      Enum.join(Enum.reject([value, stale? && "stale", age], &(&1 in [nil, false])), ", ")
    end
  end

  # A limited source scores exhausted with no percent; that is a known cause, not an unknown reading.
  defp value_text("exhausted", percent, _reason) when not is_number(percent), do: "exhausted"
  defp value_text(_status, percent, _reason) when is_number(percent), do: "#{round(percent)}% left"
  # The clause already says `usage unknown`.
  defp value_text(_status, _unknown, "reading_unknown"), do: nil
  defp value_text(_status, _unknown, _reason), do: "usage unknown"

  # No age means the reading has no observation time, not that it was never read.
  defp age_text(seconds, prefix) when is_integer(seconds) and seconds >= 0, do: prefix <> elapsed(seconds) <> " old"
  defp age_text(_none, _prefix), do: "age unknown"

  defp elapsed(seconds) when seconds < 120, do: "#{seconds}s"
  defp elapsed(seconds) when seconds < 7200, do: "#{div(seconds, 60)}m"
  defp elapsed(seconds), do: "#{div(seconds, 3600)}h"

  defp source(entry) do
    route = get(entry, :route) || get(entry, :backend)
    account = get(entry, :account)
    if present(account), do: "#{route}/#{account}", else: "#{route}"
  end

  defp same_source?(candidate, chosen),
    do: get(candidate, :route) == get(chosen, :route) and get(candidate, :account) == get(chosen, :account)

  defp candidates(record) do
    case get(record, :candidates) do
      list when is_list(list) -> Enum.filter(list, &is_map/1)
      _none -> []
    end
  end

  defp has?(map, key), do: Map.has_key?(map, key) or Map.has_key?(map, Atom.to_string(key))
  defp get(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp present(value) when is_binary(value) and value != "", do: value
  defp present(_value), do: nil
end
