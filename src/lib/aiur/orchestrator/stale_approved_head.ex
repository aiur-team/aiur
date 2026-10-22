defmodule Aiur.Orchestrator.StaleApprovedHead do
  @moduledoc "Disarms auto-merge when a pushed PR head changes its approved contribution."

  alias Aiur.Alerts
  alias Aiur.Events.GithubCIPoller
  alias Aiur.GitHub.LandingWithdrawal

  @read_retries 2
  @read_retry_delay_ms 200

  @spec reconcile(String.t(), integer(), keyword()) :: :ok
  def reconcile(ticket, pr_number, opts \\ []) do
    if Aiur.Instance.skip?(ticket, nil, :stale_approved_head), do: :ok, else: check(ticket, pr_number, opts)
  end

  defp check(ticket, pr_number, opts) do
    case read_approved_head(pr_number, opts, @read_retries) do
      {:ok, %{head_sha: head, approved_head_sha: approved}} ->
        case classify(approved, head, pr_number, opts) do
          {:changed, %{reason: reason, hunks: hunks}} -> withdraw(ticket, pr_number, approved, head, reason, hunks, opts)
          :identical -> :ok
        end

      :not_applicable ->
        :ok

      {:error, reason} ->
        emit_check_failure(ticket, pr_number, reason)
    end
  end

  @spec task_start_failed(String.t(), integer(), term()) :: :ok
  def task_start_failed(ticket, pr_number, reason) do
    emit_check_failure(ticket, pr_number, {:task_start, reason})
  end

  defp read_approved_head(pr_number, opts, retries_left) do
    case LandingWithdrawal.approved_auto_merge_head(pr_number, opts) do
      {:error, _reason} when retries_left > 0 ->
        Process.sleep(Keyword.get(opts, :read_retry_delay_ms, @read_retry_delay_ms))
        read_approved_head(pr_number, opts, retries_left - 1)

      result ->
        result
    end
  end

  defp withdraw(ticket, pr_number, approved, head, reason, hunks, opts) do
    case LandingWithdrawal.disable_auto_merge(pr_number, Keyword.put(opts, :caller, "stale_approved_head")) do
      {:ok, actions} -> notify_if_disabled(ticket, pr_number, approved, head, reason, hunks, actions)
      {:error, withdrawal_reason, _actions} -> emit_withdrawal_failure(ticket, pr_number, withdrawal_reason)
    end
  end

  defp notify_if_disabled(ticket, pr_number, approved, head, reason, hunks, actions) do
    if :auto_merge_disabled in actions, do: emit_stale(ticket, pr_number, approved, head, reason, hunks)
    :ok
  end

  defp classify(approved, head, pr_number, opts) do
    classifier = Keyword.get(opts, :contribution_classifier, &GithubCIPoller.classify_contribution/4)
    classifier.(approved, head, pr_number, opts)
  end

  defp emit_stale(ticket, pr_number, approved, head, reason, hunks) do
    files = Enum.map_join(hunks, ", ", & &1.file)
    details = if files == "", do: "Comparison reason: #{inspect(reason)}", else: "Changed files: #{files}"

    Alerts.emit_system("ticket.#{ticket}.agent.attention.stale_approved_pr_head",
      issue: ticket,
      message: "Auto-merge was disabled on PR ##{pr_number} after a push changed its approved contribution.",
      reason: "Approved commit `#{approved}` was replaced by `#{head}`. Review the new head and approve it again to re-enable auto-merge. #{details}",
      needs_attention: true,
      severity: "critical",
      central: true,
      head_sha: head
    )
  end

  defp emit_withdrawal_failure(ticket, pr_number, reason) do
    Alerts.emit_system("ticket.#{ticket}.agent.attention.landing_withdrawal_failed",
      issue: ticket,
      message: "Could not disable auto-merge on PR ##{pr_number} after its approved contribution changed",
      reason: "Disable auto-merge before the new head can merge (#{inspect(reason)}).",
      needs_attention: true,
      severity: "critical",
      central: true
    )
  end

  defp emit_check_failure(ticket, pr_number, reason) do
    Alerts.emit_system("ticket.#{ticket}.agent.attention.landing_withdrawal_failed",
      issue: ticket,
      message: "Could not verify or protect auto-merge on PR ##{pr_number} after a synchronize event",
      reason: "Review the PR's current head and disable auto-merge if it has not been approved (#{inspect(reason)}).",
      needs_attention: true,
      severity: "critical",
      central: true
    )
  end
end
