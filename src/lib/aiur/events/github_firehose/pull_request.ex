defmodule Aiur.Events.GithubFirehose.PullRequest do
  @moduledoc false

  alias Aiur.Events.GithubKeys
  alias Aiur.Events.PostDeployChecks
  alias Aiur.RecentMerge

  @spec translate(map(), keyword()) :: {String.t(), map(), keyword()} | nil
  def translate(%{"type" => "PullRequestEvent"} = event, opts) do
    action = get_in(event, ["payload", "action"])
    pr = get_in(event, ["payload", "pull_request"]) || %{}
    head_ref = get_in(pr, ["head", "ref"]) || ""
    head_sha = get_in(pr, ["head", "sha"]) || ""
    actor = get_in(event, ["actor", "login"])
    repo_name = get_in(event, ["repo", "name"]) || Keyword.get(opts, :repo)
    pr_number = Map.get(pr, "number")
    merged? = merged_pull_request_event?(action, Map.get(pr, "merged"))

    case pull_request_target(pr, head_ref, repo_name, action, merged?) do
      {id, topic} ->
        publish_opts = [
          actor: actor,
          issue_number: id,
          bypass_contamination: merged?,
          dedup_key: pr_dedup_key(repo_name, pr_number, action, head_sha, id, merged?)
        ]

        payload = %{action: action, pr: pr, timestamp: Map.get(event, "created_at"), repository: repo_name}
        payload = if merged?, do: Map.put(payload, :post_deploy_checks, PostDeployChecks.from_pr_body(Map.get(pr, "body"))), else: payload
        {topic, payload, publish_opts}

      nil ->
        nil
    end
  end

  def translate(_event, _opts), do: nil

  defp pr_issue_links(pr, repo_name) do
    commit_messages = Map.get(pr, "commit_messages", [])

    closing_ids =
      [Map.get(pr, "body") | commit_messages]
      |> Enum.flat_map(&RecentMerge.closing_issue_identifiers_in_body(&1, repo_name))
      |> Enum.uniq()

    linked_ids =
      RecentMerge.linked_issue_identifiers(
        struct(RecentMerge,
          summary: Map.get(pr, "body"),
          repository: repo_name,
          commit_messages: commit_messages
        )
      )

    {closing_ids, linked_ids}
  end

  defp pull_request_target(pr, head_ref, repo_name, action, merged?) do
    branch_id = Aiur.TicketBranch.ticket_id(head_ref)
    {closing_ids, linked_ids} = pr_issue_links(pr, repo_name)
    commit_messages_unavailable? = get_in(pr, ["commit_messages_unavailable"]) == true
    linked_ids = if commit_messages_unavailable?, do: [], else: linked_ids

    with id when is_binary(id) <-
           if(merged?, do: List.first(closing_ids) || branch_id || List.first(linked_ids), else: branch_id || List.first(closing_ids)),
         topic when is_binary(topic) <- pr_topic(id, action, Map.get(pr, "merged")) do
      {id, topic}
    else
      _ -> nil
    end
  end

  defp pr_topic(id, "opened", _merged), do: "ticket.#{id}.pr.opened"
  defp pr_topic(id, "ready_for_review", _merged), do: "ticket.#{id}.pr.ready_for_review"
  defp pr_topic(id, "reopened", _merged), do: "ticket.#{id}.pr.reopened"
  defp pr_topic(id, "merged", _merged), do: "ticket.#{id}.pr.merged"
  defp pr_topic(id, "closed", true), do: "ticket.#{id}.pr.merged"
  defp pr_topic(id, "closed", false), do: "ticket.#{id}.pr.closed_unmerged"
  defp pr_topic(_id, _action, _merged), do: nil

  defp pr_dedup_key(repo, pr_number, action, head_sha, _ticket, false),
    do: GithubKeys.pr_dedup_key(repo, pr_number, action, head_sha)

  defp pr_dedup_key(repo, pr_number, action, head_sha, ticket, true),
    do: GithubKeys.pr_dedup_key(repo, pr_number, action, head_sha, ticket)

  # GitHub's Events API emits sparse merge notifications as action=merged.
  # Retain the older closed+merged form for replay compatibility.
  defp merged_pull_request_event?("merged", _merged), do: true
  defp merged_pull_request_event?("closed", true), do: true
  defp merged_pull_request_event?(_action, _merged), do: false
end
