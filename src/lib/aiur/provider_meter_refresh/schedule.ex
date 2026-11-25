defmodule Aiur.ProviderMeterRefresh.Schedule do
  @moduledoc """
  When each provider's usage must be re-read, whether or not anything is watching.

  A meter that read 100% stays at 100% until something observes the provider
  again, and nothing else does while the fleet is idle. So a provider is due:

  - shortly after the earliest `resets_at` a window recorded, so the new
    headroom shows within minutes of the reset;
  - again, with backoff, while its reading still predates a reset that has
    passed (the provider may not report the new window straight away);
  - every `limited_interval` while a window is exhausted, so a reset that was
    never recorded, or recorded wrong, still recovers.

  Pure: views, the wall clock and the last attempt per provider come in, the
  next check per provider comes out.
  """

  @reset_margin_seconds 60
  @limited_interval_seconds 15 * 60
  @retry_base_seconds 60

  @type attempt :: %{at: DateTime.t(), count: non_neg_integer()}

  @doc "The next time each provider is due, or no entry when nothing schedules it."
  @spec next_checks(%{atom() => map()}, DateTime.t(), %{atom() => attempt()}) :: %{atom() => DateTime.t()}
  def next_checks(views, %DateTime{} = now, attempts) when is_map(views) and is_map(attempts) do
    for {provider, view} <- views, check = next_check(view, now, Map.get(attempts, provider)), into: %{}, do: {provider, check}
  end

  @doc "Providers whose next check is at or before `now`."
  @spec due(%{atom() => DateTime.t()}, DateTime.t()) :: [atom()]
  def due(next_checks, %DateTime{} = now) do
    for {provider, at} <- next_checks, DateTime.compare(at, now) != :gt, do: provider
  end

  @doc "Whether the provider's reading predates a reset that has already passed."
  @spec awaiting_reset?(map(), DateTime.t()) :: boolean()
  def awaiting_reset?(view, %DateTime{} = now) do
    observed_at = Map.get(view, :observed_at)
    Enum.any?(resets(view), &(not after?(&1, now) and not observed_after?(observed_at, &1)))
  end

  defp next_check(view, now, attempt) when is_map(view) do
    [retry_after_reset(view, now, attempt), upcoming_reset(view, now), limited_check(view, attempt)]
    |> Enum.reject(&is_nil/1)
    |> Enum.min(DateTime, fn -> nil end)
  end

  defp next_check(_view, _now, _attempt), do: nil

  defp retry_after_reset(view, now, attempt) do
    cond do
      not awaiting_reset?(view, now) -> nil
      is_nil(attempt) -> now
      true -> DateTime.add(attempt.at, backoff_seconds(attempt.count), :second)
    end
  end

  defp upcoming_reset(view, now) do
    case view |> resets() |> Enum.filter(&after?(&1, now)) do
      [] -> nil
      future -> future |> Enum.min(DateTime) |> DateTime.add(@reset_margin_seconds, :second)
    end
  end

  defp limited_check(view, attempt) do
    if limited?(view) do
      base = [Map.get(view, :observed_at), attempt && attempt.at] |> Enum.filter(&match?(%DateTime{}, &1)) |> Enum.max(DateTime, fn -> nil end)
      if base, do: DateTime.add(base, @limited_interval_seconds, :second), else: nil
    end
  end

  # 1, 2, 4, 8 minutes, then every limited interval.
  defp backoff_seconds(count), do: min(@retry_base_seconds * Integer.pow(2, max(count - 1, 0)), @limited_interval_seconds)

  defp limited?(view) do
    view |> windows() |> Enum.any?(fn window -> Map.get(window, :standing) == :rejected or exhausted?(Map.get(window, :used_percent)) end)
  end

  defp exhausted?(percent) when is_number(percent), do: percent >= 100
  defp exhausted?(_percent), do: false

  defp resets(view), do: for(%{resets_at: %DateTime{} = at} <- windows(view), do: at)

  defp windows(%{windows: windows}) when is_map(windows), do: Map.values(windows)
  defp windows(_view), do: []

  defp after?(at, now), do: DateTime.compare(at, now) == :gt
  defp observed_after?(%DateTime{} = observed_at, reset), do: DateTime.compare(observed_at, reset) != :lt
  defp observed_after?(_observed_at, _reset), do: false
end
