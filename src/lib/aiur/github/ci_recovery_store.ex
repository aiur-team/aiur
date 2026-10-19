defmodule Aiur.GitHub.CIRecoveryStore do
  @moduledoc "Strict, daemon-private journal of CI recovery attempts and failed handoffs."
  alias Aiur.{CIApprovalStore, JsonStore}

  @spec read(String.t(), integer(), keyword()) :: {:ok, map()} | {:error, term()}
  def read(target, pr, opts) do
    case JsonStore.read(path(opts), %{}) do
      {:ok, entries} when is_map(entries) ->
        entry = Map.get(entries, target, %{})
        normalize(entry, pr)

      {:error, _} = error ->
        error

      _ ->
        {:error, :invalid_ci_recovery_journal}
    end
  end

  defp normalize(%{"pr" => pr, "cycles" => cycles, "heads" => heads} = entry, pr) when is_integer(cycles) and cycles >= 0 and is_map(heads) do
    if Enum.all?(heads, fn {sha, attempt} -> is_binary(sha) and valid_attempt?(attempt) end) and valid_hold?(entry["hold"]) and
         valid_limit_hold?(entry["limit_hold"]) and is_list(Map.get(entry, "attentions", [])),
       do: {:ok, entry},
       else: {:error, :invalid_ci_recovery_entry}
  end

  defp normalize(%{"pr" => pr}, pr), do: {:error, :invalid_ci_recovery_entry}
  defp normalize(entry, pr) when is_map(entry), do: {:ok, %{"pr" => pr, "cycles" => 0, "heads" => %{}}}
  defp normalize(_, _), do: {:error, :invalid_ci_recovery_entry}

  defp valid_hold?(nil), do: true

  defp valid_hold?(%{"sha" => sha, "reason" => reason, "tests" => tests, "mode" => mode}),
    do: is_binary(sha) and is_binary(reason) and is_binary(tests) and mode in ["hold", "fallback", "landing", "transient", "base"]

  defp valid_hold?(_), do: false
  defp valid_limit_hold?(nil), do: true
  defp valid_limit_hold?(%{"sha" => sha, "retry_at" => retry_at}), do: is_binary(sha) and is_integer(retry_at)
  defp valid_limit_hold?(_), do: false
  defp valid_attempt?(%{"runs" => [_ | _] = runs} = attempt), do: valid_time?(attempt) and is_list(attempt["checks"]) and Enum.all?(runs, &valid_run?/1)
  defp valid_attempt?(_), do: false
  defp valid_time?(%{"requested_at" => time} = attempt), do: is_integer(time) and (not Map.has_key?(attempt, "error") or is_binary(attempt["error"]))
  defp valid_time?(_), do: false
  defp valid_run?(%{"id" => id, "attempt" => attempt}), do: is_integer(id) and id > 0 and is_integer(attempt) and attempt > 0
  defp valid_run?(_), do: false

  @spec update(String.t(), integer(), (map() -> map()), keyword()) :: {:ok, map()} | {:error, term()}
  def update(target, pr, fun, opts) do
    journal = path(opts)

    :global.trans({{__MODULE__, journal}, self()}, fn ->
      with {:ok, entries} when is_map(entries) <- JsonStore.read(journal, %{}),
           {:ok, entry} <- read(target, pr, opts) do
        entry = fun.(entry)
        JsonStore.write!(journal, Map.put(entries, target, entry))
        {:ok, entry}
      else
        {:error, _} = error -> error
        _ -> {:error, :invalid_ci_recovery_journal}
      end
    end)
  rescue
    error -> {:error, {:ci_recovery_journal_failed, Exception.message(error)}}
  end

  @spec reserve_reruns(term(), pos_integer(), pos_integer(), pos_integer(), keyword()) :: :ok | {:error, :limit_reached | term()}
  def reserve_reruns(poll_id, count, per_poll, per_hour, opts) do
    journal = path(opts)
    now = Keyword.get(opts, :ci_recovery_now, System.system_time(:second))

    :global.trans({{__MODULE__, journal}, self()}, fn ->
      case JsonStore.read(journal, %{}) do
        {:ok, entries} when is_map(entries) -> reserve_from_journal(entries, poll_id, count, now, per_poll, per_hour, journal)
        {:error, _} = error -> error
        _ -> {:error, :invalid_ci_recovery_journal}
      end
    end)
  rescue
    error -> {:error, {:ci_recovery_journal_failed, Exception.message(error)}}
  end

  defp reserve_from_journal(entries, poll_id, count, now, per_poll, per_hour, journal) do
    reruns = get_in(entries, ["_limits", "reruns"]) || []

    case Enum.all?(reruns, &(is_map(&1) and is_integer(&1["at"]) and is_binary(&1["poll"]))) do
      true -> reserve_recent_rerun(entries, reruns, poll_id, count, now, per_poll, per_hour, journal)
      false -> {:error, :invalid_ci_recovery_limits}
    end
  end

  defp reserve_recent_rerun(entries, reruns, poll_id, count, now, per_poll, per_hour, journal) do
    recent = Enum.filter(reruns, &(now - &1["at"] < 3_600))
    poll_key = inspect(poll_id)

    current_poll = Enum.count(recent, &(&1["poll"] == poll_key))

    cond do
      count > per_poll or count > per_hour ->
        {:error, :ticket_exceeds_rerun_limit}

      current_poll + count > per_poll ->
        {:error, :poll_limit_reached}

      length(recent) + count > per_hour ->
        retry_at = recent |> Enum.min_by(& &1["at"]) |> Map.fetch!("at") |> Kernel.+(3_600)
        {:error, {:hour_limit_reached, retry_at}}

      true ->
        reservations = List.duplicate(%{"at" => now, "poll" => poll_key}, count)
        updated = Map.put(entries, "_limits", %{"reruns" => reservations ++ recent})
        JsonStore.write!(journal, updated)
        :ok
    end
  end

  defp path(opts), do: Keyword.get(opts, :ci_recovery_path, CIApprovalStore.path_for() <> ".recovery")
end
