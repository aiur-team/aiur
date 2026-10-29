defmodule AiurWeb.Streamdeck.Deck.Meters do
  @moduledoc "Deck usage from the Build page, selecting the account closest to its limit."
  alias AiurWeb.Build.Usage
  alias AiurWeb.EndpointConfig
  alias AiurWeb.Build.RedactedMeterSource

  @spec read(keyword()) :: map()
  def read(opts \\ []) do
    load = EndpointConfig.get(:streamdeck_usage_load_fun) || (&Usage.load/2)
    inputs = load.(:streamdeck, Keyword.put(opts, :meter_source, RedactedMeterSource))
    block = Usage.block({:ok, :streamdeck}, inputs, Keyword.get(opts, :now, DateTime.utc_now()))

    inputs.families
    |> Usage.order_families()
    |> Enum.zip(block.providers)
    |> Map.new(fn {family, row} -> {Atom.to_string(family), meter(family, row, inputs.accounts)} end)
  end

  defp meter(family, row, accounts) do
    names = row.accounts || if(family == :claude, do: Enum.sort(Map.keys(accounts)))
    {index, label} = closest(%{row | accounts: names})
    windows = if row.none, do: %{}, else: windows(row, index)

    %{
      "provider" => Atom.to_string(family),
      "state" => if(row.none or map_size(windows) == 0, do: "unknown", else: "observed"),
      "freshness" => if(row.stale, do: "stale", else: "fresh"),
      "summary_label" => label,
      "reason" => row.note,
      "windows" => windows
    }
  end

  defp closest(%{accounts: names} = row) when is_list(names) and names != [] do
    observed =
      names
      |> Enum.with_index()
      |> Enum.flat_map(fn {name, index} ->
        values = Enum.filter([remaining(row.session, index), remaining(row.weekly, index)], &is_number/1)
        if values == [], do: [], else: [{Enum.min(values), name, index}]
      end)

    case Enum.min(observed, fn -> nil end) do
      nil ->
        {0, nil}

      {_, name, index} ->
        count = length(observed)
        suffix = if count == length(names), do: "closest of #{count}", else: "#{count}/#{length(names)} observed"
        {index, "#{name} · #{suffix}"}
    end
  end

  defp closest(_row), do: {0, nil}

  defp windows(%{credits: %{pct: value}} = row, _index) do
    %{"session" => window(value, nil, row.stale)}
  end

  defp windows(row, index) do
    Map.new(
      for slot <- [:session, :weekly], window = row[slot], window != nil do
        value = remaining(window, index)

        {Atom.to_string(slot), window(value, reset(window.reset_at), row.stale)}
      end
    )
  end

  defp window(value, reset, stale) do
    %{"remaining_percent" => value, "used_percent" => if(is_number(value), do: 100 - value), "resets_at" => reset, "freshness" => if(stale, do: "stale", else: "fresh")}
  end

  defp remaining(%{acc: values}, index), do: Enum.at(values, index)
  defp remaining(_, _), do: nil
  defp reset(at) when is_integer(at), do: at |> DateTime.from_unix!(:millisecond) |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  defp reset(_), do: nil
end
