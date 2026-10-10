defmodule Aiur.Orchestrator.EnvelopeStore do
  @moduledoc false
  require Logger
  alias Aiur.{Config.Paths, JsonStore}

  @spec load(non_neg_integer(), pos_integer(), DateTime.t()) :: map() | nil
  def load(max_age, schedulers, now \\ DateTime.utc_now())
  def load(0, _schedulers, _now), do: nil

  def load(max_age, schedulers, now) do
    with {:ok, path} <- path(),
         {:ok, record} <- JsonStore.read(path),
         {:ok, normalized} <- normalize(record, max_age, schedulers, now) do
      normalized
    else
      {:error, reason} ->
        Logger.warning("Dispatch envelope record unavailable: #{inspect(reason)}")
        nil

      :none ->
        nil
    end
  end

  defp normalize(nil, _max_age, _schedulers, _now), do: :none

  defp normalize(%{"version" => 1, "safe_level" => level, "schedulers" => schedulers, "recorded_at" => stamp}, max_age, schedulers, now)
       when is_integer(level) and level >= 1 and is_binary(stamp) do
    with {:ok, recorded_at, _offset} <- DateTime.from_iso8601(stamp),
         age when age >= 0 and age <= max_age <- DateTime.diff(now, recorded_at) do
      {:ok, %{safe_level: level, resume_level: level, recorded_at: recorded_at, record_schedulers: schedulers}}
    else
      _ -> :none
    end
  end

  defp normalize(_record, _max_age, _schedulers, _now), do: :none

  @spec save(pos_integer(), pos_integer(), DateTime.t()) :: :ok | {:error, term()}
  def save(level, schedulers, now) do
    with {:ok, path} <- path() do
      JsonStore.write!(path, %{version: 1, safe_level: level, schedulers: schedulers, recorded_at: DateTime.to_iso8601(now)})
    end
  rescue
    error ->
      Logger.warning("Dispatch envelope record write failed: #{Exception.message(error)}")
      {:error, {:write_failed, error.__struct__}}
  end

  defp path do
    case Application.get_env(:aiur, :envelope_store_path) do
      path when is_binary(path) ->
        {:ok, path}

      _ ->
        with {:ok, dir} <- Paths.decision_state_dir(), do: {:ok, Path.join(dir, "dispatch-envelope.json")}
    end
  end
end
