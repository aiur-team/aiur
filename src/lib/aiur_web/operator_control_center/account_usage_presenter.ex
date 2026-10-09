defmodule AiurWeb.OperatorControlCenter.AccountUsagePresenter do
  @moduledoc "Named weekly account readings with an explicit worst-account summary."

  @spec present(map()) :: map() | nil
  def present(readings) when map_size(readings) == 0, do: nil

  def present(readings) do
    accounts =
      readings
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.with_index()
      |> Enum.map(fn {{name, reading}, index} ->
        percent = weekly_percent(reading)
        age_seconds = age_seconds(reading.observed_at)
        %{name: name, index: index, percent: percent, freshness: reading.freshness, age_seconds: age_seconds}
      end)

    percentages = Enum.map(accounts, & &1.percent)
    total = if Enum.all?(percentages, &is_number/1), do: Enum.max(percentages), else: nil
    title = Enum.map_join(accounts, "; ", &account_usage_label/1)

    %{count: length(accounts), total_percent: total, title: title, accounts: accounts}
  end

  defp weekly_percent(%{reading: %{windows: windows}}) when is_list(windows) do
    case Enum.find(windows, &(&1.window == "seven_day")) do
      %{used_percent: percent} when is_number(percent) -> percent
      _missing -> nil
    end
  end

  defp weekly_percent(_reading), do: nil

  defp age_seconds(%DateTime{} = observed_at), do: max(DateTime.diff(DateTime.utc_now(), observed_at, :second), 0)
  defp age_seconds(_observed_at), do: nil

  defp account_usage_label(%{name: name, percent: percent, freshness: freshness, age_seconds: age}) do
    usage = if is_number(percent), do: "#{percent}%", else: "unknown"
    age_text = if is_integer(age), do: "#{age}s old", else: "age unknown"
    "#{name}: #{usage}, #{freshness} (#{age_text})"
  end
end
