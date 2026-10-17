defmodule Aiur.GitHub.ReworkCICancel do
  @moduledoc """
  Cancels a rework ticket's queued and running PR checks.

  A ticket in rework will push again, so its current-head `ci` and `pr body`
  runs only hold runners the merge queue needs (#4814). Superseding pushes are
  already cancelled by the workflows' `concurrency` groups.
  """

  require Logger
  alias Aiur.GitHub.{CIRecovery, Client}

  @workflows ["ci", "pr body"]
  @active ["queued", "in_progress", "waiting", "requested", "pending"]

  @doc "Fire-and-forget cancel the poll diff runs when a ticket enters rework."
  @spec cancel_async(String.t()) :: :ok
  def cancel_async(issue_id) do
    if Aiur.Config.tracker_kind() == "github", do: start(issue_id)
    :ok
  end

  defp start(issue_id) do
    case Task.Supervisor.start_child(Aiur.TaskSupervisor, fn -> log(issue_id, cancel(issue_id)) end) do
      {:ok, _pid} -> :ok
      {:error, reason} -> Logger.warning("rework CI cancel not started issue=#{issue_id} reason=#{inspect(reason)}")
    end

    :ok
  end

  @spec cancel(String.t(), keyword()) :: {:ok, [integer()]} | {:error, term()}
  def cancel(issue_id, opts \\ []) do
    open_pr = Keyword.get(opts, :open_pr_fun, &Client.fetch_open_pull_request_for_branch/1)

    case open_pr.(issue_id) do
      {:ok, %{"head" => %{"sha" => sha}}} when is_binary(sha) -> cancel_head(sha, opts)
      {:ok, nil} -> {:ok, []}
      {:error, _} = error -> error
      _ -> {:error, :invalid_pull_request}
    end
  end

  defp cancel_head(sha, opts) do
    opts = Keyword.put_new(opts, :caller, "rework_ci_cancel")

    case CIRecovery.read("/actions/runs?head_sha=#{sha}&event=pull_request&per_page=100", opts) do
      {:ok, %{"workflow_runs" => runs}} when is_list(runs) ->
        cancel = Keyword.get(opts, :cancel_fun, &CIRecovery.cancel/2)

        ids =
          for %{"id" => id, "name" => name, "status" => status, "head_sha" => ^sha} <- runs,
              name in @workflows and status in @active,
              # A run that finished between the listing and the cancel answers 409; it no longer holds a runner.
              cancel.(id, opts) == :ok,
              do: id

        {:ok, ids}

      {:ok, _} ->
        {:error, :invalid_actions_runs_response}

      {:error, _} = error ->
        error
    end
  end

  defp log(issue_id, {:ok, ids}), do: Logger.info("rework CI cancel issue=#{issue_id} cancelled_runs=#{inspect(ids)}")
  defp log(issue_id, {:error, reason}), do: Logger.warning("rework CI cancel failed issue=#{issue_id} reason=#{inspect(reason)}")
end
