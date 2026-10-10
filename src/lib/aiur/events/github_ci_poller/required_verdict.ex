defmodule Aiur.Events.GithubCIPoller.RequiredVerdict do
  @moduledoc """
  Narrows a raw CI evaluation to what the required checks decide (#4200).

  A failing check that no ruleset or branch protection requires cannot block a
  merge, so it must not send the ticket to rework. A cancelled run with no
  newer run is missing CI, not failed CI: the workflow is re-run through the
  API rather than handed to a worker, whose only tool is a push.
  """

  require Logger

  alias Aiur.GitHub.Transport

  @spec settle(map(), [map()], String.t(), keyword()) :: map()
  def settle(%{decision: :failed, failures: failures} = result, _runs, _head_sha, opts) do
    if required_failure?(failures, opts), do: result, else: %{result | decision: :passed, failures: []}
  end

  def settle(%{decision: :pending, pending_reason: :check_runs_incomplete, failures: failures} = result, runs, head_sha, opts) do
    if cancelled_only?(runs) and not required_failure?(failures, opts) do
      rerun_cancelled(head_sha, opts)
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

  # ponytail: no per-head memory. A successful re-run leaves the run queued, so
  # the next poll no longer sees it cancelled; a refused re-run is retried (two
  # calls) every poll until the ci-wait re-wake. Remember the head if that costs.
  defp rerun_cancelled(head_sha, opts) do
    with {:ok, {owner, repo}} <- repo(Keyword.get(opts, :repo)),
         {:ok, token} <- Transport.require_token(opts) do
      request_fun = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)
      base = "#{Transport.base_url()}/repos/#{owner}/#{repo}/actions/runs"

      request_fun
      |> Transport.fetch_json_map(token, "#{base}?head_sha=#{head_sha}&per_page=100", caller: "ci_cancelled_rerun")
      |> rerun_latest_cancelled(request_fun, token, base, head_sha)
    end
  end

  defp rerun_latest_cancelled({:ok, %{"workflow_runs" => workflow_runs}}, request_fun, token, base, head_sha) when is_list(workflow_runs) do
    workflow_runs
    |> Enum.group_by(&Map.get(&1, "workflow_id"))
    |> Enum.map(fn {_workflow, runs} -> Enum.max_by(runs, &Map.get(&1, "run_started_at", "")) end)
    |> Enum.filter(&(Map.get(&1, "conclusion") == "cancelled"))
    |> Enum.each(&rerun(request_fun, token, "#{base}/#{Map.get(&1, "id")}/rerun", head_sha))
  end

  defp rerun_latest_cancelled(other, _request_fun, _token, _base, head_sha) do
    Logger.warning("GithubCIPoller cancelled-run lookup failed: head_sha=#{head_sha} reason=#{inspect(other)}")
  end

  defp rerun(request_fun, token, url, head_sha) do
    request = Transport.put_caller(%{method: :post, url: url, token: token, body: %{}}, caller: "ci_cancelled_rerun")

    case request_fun.(request) do
      {:ok, %{status: 201}} -> Logger.info("GithubCIPoller re-ran cancelled workflow: head_sha=#{head_sha} url=#{url}")
      other -> Logger.warning("GithubCIPoller re-run refused: head_sha=#{head_sha} url=#{url} reason=#{inspect(other)}")
    end
  end

  defp repo(nil), do: Transport.parse_repo()

  defp repo(repo) when is_binary(repo) do
    case String.split(repo, "/") do
      [owner, name] -> {:ok, {owner, name}}
      _ -> {:error, {:invalid_github_repo, repo}}
    end
  end
end
