defmodule Aiur.GitHub.StaleApprovedHead do
  @moduledoc "Disarms auto-merge when a pushed PR head changes its approved contribution."

  alias Aiur.Alerts
  alias Aiur.Events.GithubCIPoller
  alias Aiur.GitHub.{LandingWithdrawal, Transport}

  @spec reconcile(String.t(), integer(), keyword()) :: :ok
  def reconcile(ticket, pr_number, opts \\ []) do
    with {:ok, %{head_sha: head, approved_head_sha: approved, auto_merge?: true}} <- read_pr(pr_number, opts),
         true <- is_binary(head) and is_binary(approved) and head != approved,
         {:changed, %{reason: reason, hunks: hunks}} <- classify(approved, head, pr_number, opts) do
      withdraw(ticket, pr_number, approved, head, reason, hunks, opts)
    else
      _unchanged_or_unavailable -> :ok
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

  defp read_pr(pr_number, opts) do
    query =
      "query AiurStaleApprovedHead($owner: String!, $name: String!, $number: Int!) { repository(owner: $owner, name: $name) { pullRequest(number: $number) { state headRefOid reviewDecision autoMergeRequest { enabledAt } reviews(states: APPROVED, last: 1) { nodes { commit { oid } } } } } }"

    with {:ok, token} <- Transport.require_token(opts),
         {:ok, {owner, name}} <- Transport.parse_repo(),
         {:ok, body} <-
           Transport.github_graphql(Keyword.get(opts, :request_fun, &Transport.default_request_fun/1), token, query, %{"owner" => owner, "name" => name, "number" => pr_number},
             caller: "stale_approved_head"
           ),
         %{"state" => "OPEN", "headRefOid" => head, "reviewDecision" => "APPROVED", "autoMergeRequest" => %{}, "reviews" => %{"nodes" => nodes}} <- get_in(body, ["data", "repository", "pullRequest"]),
         [%{"commit" => %{"oid" => approved}}] <- nodes,
         true <- is_binary(head) and is_binary(approved) do
      {:ok, %{head_sha: head, approved_head_sha: approved, auto_merge?: true}}
    else
      {:error, _reason} = error -> error
      _other -> {:error, :approval_or_auto_merge_unconfirmed}
    end
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
end
