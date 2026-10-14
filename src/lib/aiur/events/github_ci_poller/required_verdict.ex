defmodule Aiur.Events.GithubCIPoller.RequiredVerdict do
  @moduledoc """
  Narrows a raw CI evaluation to what the required checks decide (#4200).

  A failing check that no ruleset or branch protection requires cannot block a
  merge, so it must not send the ticket to rework. A cancelled run with no
  newer run is missing CI, not failed CI.

  A cancelled run stays pending for operator action; polling never reverses a
  cancellation by starting the run again.
  """

  @spec settle(map(), [map()], String.t(), keyword()) :: map()
  def settle(%{decision: :failed, failures: failures} = result, _runs, _head_sha, opts) do
    if required_failure?(failures, opts), do: result, else: %{result | decision: :passed, failures: []}
  end

  def settle(%{decision: :pending, pending_reason: :check_runs_incomplete, failures: failures} = result, runs, _head_sha, opts) do
    if cancelled_only?(runs) and not required_failure?(failures, opts) do
      %{result | pending_reason: :ci_cancelled, failures: []}
    else
      result
    end
  end

  def settle(result, _runs, _head_sha, _opts), do: result

  @spec passed?(%{name: String.t(), app_id: integer() | nil}, [map()], [map()]) :: boolean()
  def passed?(%{name: name, app_id: app_id}, runs, statuses) do
    Enum.any?(runs, fn run ->
      Map.get(run, "name") == name and Map.get(run, "status") == "completed" and
        Map.get(run, "conclusion") in ~w(success neutral) and
        (app_id in [nil, -1] or get_in(run, ["app", "id"]) == app_id)
    end) or
      (app_id in [nil, -1] and Enum.any?(statuses, &(Map.get(&1, "context") == name and Map.get(&1, "state") == "success")))
  end

  # With no required list (none configured, or the read failed) every failure
  # decides, as it did before required checks were known.
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
