defmodule Aiur.LandingWatch.MergeQueueRecoveryAttempt do
  @moduledoc false

  alias Aiur.LandingWatch.Journal

  @max_attempts 1
  @reservation_timeout_ms 2 * 60_000

  @spec reserve(pos_integer(), String.t(), integer(), keyword()) ::
          {:ok, :reserved} | {:skip, atom()} | {:error, term()}
  def reserve(number, head, now, opts) do
    key = "#{number}:#{head}"

    Journal.update(opts, fn state ->
      rows = Map.get(state, "unmergeable_queue_entries", %{})
      row = Map.get(rows, key, %{"since" => 0, "attempts" => 0})

      cond do
        attempts(row) >= @max_attempts ->
          {:ok, state, {:error, :recovery_attempt_limit}}

        reservation_live?(row, now) ->
          {:ok, state, {:skip, :recovery_in_progress}}

        true ->
          updated =
            row
            |> Map.put("recovery_pending", true)
            |> Map.put("recovery_pending_since", now)

          {:ok, put_row(state, rows, key, updated), {:reserved, updated}}
      end
    end)
    |> case do
      {:ok, {:reserved, _row}} -> {:ok, :reserved}
      {:ok, {:error, reason}} -> {:error, reason}
      {:ok, {:skip, reason}} -> {:skip, reason}
      {:error, _} = error -> error
    end
  end

  @spec release(pos_integer(), String.t(), keyword()) :: :ok | {:error, term()}
  def release(number, head, opts) do
    update_row(number, head, opts, fn row ->
      row
      |> Map.delete("recovery_pending")
      |> Map.delete("recovery_pending_since")
    end)
  end

  @spec commit(pos_integer(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def commit(number, head, opts) do
    key = "#{number}:#{head}"

    Journal.update(opts, fn state ->
      rows = Map.get(state, "unmergeable_queue_entries", %{})
      row = Map.get(rows, key, %{"since" => 0, "attempts" => 0})

      if Map.get(row, "recovery_pending", false) do
        updated =
          row
          |> Map.update("attempts", 1, &(&1 + 1))
          |> Map.delete("recovery_pending")
          |> Map.delete("recovery_pending_since")

        {:ok, put_row(state, rows, key, updated), {:ok, updated}}
      else
        {:ok, state, {:error, :recovery_reservation_lost}}
      end
    end)
    |> case do
      {:ok, {:ok, row}} when is_map(row) -> {:ok, row}
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, _} = error -> error
    end
  end

  defp update_row(number, head, opts, update_fun) do
    key = "#{number}:#{head}"

    Journal.update(opts, fn state ->
      rows = Map.get(state, "unmergeable_queue_entries", %{})

      rows =
        case Map.get(rows, key) do
          row when is_map(row) -> Map.put(rows, key, update_fun.(row))
          _ -> rows
        end

      {:ok, Map.put(state, "unmergeable_queue_entries", rows)}
    end)
  end

  defp put_row(state, rows, key, row),
    do: Map.put(state, "unmergeable_queue_entries", Map.put(rows, key, row))

  defp attempts(%{"attempts" => attempts}) when is_integer(attempts), do: attempts
  defp attempts(_), do: 0

  defp reservation_live?(%{"recovery_pending" => true, "recovery_pending_since" => started}, now)
       when is_integer(started),
       do: now - started < @reservation_timeout_ms

  defp reservation_live?(_, _), do: false
end
