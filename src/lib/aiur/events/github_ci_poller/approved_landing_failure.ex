defmodule Aiur.Events.GithubCIPoller.ApprovedLandingFailure do
  @moduledoc false

  alias Aiur.Events.GithubCIPoller.BaseCause
  alias Aiur.GitHub.CIRecoveryStore

  @spec landing_state(map(), map()) :: :landing | :not_landing | :changed_head | :unknown
  def landing_state(result, pr) do
    cond do
      pr["state"] != "OPEN" or pr["headRefOid"] != result[:head_sha] -> :changed_head
      is_map(pr["autoMergeRequest"]) or is_map(pr["mergeQueueEntry"]) -> :landing
      Map.has_key?(pr, "autoMergeRequest") and Map.has_key?(pr, "mergeQueueEntry") -> :not_landing
      true -> :unknown
    end
  end

  @spec route_or_hold(map(), map(), keyword()) :: {:routed, map()} | {:hold, atom()} | {:attention, atom(), term(), atom()}
  def route_or_hold(issue, result, opts) do
    classifications = BaseCause.classify_checks(result, opts)

    if classifications != [] and Enum.all?(classifications, &(&1.class == :caused_by_pr)) and not contains_infrastructure_failure?(result) do
      failures = Map.get(result, :failures, [])
      caused = MapSet.new(classifications, & &1.name)
      annotated = Enum.map(failures, &Map.put(&1, :pr_caused?, MapSet.member?(caused, &1.name)))
      withdraw_and_route(issue, Map.put(result, :failures, annotated), opts)
    else
      cause = if Enum.any?(classifications, &(&1.class == :inherited)), do: :inherited, else: :unknown
      {:hold, cause}
    end
  end

  @spec all_infrastructure_failures?(map()) :: boolean()
  def all_infrastructure_failures?(%{failures: [_ | _] = failures}), do: Enum.all?(failures, &infrastructure_failure?/1)
  def all_infrastructure_failures?(_result), do: false

  @spec contains_infrastructure_failure?(map()) :: boolean()
  def contains_infrastructure_failure?(%{failures: failures}) when is_list(failures), do: Enum.any?(failures, &infrastructure_failure?/1)
  def contains_infrastructure_failure?(_result), do: false

  defp withdraw_and_route(issue, result, opts) do
    case Keyword.get(opts, :withdraw_landing, &Aiur.CodeHost.withdraw_landing/1).(result.pr_number) do
      {:ok, _actions} ->
        result = Map.merge(result, %{approved_landing_withdrawn?: true, ci_recovery_opts: opts})

        case CIRecoveryStore.update(
               to_string(issue.identifier || issue.id),
               result.pr_number,
               &(&1 |> Map.put("landing_hold", result.head_sha) |> Map.delete("landing_hold_cause") |> Map.delete("hold")),
               opts
             ) do
          {:ok, _} -> {:routed, Map.merge(result, %{decision: :failed, recovery: nil})}
          {:error, reason} -> {:attention, :journal_failed, reason, :default}
        end

      {:error, reason, _actions} ->
        {:attention, :landing_withdrawal_failed, reason, :landing}

      {:error, reason} ->
        {:attention, :landing_withdrawal_failed, reason, :landing}
    end
  end

  defp infrastructure_failure?(failure) do
    failure[:result] in ["cancelled", "timed_out", "startup_failure"] or
      (is_binary(failure[:excerpt]) and String.match?(failure[:excerpt], ~r/(?:ECONNRESET|runner.*lost|artifact.*upload.*(?:error|failed))/i))
  end
end
