defmodule AiurWeb.OperatorControlCenter.AccountUsagePresenter do
  @moduledoc "Named weekly account readings with an explicit worst-account summary."

  alias Aiur.Accounts.UsageReadings

  @spec present(map()) :: map() | nil
  def present(readings) when map_size(readings) == 0, do: nil

  def present(readings) do
    now = DateTime.utc_now()

    accounts =
      readings
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.with_index()
      |> Enum.map(fn {{name, reading}, index} ->
        percent = weekly_percent(reading)
        age_seconds = age_seconds(UsageReadings.observed_at(reading))
        resets_at = weekly_reset(reading)
        last_error = Map.get(reading, :reason)

        %{
          name: name,
          index: index,
          percent: percent,
          freshness: UsageReadings.freshness(reading, now),
          age_seconds: age_seconds,
          resets_at: resets_at,
          last_error: last_error
        }
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

  defp weekly_reset(%{reading: %{windows: windows}}) when is_list(windows) do
    case Enum.find(windows, &(&1.window == "seven_day")) do
      %{resets_at: %DateTime{} = resets_at} -> resets_at
      _missing -> nil
    end
  end

  defp weekly_reset(_reading), do: nil

  defp age_seconds(%DateTime{} = observed_at), do: max(DateTime.diff(DateTime.utc_now(), observed_at, :second), 0)
  defp age_seconds(_observed_at), do: nil

  defp account_usage_label(%{name: name, percent: percent, freshness: freshness, age_seconds: age, last_error: last_error}) do
    usage = if is_number(percent), do: "#{percent}%", else: "unknown"
    age_text = if is_integer(age), do: "#{age}s old", else: "age unknown"
    "#{name}: #{usage}, #{freshness} (#{age_text}#{error_text(last_error)})"
  end

  defp error_text(nil), do: ""
  defp error_text(reason), do: ", last error #{reason}"
end
