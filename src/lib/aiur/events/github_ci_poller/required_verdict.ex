defmodule Aiur.Events.GithubCIPoller.RequiredVerdict do
  @moduledoc """
  Narrows a raw CI evaluation to what the required checks decide (#4200).

  A failing check that no ruleset or branch protection requires cannot block a
  merge, so it must not send the ticket to rework. A cancelled run with no
  newer run is missing CI, not failed CI.

  A cancelled run stays pending so the recovery layer can make one bounded
  rerun attempt for the current head.
  """

  alias Aiur.Events.GithubCIPoller.CancelledRun

  @spec settle(map(), [map()], String.t(), keyword()) :: map()
  def settle(result, runs, head_sha, opts) do
    if required_checks_unavailable?(opts),
      do: unavailable(result, opts),
      else: settle_known(result, runs, head_sha, opts)
  end

  defp settle_known(%{decision: :failed, failures: failures} = result, runs, _head_sha, opts) do
    cond do
      CancelledRun.cancelled?(%{"event" => "pull_request"}, runs) ->
        Map.merge(result, %{decision: :pending, pending_reason: :ci_cancelled, failures: []})

      required_failure?(failures, opts) ->
        result

      true ->
        %{result | decision: :passed, failures: []}
    end
  end

  defp settle_known(
         %{decision: :pending, pending_reason: :check_runs_incomplete, failures: failures} =
           result,
         runs,
         _head_sha,
         opts
       ) do
    cond do
      cancelled_only?(runs) and required_failure?(failures, opts) ->
        result |> Map.put(:decision, :failed) |> Map.delete(:pending_reason)

      cancelled_only?(runs) ->
        %{result | pending_reason: :ci_cancelled, failures: []}

      true ->
        result
    end
  end

  defp settle_known(result, _runs, _head_sha, _opts), do: result

  defp required_checks_unavailable?(opts),
    do: match?({:error, _}, Keyword.fetch!(opts, :required_checks))

  defp unavailable(result, opts) do
    {:error, reason} = Keyword.fetch!(opts, :required_checks)

    Map.merge(result, %{
      decision: :pending,
      pending_reason: :required_checks_unavailable,
      failures: [],
      error: reason
    })
  end

  @spec passed?(%{name: String.t(), app_id: integer() | nil}, [map()], [map()]) :: boolean()
  def passed?(%{name: name, app_id: app_id}, runs, statuses) do
    Enum.any?(runs, fn run ->
      Map.get(run, "name") == name and Map.get(run, "status") == "completed" and
        Map.get(run, "conclusion") in ~w(success neutral) and
        (app_id in [nil, -1] or get_in(run, ["app", "id"]) == app_id)
    end) or
      (app_id in [nil, -1] and
         Enum.any?(
           statuses,
           &(Map.get(&1, "context") == name and Map.get(&1, "state") == "success")
         ))
  end

  # With no required checks configured, every failure decides. A failed read
  # is quarantined before this fallback can classify any failure.
  defp required_failure?(failures, opts) do
    case Keyword.fetch!(opts, :required_checks) do
      {:ok, [_ | _] = required} ->
        names = MapSet.new(required, & &1.name)
        Enum.any?(failures, &(&1.name in names))

      _ ->
        failures != []
    end
  end

  defp cancelled_only?(runs) do
    Enum.all?(runs, &(Map.get(&1, "status") == "completed")) and
      Enum.any?(runs, &(Map.get(&1, "conclusion") == "cancelled"))
  end
end
