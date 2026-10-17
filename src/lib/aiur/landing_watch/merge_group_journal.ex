defmodule Aiur.LandingWatch.MergeGroupJournal do
  @moduledoc "Persistence for merge-group run claims and automatic requeues."

  alias Aiur.LandingWatch.Journal

  @spec claim_merge_group_run(pos_integer(), keyword()) ::
          {:ok, :new | :already_claimed} | {:error, term()}
  def claim_merge_group_run(run_id, opts) when is_integer(run_id) and run_id > 0 do
    claim_run(run_id, "merge_group_runs", opts)
  end

  @spec claim_quarantine_merge_group_run(pos_integer(), keyword()) ::
          {:ok, :new | :already_claimed} | {:error, term()}
  def claim_quarantine_merge_group_run(run_id, opts) when is_integer(run_id) and run_id > 0,
    do: claim_run(run_id, "quarantine_merge_group_runs", opts)

  @spec reserve_merge_group_requeue(integer(), keyword()) ::
          :ok | {:error, :merge_group_requeue_limit_reached | term()}
  def reserve_merge_group_requeue(now, opts) when is_integer(now) do
    Journal.update(opts, &take_requeue_slot(&1, now))
  end

  @doc "Takes one slot of the shared automatic-requeue cap from a journal state, without writing it."
  @spec take_requeue_slot(map(), integer()) :: {:ok, map(), :ok} | {:error, :merge_group_requeue_limit_reached}
  def take_requeue_slot(state, now) do
    recent =
      state
      |> Map.get("merge_group_requeues", [])
      |> Enum.filter(&(is_integer(&1) and now >= &1 and now - &1 < 15 * 60_000))

    if length(recent) >= 3 do
      {:error, :merge_group_requeue_limit_reached}
    else
      {:ok, Map.put(state, "merge_group_requeues", [now | recent]), :ok}
    end
  end

  @spec merge_group_requeues_by_hour(keyword()) ::
          {:ok, %{optional(String.t()) => non_neg_integer()}} | {:error, term()}
  def merge_group_requeues_by_hour(opts \\ []) do
    with {:ok, state} <- Journal.state(opts) do
      counts =
        state
        |> Map.get("merge_group_requeues", [])
        |> Enum.filter(&is_integer/1)
        |> Enum.frequencies_by(fn timestamp ->
          hour = div(timestamp, 3_600_000) * 3_600_000
          DateTime.from_unix!(hour, :millisecond) |> DateTime.truncate(:second) |> DateTime.to_iso8601()
        end)

      {:ok, counts}
    end
  end

  @spec release_merge_group_run(pos_integer(), keyword()) :: :ok | {:error, term()}
  def release_merge_group_run(run_id, opts) when is_integer(run_id) and run_id > 0 do
    release_run(run_id, "merge_group_runs", opts)
  end

  @doc "Counts a failed attempt; releases the claim for a retry until `limit` attempts, then keeps it."
  @spec release_failed_merge_group_run(pos_integer(), pos_integer(), keyword()) ::
          {:ok, :released | :kept} | {:error, term()}
  def release_failed_merge_group_run(run_id, limit, opts) when is_integer(run_id) and run_id > 0 do
    run_key = Integer.to_string(run_id)

    Journal.update(opts, fn state ->
      failures = Map.get(state, "merge_group_run_failures", %{})
      count = failure_count(Map.get(failures, run_key)) + 1

      if count >= limit do
        {:ok, Map.put(state, "merge_group_run_failures", Map.delete(failures, run_key)), :kept}
      else
        state =
          state
          |> Map.put("merge_group_runs", Map.delete(Map.get(state, "merge_group_runs", %{}), run_key))
          |> Map.put("merge_group_run_failures", Map.put(failures, run_key, count))

        {:ok, state, :released}
      end
    end)
  end

  @spec clear_merge_group_run_failures(pos_integer(), keyword()) :: :ok | {:error, term()}
  def clear_merge_group_run_failures(run_id, opts) when is_integer(run_id) and run_id > 0,
    do: release_run(run_id, "merge_group_run_failures", opts)

  defp failure_count(count) when is_integer(count) and count > 0, do: count
  defp failure_count(_), do: 0

  @spec release_quarantine_merge_group_run(pos_integer(), keyword()) :: :ok | {:error, term()}
  def release_quarantine_merge_group_run(run_id, opts) when is_integer(run_id) and run_id > 0,
    do: release_run(run_id, "quarantine_merge_group_runs", opts)

  defp claim_run(run_id, journal_key, opts) do
    Journal.update(opts, fn state ->
      runs = Map.get(state, journal_key, %{})
      run_key = Integer.to_string(run_id)

      if Map.has_key?(runs, run_key) do
        {:ok, state, :already_claimed}
      else
        runs =
          runs
          |> Map.put(run_key, System.system_time(:millisecond))
          |> Enum.sort_by(&elem(&1, 1), :desc)
          |> Enum.take(500)
          |> Map.new()

        {:ok, Map.put(state, journal_key, runs), :new}
      end
    end)
  end

  defp release_run(run_id, journal_key, opts) do
    run_key = Integer.to_string(run_id)

    Journal.update(opts, fn state ->
      {:ok, Map.put(state, journal_key, Map.delete(Map.get(state, journal_key, %{}), run_key))}
    end)
  end
end
