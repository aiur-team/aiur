defmodule Aiur.Events.GithubCIPoller.UnavailableCI do
  @moduledoc """
  Keeps a CI failure that says nothing about the code from sending its ticket
  to rework.

  - With `agent.ci_failed_rework: false` no CI failure reworks a ticket. A
    repository whose hosted Actions are off for good and whose CI runs in
    another loop sets it.
  - A check GitHub never started (`startup_failure`, or a job refused for
    billing or a spending limit) is missing CI, not failed CI. When every
    failed check is one of those, the verdict stays pending.

  Either way the result is pending with a named reason, so nothing reruns and
  the worker never receives the failure as rework.
  """

  require Logger

  alias Aiur.CI.FailureDigest
  alias Aiur.Config

  @not_started ~r/job was not started|recent account payments have failed|spending limit needs to be increased/i

  @spec settle(map(), keyword()) :: map()
  def settle(%{decision: :failed} = result, opts) do
    cond do
      not Keyword.get_lazy(opts, :ci_failed_rework, &Config.ci_failed_rework?/0) -> hold(result, :ci_failed_rework_disabled)
      not_started?(result, opts) -> hold(result, :ci_not_started)
      true -> result
    end
  end

  def settle(result, _opts), do: result

  defp hold(result, reason) do
    Logger.info("CI failure does not rework: pr=#{result[:pr_number]} head=#{result[:head_sha]} reason=#{reason} checks=#{inspect(Enum.map(result[:failures] || [], & &1[:name]))}")

    result
    |> Map.delete(:checks_incomplete)
    |> Map.merge(%{decision: :pending, pending_reason: reason, failures: []})
  end

  defp not_started?(%{failures: [_ | _] = failures} = result, opts) do
    case Enum.reject(failures, &(&1[:result] == "startup_failure")) do
      [] -> true
      started -> Enum.all?(started, &refusal_shaped?/1) and MapSet.subset?(MapSet.new(started, & &1[:name]), MapSet.new(refused_checks(result, opts)))
    end
  end

  defp not_started?(_result, _opts), do: false

  # A refused job ends seconds after it starts and leaves no summary. Only such
  # failures are worth an annotation read; anything else is a real run.
  @refusal_window_s 15

  defp refusal_shaped?(%{excerpt: excerpt} = failure) when excerpt in [nil, ""] do
    with {:ok, started, _} <- DateTime.from_iso8601(to_string(failure[:started_at])),
         {:ok, completed, _} <- DateTime.from_iso8601(to_string(failure[:completed_at])) do
      DateTime.diff(completed, started) <= @refusal_window_s
    else
      _ -> false
    end
  end

  defp refusal_shaped?(_failure), do: false

  # Names of the failed checks whose every error line is GitHub refusing to start the job.
  defp refused_checks(%{head_sha: sha}, opts) when is_binary(sha) do
    case Keyword.get(opts, :ci_failure_digest, &FailureDigest.build/2).(sha, opts) do
      {:ok, %{checks: checks}} when is_list(checks) ->
        for %{name: name} = check <- checks, refused?(Map.get(check, :errors, [])), do: name

      _unreadable ->
        []
    end
  end

  defp refused_checks(_result, _opts), do: []

  defp refused?([_ | _] = lines), do: Enum.all?(lines, &String.match?(&1, @not_started))
  defp refused?(_lines), do: false
end
