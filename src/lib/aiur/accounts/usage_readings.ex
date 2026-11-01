defmodule Aiur.Accounts.UsageReadings do
  @moduledoc "Small read model for per-account provider usage observations."

  @key {__MODULE__, :readings}
  @explored_key {__MODULE__, :headroom_explorations}
  @default_max_reading_age_seconds 1800
  @headroom_exploration_window_seconds 120
  # Probe failures a fresh `aiur login` fixes, as opposed to a broken endpoint.
  @signed_out_reasons [:no_oauth_token, :token_expired, :unauthorized, :no_credentials]

  @doc "Whether a probe failure means the profile is not signed in."
  @spec signed_out?(term()) :: boolean()
  def signed_out?(reason), do: reason in @signed_out_reasons

  @doc "Operator-facing description of a probe failure, naming the fix for a signed-out profile."
  @spec failure_text(String.t(), term()) :: String.t()
  def failure_text(name, reason) do
    cond do
      signed_out?(reason) -> "not signed in; run `aiur login claude #{name}`"
      is_atom(reason) -> Atom.to_string(reason)
      true -> inspect(reason)
    end
  end

  @doc """
  Whether an observation is too old to treat as current.

  The one cutoff for every usage surface: `agent.headroom_reading_max_age_seconds`,
  past which dispatch already scores a reading as unknown (#5747). `aiur
  accounts` and the Models panel's account and window lines all use it.
  """
  @spec stale?(DateTime.t() | nil, DateTime.t()) :: boolean()
  def stale?(observed_at, now \\ DateTime.utc_now())
  def stale?(%DateTime{} = observed_at, %DateTime{} = now), do: DateTime.diff(now, observed_at, :second) > max_reading_age_seconds()
  def stale?(_observed_at, _now), do: false

  @doc "`agent.headroom_reading_max_age_seconds`, the one usage stale cutoff; headroom dispatch reads it here too."
  @spec max_reading_age_seconds() :: pos_integer()
  def max_reading_age_seconds do
    case Aiur.Config.settings() do
      {:ok, %{agent: %{headroom_reading_max_age_seconds: seconds}}} when is_integer(seconds) and seconds > 0 -> seconds
      _unavailable -> @default_max_reading_age_seconds
    end
  rescue
    _error -> @default_max_reading_age_seconds
  end

  @doc """
  The freshness every surface shows for an entry: `:stale` past the cutoff or
  while failing after an earlier good reading, otherwise the recorded
  freshness (`:fresh`, `:cached`, or `:unavailable` with no reading yet).
  """
  @spec freshness(map(), DateTime.t()) :: :fresh | :cached | :stale | :unavailable
  def freshness(entry, now \\ DateTime.utc_now())
  def freshness(%{reading: nil, last_observed_at: %DateTime{}}, _now), do: :stale
  def freshness(%{reading: nil}, _now), do: :unavailable

  def freshness(%{observed_at: observed_at, freshness: freshness}, now) do
    if stale?(observed_at, now), do: :stale, else: freshness
  end

  @doc "When the entry's numbers were actually observed: a failing entry keeps its last good observation time."
  @spec observed_at(map()) :: DateTime.t() | nil
  def observed_at(%{reading: nil} = entry), do: Map.get(entry, :last_observed_at)
  def observed_at(entry), do: Map.get(entry, :observed_at)

  @doc "One line per account whose latest usage probe failed: the failure, its time, and the fix (#7449)."
  @spec failure_lines() :: [String.t()]
  def failure_lines do
    for {{harness, name}, %{reading: nil, reason: reason} = entry} <- Enum.sort(snapshot()), not is_nil(reason) do
      "ACCOUNT #{harness}/#{name} usage probe failing: #{failure_text(name, reason)} " <>
        "(last failed #{DateTime.to_iso8601(entry.observed_at)}, #{Map.get(entry, :consecutive_failures, 1)} in a row)"
    end
  end

  @spec snapshot() :: %{{String.t(), String.t()} => map()}
  def snapshot, do: :persistent_term.get(@key, %{})

  @spec reset() :: :ok
  def reset do
    :persistent_term.erase(@key)
    :persistent_term.erase(@explored_key)
    :ok
  end

  @doc "Whether an unknown or stale account was dispatched recently while awaiting a fresh usage observation."
  @spec recently_explored?(String.t(), String.t(), DateTime.t()) :: boolean()
  def recently_explored?(harness, name, now \\ DateTime.utc_now()) do
    case Map.get(:persistent_term.get(@explored_key, %{}), {harness, name}) do
      %DateTime{} = explored_at ->
        age = DateTime.diff(now, explored_at, :second)
        age >= 0 and age < @headroom_exploration_window_seconds

      _missing ->
        false
    end
  end

  @doc "Mark an account as explored so an unknown reading does not attract a dispatch burst."
  @spec mark_explored(String.t(), String.t(), DateTime.t()) :: :ok
  def mark_explored(harness, name, now \\ DateTime.utc_now()) do
    explored = :persistent_term.get(@explored_key, %{})
    :persistent_term.put(@explored_key, Map.put(explored, {harness, name}, now))
    :ok
  end

  @spec snapshot(String.t(), [String.t()]) :: %{String.t() => map()}
  def snapshot(harness, names) do
    names
    |> Enum.uniq()
    |> Enum.reduce(%{}, fn name, acc ->
      case Map.fetch(snapshot(), {harness, name}) do
        {:ok, reading} -> Map.put(acc, name, reading)
        :error -> acc
      end
    end)
  end

  @spec record(String.t(), term(), DateTime.t()) :: :ok
  def record(name, result, observed_at) do
    record("claude", name, result, observed_at)
  end

  @spec record(String.t(), String.t(), term(), DateTime.t()) :: :ok
  def record(harness, name, result, observed_at), do: record(harness, name, result, observed_at, :fresh)

  @spec record(String.t(), String.t(), term(), DateTime.t(), :fresh | :cached) :: :ok
  def record(harness, name, result, observed_at, freshness) do
    readings = snapshot()
    previous = Map.get(readings, {harness, name}, %{})
    entry = entry(result, observed_at, freshness, previous)

    if match?({:ok, _reading}, result) and freshness == :fresh do
      clear_explored(harness, name)
    end

    :persistent_term.put(@key, Map.put(readings, {harness, name}, entry))
    :ok
  end

  defp clear_explored(harness, name) do
    explored = :persistent_term.get(@explored_key, %{})
    :persistent_term.put(@explored_key, Map.delete(explored, {harness, name}))
  end

  # Only a fresh read is a new observation, so only it ends a failure streak.
  # A cached read re-serves the last good value, usually because the endpoint
  # just refused (#5747), so it keeps the error that made it cached.
  defp entry({:ok, reading}, observed_at, :fresh, _previous),
    do: %{reading: reading, observed_at: observed_at, freshness: :fresh, reason: nil, consecutive_failures: 0}

  defp entry({:ok, reading}, observed_at, freshness, previous) do
    %{reading: reading, observed_at: observed_at, freshness: freshness, reason: Map.get(previous, :reason), consecutive_failures: Map.get(previous, :consecutive_failures, 0)}
  end

  # A failure carries no reading, but remembers when the account was last
  # actually observed so its age stays visible.
  defp entry({:error, reason}, observed_at, _freshness, previous) do
    %{
      reading: nil,
      observed_at: observed_at,
      freshness: :unavailable,
      reason: reason,
      consecutive_failures: Map.get(previous, :consecutive_failures, 0) + 1,
      last_observed_at: last_observed_at(previous)
    }
  end

  defp last_observed_at(%{reading: reading, observed_at: observed_at}) when not is_nil(reading), do: observed_at
  defp last_observed_at(previous), do: Map.get(previous, :last_observed_at)
end
