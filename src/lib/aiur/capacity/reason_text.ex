defmodule Aiur.Capacity.ReasonText do
  @moduledoc """
  Operator text for a `capacity/v1` dispatch decision record (plan
  `docs/plans/2026-11-08-7881-provider-capacity-policy.md`, section 5): the
  reason the chosen source was picked, and one clause per source when no
  source is authorized.

  Accepts atom or string keys, so a record read back from the agent event
  stream renders the same as the live one. An unknown reading always renders
  as `unknown` with its age, never as a number.
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
  `codex/default (preferred; 62% left, 40s old)` for the chosen candidate, with
  the held sources after a `last_resort_used` choice, or `nil` without a choice.
  """
  @spec chosen(map() | nil) :: String.t() | nil
  def chosen(%{} = record) do
    case get(record, :chosen) do
      %{} = chosen ->
        reading = record |> candidates() |> Enum.find(&same_source?(&1, chosen)) |> reading()
        held = if to_string(get(chosen, :reason)) == "last_resort_used", do: held_clauses(record), else: []
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

    if candidates != [] and not Enum.any?(candidates, &(to_string(get(&1, :verdict)) == "allow")),
      do: "waiting: no authorized source: " <> Enum.join(held_clauses(record), "; ")
  end

  def waiting(_record), do: nil

  defp held_clauses(record) do
    record
    |> candidates()
    |> Enum.reject(&(to_string(get(&1, :verdict)) == "allow"))
    |> Enum.map(&clause/1)
  end

  defp clause(candidate) do
    detail = get(candidate, :detail)
    details = Enum.reject([present(detail), reading(candidate)], &is_nil/1)
    base = "#{source(candidate)} #{reason(get(candidate, :reason) || get(candidate, :verdict))}"
    if details == [], do: base, else: base <> " (" <> Enum.join(details, ", ") <> ")"
  end

  defp reading(nil), do: nil

  defp reading(candidate) do
    case get(candidate, :reading) do
      %{} = reading -> reading_text(get(reading, :remaining_percent), get(reading, :age_s))
      _none -> nil
    end
  end

  defp reading_text(percent, age) when is_number(percent), do: "#{round(percent)}% left" <> age_text(age)
  defp reading_text(_unknown, age), do: "usage unknown" <> age_text(age)

  defp age_text(seconds) when is_integer(seconds) and seconds >= 0, do: ", " <> elapsed(seconds) <> " old"
  defp age_text(_none), do: ", never read"

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

  defp get(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp present(value) when is_binary(value) and value != "", do: value
  defp present(_value), do: nil
end
