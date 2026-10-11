defmodule AiurWeb.ProviderMeterWindows do
  @moduledoc "Shared provider session and weekly window classification."
  @session_window_tokens ~w(session primary five_hour hourly)
  @weekly_window_tokens ~w(weekly secondary seven_day)
  @spec semantic(map() | nil, atom()) :: list()
  def semantic(windows, provider), do: windows |> meter_windows(provider) |> semantic_windows()

  defp meter_windows(windows, provider) when is_map(windows) do
    windows
    |> Enum.filter(&eligible_window?(&1, provider))
    |> Enum.sort_by(fn {limit_id, window} -> {window_duration(window), to_string(limit_id)} end)
  end

  defp meter_windows(_windows, _provider), do: []

  defp eligible_window?({limit_id, window}, provider) when is_map(window) do
    if to_string(field(window, :limit_id) || limit_id) == "local-concurrency" do
      false
    else
      case field(window, :kind) do
        kind when kind in [:rate_limit, "rate_limit"] -> true
        kind when kind in [:credit, "credit"] -> provider != :codex
        _kind -> false
      end
    end
  end

  defp eligible_window?(_entry, _provider), do: false

  defp semantic_windows([]), do: []

  defp semantic_windows(windows) do
    session = Enum.find(windows, &credit_window?/1) || Enum.find(windows, &window_matches?(&1, @session_window_tokens))
    weekly = windows |> List.delete(session) |> Enum.find(&window_matches?(&1, @weekly_window_tokens))
    remaining = windows |> unclassified_windows() |> List.delete(session) |> List.delete(weekly)

    session = session || fallback_window(remaining, :shortest)
    weekly = weekly || remaining |> List.delete(session) |> fallback_window(:longest)

    [{"session", session}, {"weekly", weekly}]
    |> Enum.reject(fn {_slot, window} -> is_nil(window) end)
  end

  defp credit_window?({_limit_id, window}), do: field(window, :kind) in [:credit, "credit"]

  defp unclassified_windows(windows) do
    Enum.reject(windows, fn window ->
      credit_window?(window) or window_matches?(window, @session_window_tokens) or window_matches?(window, @weekly_window_tokens)
    end)
  end

  defp window_matches?({limit_id, _window}, tokens) do
    limit_id
    |> to_string()
    |> String.downcase()
    |> then(&Enum.any?(tokens, fn token -> String.contains?(&1, token) end))
  end

  defp fallback_window([], _fallback), do: nil
  defp fallback_window(windows, :shortest), do: Enum.min_by(windows, fn {_limit_id, window} -> window_duration(window) end)
  defp fallback_window(windows, :longest), do: Enum.max_by(windows, fn {_limit_id, window} -> window_duration(window) end)

  defp window_duration(window) do
    case field(window, :duration_minutes) do
      minutes when is_integer(minutes) and minutes >= 0 -> minutes
      _ -> 0
    end
  end

  defp field(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end
