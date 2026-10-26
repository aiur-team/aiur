defmodule Aiur.Events.GithubCIPoller.RepoWideFailure do
  @moduledoc "Identifies PR failures that exactly match the latest failing main run."

  @spec matches?(map(), keyword()) :: boolean()
  def matches?(%{ci_failure_digest: %{signature: signature}} = result, opts)
      when is_binary(signature) and signature != "" do
    history = Keyword.get_lazy(opts, :main_watch_history, &main_history/0)

    with history when is_list(history) <- history,
         %{digest: %{signature: ^signature}, checks: checks} <- latest_failure(history),
         true <- failed_jobs(result) != [],
         true <- Enum.all?(failed_jobs(result), &(&1 in failed_job_names(checks))) do
      true
    else
      _ -> false
    end
  end

  def matches?(_result, _opts), do: false

  defp latest_failure(history) do
    history
    |> Enum.filter(fn entry ->
      match?(%{digest: %{signature: signature}} when is_binary(signature) and signature != "", entry) and
        Enum.any?(Map.get(entry, :checks, []), &(&1.conclusion in ~w(failure timed_out action_required startup_failure)))
    end)
    |> Enum.max_by(&Map.get(&1, :completed_at, 0), fn -> nil end)
  end

  defp failed_jobs(result), do: result |> Map.get(:failures, []) |> Enum.map(& &1.name) |> Enum.uniq() |> Enum.sort()

  defp failed_job_names(checks), do: checks |> Enum.filter(&(&1.conclusion in ~w(failure timed_out action_required startup_failure))) |> Enum.map(& &1.name) |> Enum.uniq()

  defp main_history do
    if Aiur.MainWatch.enabled?(), do: Map.get(Aiur.MainWatch.state(), :history, []), else: :disabled
  end
end
