defmodule Aiur.LandingWatch.Journal do
  @moduledoc "Durable idempotency journal for per-PR/head landing actions."

  alias Aiur.Config.Paths
  alias Aiur.JsonStore
  alias Aiur.LandingWatch.MergeGroupJournal

  @spec state(keyword()) :: {:ok, map()} | {:error, term()}
  def state(opts \\ []) do
    case JsonStore.read(path(opts), %{}) do
      {:ok, %{} = state} -> {:ok, state}
      {:ok, _} -> {:error, :invalid_landing_watch_journal}
      error -> error
    end
  end

  @spec reserve_rerun(pos_integer(), String.t(), integer(), keyword()) :: :ok | {:error, term()}
  def reserve_rerun(pr, head, now, opts \\ [])

  def reserve_rerun(pr, head, now, opts) when is_integer(pr) and is_binary(head) do
    update(opts, &reserve_rerun_entry(&1, key(pr, head), now))
  end

  @doc "Reserves a PR-level rerun against both the per-head budget and the shared automatic-requeue cap in one write."
  @spec reserve_automatic_rerun(pos_integer(), String.t(), integer(), keyword()) :: :ok | {:error, term()}
  def reserve_automatic_rerun(pr, head, now, opts \\ []) when is_integer(pr) and is_binary(head) do
    update(opts, fn state ->
      with {:ok, state} <- reserve_rerun_entry(state, key(pr, head), now),
           {:ok, state, :ok} <- MergeGroupJournal.take_requeue_slot(state, now),
           do: {:ok, state}
    end)
  end

  @doc "Why the per-head budget would refuse a rerun of this journal entry now, or nil."
  @spec rerun_refusal(map(), integer()) :: :rerun_backoff | :rerun_limit_reached | :invalid_landing_watch_journal_entry | nil
  def rerun_refusal(entry, now) do
    case rerun_decision(entry["rerun_count"] || 0, entry["last_rerun_at"] || 0, now) do
      :reserve -> nil
      {:error, reason} -> reason
    end
  end

  @spec mark_rerun_pending(pos_integer(), String.t(), map(), keyword()) :: :ok | {:error, term()}
  def mark_rerun_pending(pr, head, row, opts \\ []) when is_integer(pr) and is_binary(head) and is_map(row) do
    update(opts, fn state ->
      entry = Map.get(state, key(pr, head), %{})
      since = get_in(entry, ["rerun_pending", "since_ms"]) || row["since_ms"]
      {:ok, Map.put(state, key(pr, head), Map.put(entry, "rerun_pending", Map.put(row, "since_ms", since)))}
    end)
  end

  @spec clear_rerun_pending(pos_integer(), String.t(), keyword()) :: :ok | {:error, term()}
  def clear_rerun_pending(pr, head, opts \\ []) when is_integer(pr) and is_binary(head) do
    update(opts, fn state ->
      case Map.get(state, key(pr, head)) do
        %{"rerun_pending" => _} = entry -> {:ok, Map.put(state, key(pr, head), Map.delete(entry, "rerun_pending"))}
        _ -> {:ok, state}
      end
    end)
  end

  @doc "Approved PR heads whose automatic rerun waits behind the shared cap, oldest first."
  @spec rerun_backlog(keyword()) :: {:ok, [map()]} | {:error, term()}
  def rerun_backlog(opts \\ []) do
    with {:ok, state} <- state(opts) do
      rows =
        for {entry_key, %{"rerun_pending" => %{} = row}} <- state, [pr, head] <- [String.split(entry_key, ":", parts: 2)], {number, ""} <- [Integer.parse(pr)] do
          Map.merge(row, %{"pr" => number, "head" => head})
        end

      {:ok, Enum.sort_by(rows, &(&1["since_ms"] || 0))}
    end
  end

  @doc "Remembers a merged PR that changed CI files, so older failed PR runs can be rerun."
  @spec record_ci_merge(map(), keyword()) :: :ok | {:error, term()}
  def record_ci_merge(%{"pr" => pr} = row, opts \\ []) do
    update(opts, fn state ->
      merges = [row | Enum.reject(Map.get(state, "ci_merges", []), &(&1["pr"] == pr))] |> Enum.take(50)
      {:ok, Map.put(state, "ci_merges", merges)}
    end)
  end

  @spec ci_merges(keyword()) :: {:ok, [map()]} | {:error, term()}
  def ci_merges(opts \\ []) do
    with {:ok, state} <- state(opts), do: {:ok, Map.get(state, "ci_merges", [])}
  end

  @spec mark_landed(pos_integer(), String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def mark_landed(pr, head, entry, opts \\ []) do
    update(opts, fn state ->
      metadata = %{"landing" => "queued", "entry" => entry}
      {:ok, Map.update(state, key(pr, head), metadata, &Map.merge(&1, metadata))}
    end)
  end

  @spec claim_alert(pos_integer(), String.t(), String.t(), keyword()) :: {:ok, :new | :already_claimed} | {:error, term()}
  def claim_alert(pr, head, alert, opts \\ []) when is_integer(pr) and is_binary(head) and is_binary(alert) do
    update(opts, fn state ->
      entry_key = key(pr, head)
      entry = Map.get(state, entry_key, %{})
      alerts = Map.get(entry, "alerts", %{})

      if Map.has_key?(alerts, alert) do
        {:ok, state, :already_claimed}
      else
        entry = Map.put(entry, "alerts", Map.put(alerts, alert, true))
        {:ok, Map.put(state, entry_key, entry), :new}
      end
    end)
  end

  @spec release_alert(pos_integer(), String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def release_alert(pr, head, alert, opts \\ []) when is_integer(pr) and is_binary(head) and is_binary(alert) do
    update(opts, fn state ->
      entry_key = key(pr, head)

      case Map.get(state, entry_key) do
        %{"alerts" => alerts} = entry when is_map(alerts) ->
          updated = Map.put(entry, "alerts", Map.delete(alerts, alert))
          {:ok, Map.put(state, entry_key, updated)}

        _ ->
          {:ok, state}
      end
    end)
  end

  @spec claim_flake(String.t(), keyword()) :: {:ok, :new | :already_claimed} | {:error, term()}
  def claim_flake(identity, opts \\ []) when is_binary(identity) and identity != "" do
    update(opts, fn state ->
      flakes = Map.get(state, "flakes", %{})

      if Map.has_key?(flakes, identity) do
        {:ok, state, :already_claimed}
      else
        flakes =
          flakes
          |> Map.put(identity, System.system_time(:millisecond))
          |> Enum.sort_by(&elem(&1, 1), :desc)
          |> Enum.take(500)
          |> Map.new()

        {:ok, Map.put(state, "flakes", flakes), :new}
      end
    end)
  end

  @spec release_flake(String.t(), keyword()) :: :ok | {:error, term()}
  def release_flake(identity, opts \\ []) when is_binary(identity) and identity != "" do
    update(opts, fn state -> {:ok, Map.put(state, "flakes", Map.delete(Map.get(state, "flakes", %{}), identity))} end)
  end

  @spec record_failure_observation(map(), keyword()) :: :ok | {:error, term()}
  def record_failure_observation(row, opts \\ []) when is_map(row) do
    update(opts, fn state ->
      observations = Map.get(state, "failure_observations", [])
      identity = row["identity"]
      pr = row["pr"]
      run_url = row["run_url"]
      unique = Enum.reject(observations, &(&1["identity"] == identity and &1["pr"] == pr and &1["run_url"] == run_url))
      retained = [row | unique] |> Enum.sort_by(& &1["at_ms"], :desc) |> Enum.take(2_000)
      {:ok, Map.put(state, "failure_observations", retained)}
    end)
  end

  @spec failure_observations(keyword()) :: {:ok, [map()]} | {:error, term()}
  def failure_observations(opts \\ []) do
    with {:ok, state} <- state(opts), do: {:ok, Map.get(state, "failure_observations", [])}
  end

  @spec claim_merge_group_run(pos_integer(), keyword()) :: {:ok, :new | :already_claimed} | {:error, term()}
  def claim_merge_group_run(run_id, opts \\ []), do: MergeGroupJournal.claim_merge_group_run(run_id, opts)

  @spec reserve_merge_group_requeue(integer(), keyword()) :: :ok | {:error, :merge_group_requeue_limit_reached | term()}
  def reserve_merge_group_requeue(now, opts \\ []), do: MergeGroupJournal.reserve_merge_group_requeue(now, opts)

  @spec merge_group_requeues_by_hour(keyword()) :: {:ok, %{optional(String.t()) => non_neg_integer()}} | {:error, term()}
  def merge_group_requeues_by_hour(opts \\ []), do: MergeGroupJournal.merge_group_requeues_by_hour(opts)

  @spec release_merge_group_run(pos_integer(), keyword()) :: :ok | {:error, term()}
  def release_merge_group_run(run_id, opts \\ []), do: MergeGroupJournal.release_merge_group_run(run_id, opts)

  @spec claim_quarantine_merge_group_run(pos_integer(), keyword()) ::
          {:ok, :new | :already_claimed} | {:error, term()}
  def claim_quarantine_merge_group_run(run_id, opts \\ []),
    do: MergeGroupJournal.claim_quarantine_merge_group_run(run_id, opts)

  @spec release_quarantine_merge_group_run(pos_integer(), keyword()) :: :ok | {:error, term()}
  def release_quarantine_merge_group_run(run_id, opts \\ []),
    do: MergeGroupJournal.release_quarantine_merge_group_run(run_id, opts)

  @spec retain_current_heads([map()], keyword()) :: :ok | {:error, term()}
  def retain_current_heads(observations, opts \\ [])

  def retain_current_heads(observations, opts) when is_list(observations) do
    keys = Enum.map(observations, &current_head_key/1)

    if Enum.all?(keys, &is_binary/1) do
      retained = MapSet.new(keys)

      update(opts, fn state ->
        {:ok,
         Map.filter(state, fn {entry_key, _} ->
           entry_key in ["flakes", "merge_group_runs", "merge_group_run_failures", "quarantine_merge_group_runs", "merge_group_requeues", "ci_merges"] or MapSet.member?(retained, entry_key)
         end)}
      end)
    else
      :ok
    end
  end

  def retain_current_heads(_, _), do: {:error, :invalid_landing_watch_observations}

  @doc false
  @spec update(keyword(), (map() -> term())) :: term()
  def update(opts, fun) do
    path = path(opts)
    :global.trans({{__MODULE__, path}, self()}, fn -> perform_update(path, opts, fun) end)
  rescue
    error -> {:error, {:landing_watch_journal_failed, Exception.message(error)}}
  end

  defp perform_update(path, opts, fun) do
    with {:ok, state} <- state(opts),
         {:ok, updated, result} <- normalize_update_result(fun.(state)) do
      JsonStore.write!(path, updated)
      if result == :ok, do: :ok, else: {:ok, result}
    end
  end

  defp normalize_update_result({:ok, updated}), do: {:ok, updated, :ok}
  defp normalize_update_result({:ok, updated, result}), do: {:ok, updated, result}
  defp normalize_update_result(other), do: other

  defp backoff(1), do: 60_000
  defp backoff(_), do: 5 * 60_000
  defp key(pr, head), do: "#{pr}:#{head}"

  defp current_head_key(%{number: number, head: head}) when is_integer(number) and is_binary(head) and head != "", do: key(number, head)
  defp current_head_key(_), do: nil

  defp reserve_rerun_entry(state, key, now) do
    attempt = Map.get(state, key, %{"rerun_count" => 0, "last_rerun_at" => 0})
    count = attempt["rerun_count"] || 0
    last = attempt["last_rerun_at"] || 0

    case rerun_decision(count, last, now) do
      :reserve -> {:ok, Map.put(state, key, Map.merge(attempt, %{"rerun_count" => count + 1, "last_rerun_at" => now}))}
      {:error, _} = error -> error
    end
  end

  defp rerun_decision(count, last, now) when is_integer(count) and count >= 0 and is_integer(last) and last >= 0 do
    cond do
      count >= 2 -> {:error, :rerun_limit_reached}
      count > 0 and now - last < backoff(count) -> {:error, :rerun_backoff}
      true -> :reserve
    end
  end

  defp rerun_decision(_count, _last, _now), do: {:error, :invalid_landing_watch_journal_entry}

  defp path(opts) do
    case Keyword.get(opts, :journal_path) do
      path when is_binary(path) ->
        path

      _ ->
        case Paths.decision_state_dir() do
          {:ok, directory} -> Path.join(directory, "landing-watch.json")
          {:error, reason} -> raise "landing watcher state directory unavailable: #{inspect(reason)}"
        end
    end
  end
end
