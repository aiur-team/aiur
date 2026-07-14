defmodule Aiur.CurrentRunMembership.Store.Marker do
  @moduledoc false

  alias Aiur.CurrentRunMembership.Store.FileOps

  @record_keys ~w(reason run_id version)
  @max_marker_bytes 1_024
  @reasons %{
    checkpoint_corrupt: "checkpoint_corrupt",
    journal_corrupt: "journal_corrupt"
  }

  @spec load(String.t(), String.t()) :: :absent | {:degraded, atom()} | {:unavailable, atom()}
  def load(path, run_id) do
    case File.lstat(path) do
      {:error, :enoent} ->
        :absent

      {:ok, %File.Stat{type: :regular, size: size}} when size <= @max_marker_bytes ->
        with {:ok, contents} <- File.read(path),
             {:ok, record} <- Jason.decode(contents),
             @record_keys <- record |> Map.keys() |> Enum.sort(),
             %{"version" => 1, "run_id" => ^run_id, "reason" => reason} <- record,
             {:ok, marker_reason} <- parse_reason(reason) do
          {:degraded, marker_reason}
        else
          _ -> {:unavailable, :invalid_degraded_marker}
        end

      {:ok, %File.Stat{type: :regular}} ->
        {:unavailable, :degraded_marker_too_large}

      _ ->
        {:unavailable, :degraded_marker_unreadable}
    end
  end

  @spec write(String.t(), String.t(), term(), (-> term())) :: :ok | {:error, term()}
  def write(path, run_id, reason, sync_fun) do
    with {:ok, marker_reason} <- marker_reason(reason),
         :ok <- FileOps.atomic_write(path, Jason.encode!(%{"version" => 1, "run_id" => run_id, "reason" => marker_reason})),
         :ok <- FileOps.ensure_regular_file(path) do
      FileOps.sync_recovery_entry(sync_fun)
    end
  end

  defp marker_reason({:checkpoint_corrupt, _reason}), do: {:ok, @reasons.checkpoint_corrupt}
  defp marker_reason({:journal_corrupt, _line, _reason}), do: {:ok, @reasons.journal_corrupt}
  defp marker_reason(_reason), do: {:error, :invalid_degraded_marker_reason}

  defp parse_reason(reason) when is_binary(reason) do
    case Enum.find(@reasons, fn {_key, value} -> value == reason end) do
      {key, _value} -> {:ok, key}
      nil -> {:error, :invalid_degraded_marker_reason}
    end
  end

  defp parse_reason(_reason), do: {:error, :invalid_degraded_marker_reason}
end
