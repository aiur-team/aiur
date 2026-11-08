defmodule AiurWeb.Streamdeck.Deck.MeterDetail do
  @moduledoc "Per-account windows for the read-only provider detail page."
  alias Aiur.Accounts.UsageReadings
  alias Aiur.BuildOrder.SourceFreshness
  alias AiurWeb.Build.Usage
  alias AiurWeb.RemainingMeter

  @spec from_inputs(String.t(), map(), DateTime.t()) :: map()
  def from_inputs(provider, inputs, now) do
    accounts =
      if provider == "claude" and map_size(inputs.accounts) > 0 do
        inputs.accounts |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(fn {name, entry} -> account(name, entry, now) end)
      else
        single(provider, inputs, now)
      end

    %{provider: provider, accounts: accounts}
  end

  defp account(name, entry, now) do
    freshness = if UsageReadings.freshness(entry, now) == :stale, do: "stale", else: "fresh"
    windows = get_in(entry, [:reading, :windows]) || []
    %{name: name, freshness: freshness, session: account_window(windows, "five_hour", freshness, now), weekly: account_window(windows, "seven_day", freshness, now)}
  end

  defp account_window(windows, id, freshness, now) do
    window = Enum.find(windows, %{}, &(&1.window == id))
    value = window |> Map.get(:used_percent) |> RemainingMeter.percent() |> Usage.percent()
    window(value, SourceFreshness.ms(Map.get(window, :resets_at)), freshness, now)
  end

  defp single(provider, inputs, now) do
    families = Usage.order_families(inputs.families)
    rows = Usage.block({:ok, :streamdeck}, inputs, now).providers

    case Enum.find(Enum.zip(families, rows), fn {family, _row} -> Atom.to_string(family) == provider end) do
      nil ->
        []

      {_family, row} ->
        freshness = if row.stale, do: "stale", else: "fresh"
        [%{name: provider, freshness: freshness, session: row_window(row.session, freshness, now), weekly: row_window(row.weekly, freshness, now)}]
    end
  end

  defp row_window(%{acc: [value | _], reset_at: reset}, freshness, now), do: window(value, reset, freshness, now)
  defp row_window(_, freshness, now), do: window(nil, nil, freshness, now)

  defp window(value, reset, freshness, now) do
    freshness = if is_integer(reset) and reset < DateTime.to_unix(now, :millisecond), do: "stale", else: freshness
    %{remaining_percent: value, reset_at: reset, freshness: freshness}
  end
end
