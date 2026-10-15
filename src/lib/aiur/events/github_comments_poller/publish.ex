defmodule Aiur.Events.GithubCommentsPoller.Publish do
  @moduledoc """
  Builds and publishes the events `Aiur.Events.GithubCommentsPoller` emits.

  One function per comment kind, each naming the dedup key and durable
  resource identity that let the webhook pipe and the sweep agree on what has
  already been processed.
  """

  alias Aiur.Events.{GithubKeys, GithubReviewThreadIdentity, Publisher, Sanitizer}
  alias Aiur.GitHub.ResourceStore

  @doc false
  @spec publish_issue_comment(term(), map(), term()) :: term()
  def publish_issue_comment(target, comment, repo) when is_map(comment) do
    actor = get_in(comment, ["user", "login"])
    parent_number = parse_integer(target)

    publish_comment(
      "ticket.#{target}.issue.commented",
      %{issue_number: target, comment: comment},
      actor,
      issue_number: target,
      dedup_key: GithubKeys.comment_dedup_key(repo, "issue_comment", parent_number, Map.get(comment, "id")),
      resource: ResourceStore.key_for_repo(:issue_comment, repo, Map.get(comment, "id")),
      resource_version: resource_version(comment)
    )
  end

  @doc false
  @spec publish_pr_issue_comment(term(), term(), map(), term(), map()) :: term()
  def publish_pr_issue_comment(target, pr_number, comment, repo, review_context) when is_map(comment) do
    actor = get_in(comment, ["user", "login"])

    publish_comment(
      "ticket.#{target}.issue.commented",
      %{issue_number: target, comment: comment, pull_request: review_context},
      actor,
      issue_number: target,
      dedup_key: GithubKeys.comment_dedup_key(repo, "issue_comment", pr_number, Map.get(comment, "id")),
      resource: ResourceStore.key_for_repo(:issue_comment, repo, Map.get(comment, "id")),
      resource_version: resource_version(comment)
    )
  end

  @doc false
  @spec publish_pr_review_comment(term(), term(), map(), term(), map()) :: term()
  def publish_pr_review_comment(target, pr_number, comment, repo, review_context) when is_map(comment) do
    actor = get_in(comment, ["user", "login"])
    resource = pr_review_comment_resource(repo, comment)
    generation = GithubReviewThreadIdentity.unresolved_generation(resource)
    dedup_key = pr_review_comment_dedup_key(repo, pr_number, comment, generation)

    publish_comment(
      "ticket.#{target}.pr.review_comment",
      %{issue_number: target, comment: comment, pull_request: review_context},
      actor,
      issue_number: target,
      dedup_key: dedup_key,
      resource: resource,
      resource_version: GithubReviewThreadIdentity.resource_version(resource_version(comment), generation)
    )
  end

  @doc false
  @spec publish_pr_review_submission(term(), term(), map(), term(), map()) :: term()
  def publish_pr_review_submission(target, pr_number, review, repo, review_context) when is_map(review) do
    actor = get_in(review, ["user", "login"])
    review_id = Map.get(review, "id")
    dedup_key = GithubKeys.pr_review_dedup_key(repo, pr_number, review_id)

    publish_comment(
      "ticket.#{target}.pr.review_comment",
      %{issue_number: target, comment: review, pull_request: review_context},
      actor,
      issue_number: target,
      dedup_key: dedup_key,
      resource: ResourceStore.key_for_repo(:pr_review, repo, review_id),
      resource_version: resource_version(review)
    )
  end

  # The resource is the *thread* when the comment carries a thread id, matching
  # the webhook pipe's `Normalizer.review_comment_keys/3`: both name
  # `{:pr_review_thread, owner, repo, thread_id}` so the durable store closes
  # the cross-pipe, cross-restart gap for review threads the way it does for
  # comments (#2081). Where this poller keys per comment (no thread id), the
  # resource is the comment and matches the delivery's per-comment fallback.
  defp pr_review_comment_resource(repo, %{"review_thread_id" => thread_id})
       when is_binary(thread_id) and thread_id != "" do
    ResourceStore.key_for_repo(:pr_review_thread, repo, thread_id)
  end

  defp pr_review_comment_resource(repo, comment) when is_map(comment) do
    ResourceStore.key_for_repo(:pr_review_comment, repo, Map.get(comment, "id"))
  end

  # Pairs with the resource key to say *which version* of that resource was
  # processed. The sweep's `?since=` filter is on `updated_at`, so an edited
  # comment comes back around; without a version, identity alone would treat it
  # as a redelivery of the original and the edit would never reach the agent.
  # Mirrors `Normalizer.resource_version/1` so both pipes agree on the marker.
  defp resource_version(%{"updated_at" => updated_at}) when is_binary(updated_at) and updated_at != "", do: updated_at

  defp resource_version(%{"submitted_at" => submitted_at}) when is_binary(submitted_at) and submitted_at != "",
    do: submitted_at

  defp resource_version(_resource), do: nil

  defp pr_review_comment_dedup_key(repo, pr_number, %{"review_thread_id" => thread_id}, generation)
       when is_binary(thread_id) and thread_id != "" do
    GithubKeys.review_thread_dedup_key(repo, pr_number, thread_id, generation)
  end

  defp pr_review_comment_dedup_key(repo, pr_number, comment, _generation) when is_map(comment) do
    GithubKeys.comment_dedup_key(repo, "pr_review_comment", pr_number, Map.get(comment, "id"))
  end

  defp publish_comment(topic, payload, actor, publish_opts) do
    sanitized = Sanitizer.github_payload(payload, actor)

    publish_opts =
      publish_opts
      |> Keyword.put(:actor, actor)
      |> Keyword.put(:resource_source, :poll)
      |> Keyword.put(:bypass_contamination, true)

    Publisher.publish(topic, sanitized, publish_opts)
  end

  @doc false
  @spec parse_integer(term()) :: integer() | nil
  def parse_integer(value) when is_integer(value), do: value

  def parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> nil
    end
  end

  def parse_integer(_value), do: nil
end
