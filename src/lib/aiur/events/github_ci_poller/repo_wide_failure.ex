defmodule Aiur.Events.GithubCIPoller.RepoWideFailure do
  @moduledoc """
  Identifies PR failures matching the latest failing main run before ordinary routing.

  For checks without parsed test identities (for example workflow security, lint, or
  dialyzer), FailureDigest signatures are check-name level. A PR-specific failure
  in the same check can therefore match the main failure until main is green.
  """
  require Logger
  alias Aiur.Events.GithubCIPoller.BaseCause

  @spec matches?(map(), keyword()) :: boolean()
  def matches?(%{ci_failure_digest: %{signature: signature}} = result, opts)
      when is_binary(signature) and signature != "" do
    history = Keyword.get_lazy(opts, :main_watch_history, &BaseCause.main_watch_history/0)

    with history when is_list(history) <- history,
         %{digest: %{signature: ^signature}, checks: checks} <- latest_observation(history),
         true <- failed_jobs(result) != [],
         true <- Enum.all?(failed_jobs(result), &(&1 in failed_job_names(checks))) do
      true
    else
      _ -> false
    end
  end

  def matches?(_result, _opts), do: false

  @spec hold(map(), keyword()) :: :no_match | map()
  def hold(result, opts) do
    if matches?(result, opts) do
      alert_once(opts, result.ci_failure_digest.signature)
      result |> Map.put(:decision, :pending) |> Map.put(:pending_reason, :ci_recovery) |> Map.put(:recovery, "repo_wide_failure")
    else
      :no_match
    end
  end

  defp alert_once(opts, signature) do
    alias Aiur.{AlertFeed, Signal}
    suffix = :crypto.hash(:sha256, signature) |> Base.encode16(case: :lower) |> binary_part(0, 12)
    topic = "system.main.ci.repo_wide_failure.#{suffix}"
    message = "Required PR checks match the latest failing main run; affected PRs remain in CI wait until main is green."
    condition_state = Keyword.get(opts, :alert_condition_state, &AlertFeed.condition_state/2)

    if condition_state.(topic, opts) != :firing do
      emitter = Keyword.get(opts, :alert_emitter, &Signal.alert/2)

      case emitter.(topic, central: true, needs_attention: true, message: message, reason: message) do
        :ok -> :ok
        {:error, reason} -> Logger.warning("Repo-wide CI attention failed: #{inspect(reason)}")
        other -> Logger.warning("Repo-wide CI attention returned unexpected result: #{inspect(other)}")
      end
    end
  rescue
    error -> Logger.warning("Repo-wide CI attention failed: #{Exception.message(error)}")
  end

  defp latest_observation(history) do
    history
    |> Enum.filter(&match?(%{digest: %{signature: signature}} when is_binary(signature) and signature != "", &1))
    |> Enum.max_by(&Map.get(&1, :completed_at, 0), fn -> nil end)
  end

  defp failed_jobs(result), do: result |> Map.get(:failures, []) |> Enum.map(& &1.name) |> Enum.uniq() |> Enum.sort()

  defp failed_job_names(checks), do: checks |> Enum.filter(&(&1.conclusion in ~w(failure timed_out action_required startup_failure))) |> Enum.map(& &1.name) |> Enum.uniq()
end
