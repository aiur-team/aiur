defmodule Aiur.Config.UsageCadence do
  @moduledoc """
  Resolves how often Claude usage may be probed and cached.

  The cadence uses the shorter of the configured polling interval and the
  freshness cutoff, but never probes more often than the provider's measured
  two-minute floor. A cutoff below that floor can therefore become stale
  between probes.
  """

  @default_interval_seconds 300
  @min_interval_seconds 120

  @spec poll_interval_ms() :: pos_integer()
  def poll_interval_ms do
    poll_interval_ms(Aiur.Config.settings())
  rescue
    _error -> @default_interval_seconds * 1_000
  catch
    _kind, _reason -> @default_interval_seconds * 1_000
  end

  @doc false
  @spec poll_interval_ms({:ok, map()} | {:error, term()}) :: pos_integer()
  def poll_interval_ms({:ok, %{polling: %{usage_interval_seconds: interval}, agent: %{headroom_reading_max_age_seconds: max_age}}})
      when is_integer(interval) and interval > 0 and is_integer(max_age) and max_age > 0 do
    max(min(interval, max_age), @min_interval_seconds) * 1_000
  end

  def poll_interval_ms(_unavailable), do: @default_interval_seconds * 1_000
end
