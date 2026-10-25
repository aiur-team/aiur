defmodule Aiur.LandingWatch.QuarantineRetry do
  @moduledoc """
  Bounds the retries of one quarantine step (a quarantine PR, or the requeue of the PRs a
  flake dropped). Backoff doubles from 1 to 32 minutes; after 7 failures in 24 hours the
  step stops and raises one attention.
  """

  alias Aiur.Alerts
  alias Aiur.LandingWatch.Journal

  @key "quarantine_retries"
  @max_attempts 7
  @window_ms 24 * 60 * 60 * 1_000

  @doc "Journal key that holds the retry entries; retained across polls."
  @spec journal_key() :: String.t()
  def journal_key, do: @key

  @spec now(keyword()) :: integer()
  def now(opts), do: Keyword.get(opts, :quarantine_now_ms, System.system_time(:millisecond))

  @doc "Whether the named step may run now, given the journal state."
  @spec due?(map(), String.t(), integer()) :: boolean()
  def due?(state, name, now) do
    case get_in(state, [@key, name]) do
      %{"first_at" => first} when now - first > @window_ms -> true
      %{"count" => count} when count >= @max_attempts -> false
      %{"next_at" => next_at} -> now >= next_at
      _ -> true
    end
  end

  @doc "Records a failed attempt and returns the error; the last allowed failure raises one attention."
  @spec failed(String.t(), {:error, term()}, keyword()) :: {:error, term()}
  def failed(name, {:error, reason} = error, opts) do
    now = now(opts)

    case Journal.update(opts, &bump(&1, name, now)) do
      {:ok, @max_attempts} -> give_up(name, reason, opts)
      _ -> :ok
    end

    error
  end

  @spec succeeded(String.t(), keyword()) :: :ok | {:error, term()}
  def succeeded(name, opts) do
    Journal.update(opts, fn state -> {:ok, Map.update(state, @key, %{}, &Map.delete(&1, name))} end)
  end

  defp bump(state, name, now) do
    entries = Map.get(state, @key, %{})

    entry =
      case Map.get(entries, name) do
        %{"first_at" => first} = entry when now - first <= @window_ms -> entry
        _ -> %{"first_at" => now, "count" => 0}
      end

    count = entry["count"] + 1
    entry = Map.merge(entry, %{"count" => count, "next_at" => now + 60_000 * Integer.pow(2, count - 1)})
    {:ok, Map.put(state, @key, Map.put(entries, name, entry)), count}
  end

  defp give_up(name, reason, opts) do
    message = "Landing watcher stopped retrying #{name} after #{@max_attempts} failures in 24 hours (last error: #{inspect(reason)})."
    emitter = Keyword.get(opts, :alert_emitter, &Alerts.emit_system/2)
    emitter.("system.pr.landing.quarantine_gave_up", central: true, durable: false, needs_attention: true, message: message, reason: message)
  end
end
