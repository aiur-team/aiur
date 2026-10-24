defmodule Aiur.GitHub.HumanReviewEvidence do
  @moduledoc false

  alias Aiur.Events.GithubCIPoller.ApprovalCarry
  alias Aiur.GitHub.Transport
  alias Aiur.LocalTestEvidence

  @spec verify(map(), map()) :: :ok | {:error, term()}
  def verify(context, %{"head" => %{"sha" => head}, "body" => body} = pr)
      when is_binary(head) and is_binary(body) do
    case LocalTestEvidence.parse(body) do
      {:ok, evidence} ->
        verify_tested_head(context, pr, evidence, head)

      :missing ->
        stale(pr, head, nil, "Local tests section is missing")

      {:error, reason} ->
        stale(pr, head, nil, reason)
    end
  end

  def verify(_context, %{"number" => number}),
    do: {:error, {:stale_pr_body_evidence, %{pr_number: number, reason: "PR head or body is missing"}}}

  defp verify_tested_head(context, pr, evidence, head) do
    case LocalTestEvidence.validate(evidence, "none", head) do
      :ok ->
        :ok

      {:error, reason} ->
        if identical_contribution_after_merge_only_advance?(context, pr, evidence.tested_head, head),
          do: :ok,
          else: stale(pr, head, evidence.tested_head, reason)
    end
  end

  defp identical_contribution_after_merge_only_advance?(context, %{"number" => number}, tested_head, head)
       when is_integer(number) do
    case compare_commits(context, tested_head, head) do
      {:ok, %{"status" => "ahead", "total_commits" => count, "commits" => commits}}
      when is_integer(count) and count > 0 and length(commits) == count ->
        merge_only_commits?(commits) and identical_pr_contribution?(context, tested_head, head, number)

      _ ->
        false
    end
  end

  defp identical_contribution_after_merge_only_advance?(_context, _pr, _tested_head, _head), do: false

  defp merge_only_commits?(commits) do
    Enum.all?(commits, fn commit ->
      case Map.get(commit, "parents") do
        parents when is_list(parents) -> length(parents) > 1
        _missing_or_invalid -> false
      end
    end)
  end

  defp identical_pr_contribution?(context, tested_head, head, number) do
    opts = Keyword.merge(context.opts, request_fun: context.request_fun, token: context.token)
    ApprovalCarry.classify_contribution(tested_head, head, number, opts) == :identical
  end

  defp compare_commits(context, ancestor, head) do
    with {:ok, {owner, repo}} <- Transport.parse_repo() do
      url = "#{Transport.base_url()}/repos/#{owner}/#{repo}/compare/#{ancestor}...#{head}?per_page=100"
      Transport.fetch_json_map(context.request_fun, context.token, url, caller: "human_review_evidence_advance")
    end
  end

  defp stale(pr, head, tested_head, reason) do
    {:error, {:stale_pr_body_evidence, %{pr_number: pr["number"], head_sha: head, tested_head: tested_head, body_update_line: "Tested head: #{head}", reason: reason}}}
  end
end
