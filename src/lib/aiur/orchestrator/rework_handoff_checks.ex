defmodule Aiur.Orchestrator.ReworkHandoffChecks do
  @moduledoc false

  alias Aiur.Alerts
  alias Aiur.GitHub.CiReadiness
  alias Aiur.GitHub.Client, as: GitHubClient

  @failed_conclusions ~w(action_required failure startup_failure timed_out)

  @spec agent_handoff_blockers(String.t() | atom() | nil, String.t() | nil, keyword()) ::
          {:blocked, [String.t()]} | :allow
  def agent_handoff_blockers(dispatch_head, current_head, opts) do
    with true <- is_binary(dispatch_head) and dispatch_head not in ["", :pending, :lookup_failed],
         true <- current_head == dispatch_head,
         {:ok, required} when required != [] <- required_checks(opts),
         {:ok, %{check_runs: runs, commit_status: status}} <- ci_status(dispatch_head, opts) do
      failed = failed_required_checks(required, runs, Map.get(status, "statuses", []))
      if failed == [], do: :allow, else: {:blocked, failed}
    else
      _unknown_or_changed -> :allow
    end
  end

  @spec alert_no_op_rework(String.t(), String.t() | atom() | nil, String.t() | nil, keyword()) :: term()
  def alert_no_op_rework(issue_key, dispatch_head, current_head, opts) do
    case agent_handoff_blockers(dispatch_head, current_head, opts) do
      {:blocked, checks} -> no_op_rework_attention(issue_key, dispatch_head, checks, opts)
      :allow -> :ok
    end
  end

  defp required_checks(opts) do
    fetcher = Keyword.get(opts, :required_checks_fetcher, &CiReadiness.fetch_required_checks/1)
    fetcher.(Keyword.get(opts, :github_opts, []))
  end

  defp ci_status(head_sha, opts) do
    fetcher = Keyword.get(opts, :commit_ci_status_fetcher, &GitHubClient.fetch_commit_ci_status/1)
    fetcher.(head_sha)
  end

  defp failed_required_checks(required, runs, statuses) do
    runs = latest_check_runs(runs)

    Enum.flat_map(required, fn %{name: name, app_id: app_id} ->
      run_failed? =
        Enum.any?(
          runs,
          &(Map.get(&1, "name") == name and Map.get(&1, "status") == "completed" and Map.get(&1, "conclusion") in @failed_conclusions and
              (app_id in [nil, -1] or get_in(&1, ["app", "id"]) == app_id))
        )

      status_failed? = app_id in [nil, -1] and Enum.any?(statuses, &(Map.get(&1, "context") == name and Map.get(&1, "state") in ["error", "failure"]))
      if run_failed? or status_failed?, do: [name], else: []
    end)
    |> Enum.uniq()
  end

  defp latest_check_runs(runs) do
    runs
    |> Enum.reject(fn run ->
      name = Map.get(run, "name")
      is_binary(name) and String.ends_with?(String.downcase(String.trim(name)), "(non-blocking)")
    end)
    |> Enum.group_by(fn run ->
      {Map.get(run, "check_suite_id") || get_in(run, ["check_suite", "id"]) || Map.get(run, "id"), Map.get(run, "name")}
    end)
    |> Enum.map(fn {_key, grouped} -> Enum.max_by(grouped, &(Map.get(&1, "started_at") || Map.get(&1, "completed_at") || "")) end)
  end

  defp no_op_rework_attention(issue_key, head_sha, checks, opts) do
    emit_alert_fun = Keyword.get(opts, :emit_alert_fun, &Alerts.emit_system/2)

    emit_alert_fun.(
      "ticket.#{issue_key}.agent.attention.no_op_rework",
      issue: issue_key,
      message: "Rework for ticket #{issue_key} ended without a new PR head while required checks are failing on #{String.slice(head_sha, 0, 7)}: #{Enum.join(checks, ", ")}.",
      reason:
        "The rework hand-back was refused because the PR head is unchanged and required CI checks are failing. Inspect the latest Executor rework comment and failing checks, then make the requested fix or explain why it cannot be made.",
      needs_attention: true,
      severity: "warning",
      central: true
    )
  end
end
