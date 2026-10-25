defmodule Aiur.ProviderMeters.CLI do
  @moduledoc "Provider-neutral terminal rendering of observed allowance windows."

  alias Aiur.ProviderMeters.Text

  @spec print({atom(), map()}) :: :ok
  def print({provider, %{state: :unknown} = view}) do
    IO.puts("#{provider_label(provider)}  no observation yet#{scope_suffix(view)}")
  end

  def print({provider, view}) do
    windows = usage_windows(view)
    scope = scope_suffix(view) <> Text.freshness_suffix(view)

    if windows == [] do
      IO.puts("#{provider_label(provider)}  observed #{age_label(view.age_seconds)}, no limit windows reported#{scope}")
    else
      Enum.each(windows, fn window ->
        IO.puts("#{provider_label(provider)}  #{usage_window_line(window)}  (#{age_label(view.age_seconds)})#{scope}")
      end)
    end
  end

  defp usage_windows(%{windows: windows}) when is_map(windows) do
    windows
    |> Enum.filter(fn {_id, window} -> Map.get(window, :kind) in [:rate_limit, :credit] end)
    |> Enum.sort_by(fn {id, _window} -> id end)
  end

  defp usage_windows(_view), do: []

  # Claude's CLI reports a standing and a reset time but no utilization, so a
  # bar is not available for it. Name what is known rather than drawing an empty
  # bar, which would read as "0% consumed".
  defp usage_window_line({id, window}) do
    case {
      Map.get(window, :name),
      Map.get(window, :kind),
      Map.get(window, :used),
      Map.get(window, :limit),
      Map.get(window, :used_percent),
      Map.get(window, :credits)
    } do
      {name, :rate_limit, used, limit, _percent, _credits}
      when name in [:concurrency, "Local concurrency"] and is_number(used) and is_number(limit) ->
        "#{String.pad_trailing(id, 10)} #{used}/#{limit} in flight"

      {_name, :credit, _used, _limit, _percent, %{amount: amount}} when is_number(amount) ->
        "#{String.pad_trailing(id, 10)} $#{Text.amount(amount)} remaining"

      {_name, _kind, _used, _limit, percent, _credits} when is_number(percent) ->
        "#{String.pad_trailing(id, 10)} #{usage_bar(percent)} #{round(percent)}%#{cli_reset_suffix(Map.get(window, :resets_at))}"

      _unknown ->
        "#{String.pad_trailing(id, 10)} #{window_standing_line(window)}"
    end
  end

  defp window_standing_line(window) do
    case Map.get(window, :standing) do
      :allowed -> "allowed#{cli_reset_suffix(Map.get(window, :resets_at))}"
      :allowed_warning -> "near limit#{cli_reset_suffix(Map.get(window, :resets_at))}"
      :rejected -> "limited#{cli_reset_suffix(Map.get(window, :resets_at))}"
      _unknown -> "unknown"
    end
  end

  defp cli_reset_suffix(%DateTime{} = resets_at) do
    case DateTime.diff(resets_at, DateTime.utc_now()) do
      seconds when seconds <= 0 -> ""
      seconds when seconds < 3_600 -> ", resets in #{div(seconds, 60)}m"
      seconds when seconds < 86_400 -> ", resets in #{div(seconds, 3_600)}h"
      seconds -> ", resets in #{div(seconds, 86_400)}d #{div(rem(seconds, 86_400), 3_600)}h"
    end
  end

  defp cli_reset_suffix(_resets_at), do: ""

  @spec usage_bar(number()) :: String.t()
  defdelegate usage_bar(percent), to: Text, as: :bar

  defp age_label(nil), do: "age unknown"
  defp age_label(seconds) when seconds < 60, do: "#{seconds}s ago"
  defp age_label(seconds) when seconds < 3_600, do: "#{div(seconds, 60)}m ago"
  defp age_label(seconds), do: "#{div(seconds, 3_600)}h ago"

  defp provider_label(provider), do: provider |> to_string() |> String.pad_trailing(6)

  defp scope_suffix(%{summary_label: label}) when is_binary(label), do: " [#{label}]"
  defp scope_suffix(%{identity_scope: :host_unverified}), do: " [current host; account unverified]"
  defp scope_suffix(_view), do: ""
end
