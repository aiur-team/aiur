defmodule Aiur.Orchestrator.DurationCapRetryStore do
  @moduledoc false

  alias Aiur.{Config.Paths, JsonStore}

  @spec count(String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def count(issue_id) when is_binary(issue_id) do
    case JsonStore.read(path(), %{}) do
      {:ok, counts} when is_map(counts) ->
        case Map.get(counts, issue_id, 0) do
          count when is_integer(count) and count >= 0 -> {:ok, count}
          _ -> {:error, :invalid_count}
        end

      {:ok, _} ->
        {:error, :invalid_store}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error -> {:error, error}
  end

  @spec increment(String.t()) :: :ok | {:error, term()}
  def increment(issue_id) when is_binary(issue_id) do
    with {:ok, counts} <- JsonStore.read(path(), %{}),
         true <- is_map(counts),
         {:ok, current} <- count_value(counts, issue_id) do
      JsonStore.write!(path(), Map.put(counts, issue_id, current + 1))
    else
      false -> {:error, :invalid_store}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, error}
  end

  defp count_value(counts, issue_id) do
    case Map.get(counts, issue_id, 0) do
      count when is_integer(count) and count >= 0 -> {:ok, count}
      _ -> {:error, :invalid_count}
    end
  end

  defp path do
    case Application.get_env(:aiur, :duration_cap_retry_store_path) do
      path when is_binary(path) and path != "" ->
        path

      _ ->
        case Paths.decision_state_dir() do
          {:ok, dir} -> Path.join(dir, "duration-cap-retries.json")
          {:error, reason} -> raise "duration-cap retry path unavailable: #{inspect(reason)}"
        end
    end
  end
end
