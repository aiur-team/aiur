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
    if Enum.all?(heads, fn {sha, attempt} -> is_binary(sha) and valid_attempt?(attempt) end) and valid_hold?(entry["hold"]) and is_list(Map.get(entry, "attentions", [])),
      do: {:ok, entry},
      else: {:error, :invalid_ci_recovery_entry}
  end

  defp normalize(%{"pr" => pr}, pr), do: {:error, :invalid_ci_recovery_entry}
  defp normalize(entry, pr) when is_map(entry), do: {:ok, %{"pr" => pr, "cycles" => 0, "heads" => %{}}}
  defp normalize(_, _), do: {:error, :invalid_ci_recovery_entry}

  defp valid_hold?(nil), do: true

  defp valid_hold?(%{"sha" => sha, "reason" => reason, "tests" => tests, "mode" => mode}),
    do: is_binary(sha) and is_binary(reason) and is_binary(tests) and mode in ["hold", "fallback"]

  defp valid_hold?(_), do: false
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

  defp path(opts), do: Keyword.get(opts, :ci_recovery_path, CIApprovalStore.path_for() <> ".recovery")
end
