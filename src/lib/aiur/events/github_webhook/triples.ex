defmodule Aiur.Events.GithubWebhook.Triples do
  @moduledoc """
  The `{topic, payload, publish_opts}` triples a webhook delivery publishes,
  and the comment and review shapes it stores.

  These must stay byte-identical to their poller twins: this is the one place
  the webhook restates a shape `Aiur.Events.GithubCommentsPoller` and
  `Aiur.Events.GithubFirehose` build from their own code. See
  `Aiur.Events.GithubWebhook.Normalizer` for why one shape has two producers.
  """

  alias Aiur.Events.{GithubKeys, GithubReviewThreadIdentity}
  alias Aiur.Events.GithubWebhook.Identity
  alias Aiur.GitHub.ResourceStore

  @type triple :: {String.t(), map(), keyword()}
  @type result :: {:publish, [triple()]} | {:drop, term()} | {:error, term()}

  @spec issue_comment_triple(map(), map(), String.t()) :: result()
  def issue_comment_triple(issue, comment, repo) do
    pull_request? = is_map(Map.get(issue, "pull_request"))
    number = Identity.ticket_identifier(Map.get(issue, "number"))

    target =
      if pull_request?,
        do: Identity.ticket_from_pr_body(Map.get(issue, "body")),
        else: number

    cond do
      is_nil(number) ->
        {:error, {:malformed_payload, "issue_comment"}}

      is_nil(target) ->
        {:drop, {:unresolved_ticket, "issue_comment", number}}

      true ->
        {:publish,
         [
           comment_triple(
             "ticket.#{target}.issue.commented",
             target,
             poller_comment_shape(comment),
             GithubKeys.comment_dedup_key(repo, "issue_comment", String.to_integer(number), Map.get(comment, "id")),
             if(pull_request?, do: review_context(Map.get(issue, "pull_request"))),
             ResourceStore.key_for_repo(:issue_comment, repo, Map.get(comment, "id"))
           )
         ]}
    end
  end

  # Deliberately NOT projected through `poller_comment_shape/1`. Review
  # submissions are the one comment topic the poller does not normalize: it
  # fetches `/pulls/N/reviews` over REST and publishes the review object as-is,
  # so the delivery's own REST review is already the matching shape. Projecting
  # here would drop `state` and `submitted_at`, which decide CHANGES_REQUESTED
  # routing and `ReviewFreshness` staleness respectively.
  @spec review_submission_triple(map(), map(), String.t()) :: result()
  def review_submission_triple(payload, review, repo) do
    with {:ok, target, pr_number} <- Identity.pull_request_identity(payload) do
      {:publish,
       [
         comment_triple(
           "ticket.#{target}.pr.review_comment",
           target,
           upcase_review_state(review),
           GithubKeys.pr_review_dedup_key(repo, pr_number, Map.get(review, "id")),
           review_context(Map.get(payload, "pull_request")),
           ResourceStore.key_for_repo(:pr_review, repo, Map.get(review, "id"))
         )
       ]}
    end
  end

  # One granularity, both pipes. `GithubCommentsPoller` keys review thread
  # comments on the GraphQL thread node id, and the delivery path resolves that
  # id for webhook deliveries (`Aiur.Events.GithubWebhook.ThreadResolver`), so
  # the two pipes derive the same key for the same event and `Publisher`
  # collapses them into one wake.
  #
  # Thread is the deliberate granularity (see #2081). A review thread is
  # GitHub's own unit of feedback — one finding plus its replies — and keying
  # per comment would multiply wakes for a multi-comment review, which is a real
  # cost, not neutral correctness. The tradeoff: a follow-up comment on an
  # already-woken thread within the replay window does not wake a second time.
  #
  # A delivery whose thread could not be resolved (no `node_id`, or a failed
  # lookup) keys per comment — the fail-open degradation, unchanged from before
  # this change. A duplicate wake is recoverable; a dropped delivery is not.
  @spec review_comment_triple(map(), map(), String.t()) :: result()
  def review_comment_triple(payload, comment, repo) do
    with {:ok, target, pr_number} <- Identity.pull_request_identity(payload) do
      {dedup_key, resource, version} = review_comment_keys(repo, pr_number, comment)

      {:publish,
       [
         comment_triple(
           "ticket.#{target}.pr.review_comment",
           target,
           poller_comment_shape(comment),
           dedup_key,
           payload |> Map.get("pull_request") |> review_context() |> approval_only_context(),
           resource,
           version
         )
       ]}
    end
  end

  defp review_comment_keys(repo, pr_number, %{"review_thread_id" => thread_id})
       when is_binary(thread_id) and thread_id != "" do
    resource = ResourceStore.key_for_repo(:pr_review_thread, repo, thread_id)
    generation = GithubReviewThreadIdentity.unresolved_generation(resource)

    {
      GithubKeys.review_thread_dedup_key(repo, pr_number, thread_id, generation),
      resource,
      generation
    }
  end

  defp review_comment_keys(repo, pr_number, comment) when is_map(comment) do
    {
      GithubKeys.comment_dedup_key(repo, "pr_review_comment", pr_number, Map.get(comment, "id")),
      ResourceStore.key_for_repo(:pr_review_comment, repo, Map.get(comment, "id")),
      nil
    }
  end

  # GithubCommentsPoller.publish_comment/4: payload keyed by the ticket
  # identifier string, actor from the comment author, contamination bypassed so
  # an inbound human comment can reactivate a deactivated ticket.
  defp comment_triple(topic, target, comment, dedup_key, review_context, resource, generation \\ nil) do
    actor = get_in(comment, ["user", "login"])

    payload =
      case review_context do
        %{} = context -> %{issue_number: target, comment: comment, pull_request: context}
        nil -> %{issue_number: target, comment: comment}
      end

    # `:resource` names the GitHub object this delivery *is*, so the poll sweep
    # that later re-reads the same object recognises it as already handled. It
    # is the free pipe's contribution to the expensive one: a delivery costs
    # nothing and arrives first, so it is the right writer of that fact.
    #
    # `:resource_version` is what keeps that from over-reaching. This module
    # normalizes `edited` deliveries as well as `created` ones, and an edit
    # keeps the comment's id, so identity alone would make an edited comment
    # look like a redelivery of the original and swallow it.
    {topic, payload,
     [
       issue_number: target,
       dedup_key: dedup_key,
       resource: resource,
       resource_version: GithubReviewThreadIdentity.resource_version(resource_version(comment), generation),
       resource_source: :webhook,
       actor: actor,
       bypass_contamination: true
     ]}
  end

  # `updated_at` for comments; a review submission has no `updated_at`, and its
  # `submitted_at` is the marker the poller's own cutoff already keys on.
  defp resource_version(%{"updated_at" => updated_at}) when is_binary(updated_at) and updated_at != "", do: updated_at
  defp resource_version(%{"submitted_at" => submitted_at}) when is_binary(submitted_at) and submitted_at != "", do: submitted_at
  defp resource_version(_comment), do: nil

  # Project a delivery's comment onto the shape the poller publishes.
  #
  # The poller never publishes GitHub's raw comment object: `CommentPollBatch`
  # reads comments over GraphQL and `normalize_comments/1` reduces each to
  # exactly these keys. A REST delivery carries roughly twice as many —
  # `node_id`, `url`, `issue_url`, `author_association`, `reactions`,
  # `performed_via_github_app` — and a full `user` object rather than a bare
  # login. Publishing the delivery as-is therefore hands consumers a visibly
  # different comment for the same GitHub event, which is precisely the drift
  # this module exists to prevent.
  #
  # Keys are taken one for one from `CommentPollBatch.normalize_comments/1`,
  # including its `body` and `updated_at` fallbacks. `line` and `path` ride along
  # only when present, matching `ReviewThreads.normalize_thread_comment/2` for
  # review threads while staying absent on issue comments, which is where the
  # poller leaves them. `review_thread_id` is the same: it is present on every
  # thread comment the poller publishes, and the delivery path stamps it on a
  # resolved review-comment delivery, so the published webhook comment matches
  # the poller's shape.
  defp poller_comment_shape(comment) when is_map(comment) do
    base = %{
      "id" => Map.get(comment, "id"),
      "body" => Map.get(comment, "body") || "",
      "created_at" => Map.get(comment, "created_at"),
      "updated_at" => Map.get(comment, "updated_at") || Map.get(comment, "created_at"),
      "html_url" => Map.get(comment, "html_url"),
      "user" => %{"login" => get_in(comment, ["user", "login"])}
    }

    Enum.reduce(["path", "line", "review_thread_id"], base, fn key, acc ->
      case Map.fetch(comment, key) do
        {:ok, value} -> Map.put(acc, key, value)
        :error -> acc
      end
    end)
  end

  defp poller_comment_shape(comment), do: comment

  @doc """
  The poller's comment shape for one delivered comment.

  Public for `Aiur.Events.GithubWebhook.Deposit`, which writes the delivered
  comment into the resource store. A stored comment has to be the same shape as
  a published one for the same reason a published one does: a consumer must not
  be able to tell which producer paid for it.
  """
  @spec comment_shape(term()) :: term()
  def comment_shape(comment), do: poller_comment_shape(comment)

  @doc """
  The poller's review shape for one delivered review.

  Same contract as `comment_shape/1`, for the one topic the poller publishes
  unprojected: only the `state` casing differs between the two producers.
  """
  @spec review_shape(term()) :: term()
  def review_shape(review), do: upcase_review_state(review)

  # Review-staleness context for the orchestrator's rework gate
  # (`Aiur.Orchestrator.ReviewFreshness`), mirroring
  # GithubCommentsPoller.review_context/1 key for key.
  #
  # A webhook delivery carries the REST pull request object, which exposes
  # neither `reviewDecision` nor the head commit date, so both read nil — the
  # same fail-open state the poller publishes on its REST fallback path, where
  # the gate stays inert and routing behaves as it did before the gate existed.
  # Reading through `Map.get/2` rather than hardcoding nil keeps the two
  # producers converging automatically if a delivery ever carries the fields.
  #
  # For `head_committed_at` failing open is correct by construction: a push
  # delivery *is* the review or comment that just happened, so it cannot be a
  # judgement about an older head and there is nothing for the staleness half of
  # the gate to suppress.
  #
  # `review_decision` is a genuine divergence, and a wider one than "PR-attached
  # issue comments" — it applies to every comment topic this module publishes.
  # `reviewDecision` is GraphQL-only, so no delivery can carry it: on an APPROVED
  # pull request the poller's batch path publishes `"APPROVED"` and suppresses
  # rework, while the webhook publishes nil and routes the ticket to rework for
  # the same GitHub event. Pinned by the `review_decision` case in
  # `github_webhook_equivalence_test.exs`.
  #
  # This is not closable inside the normalizer, which is pure: it needs a GraphQL
  # fetch in the delivery path, which lands on the W-1 receiver's request path
  # and interacts with W-4's ordering work. Reported on the PR rather than
  # silently absorbed. Reading through `Map.get/2` rather than hardcoding nil
  # means the fix is a matter of enriching the map before it reaches here.
  defp review_context(pr) when is_map(pr) do
    %{
      "review_decision" => Map.get(pr, "review_decision"),
      "head_committed_at" => Map.get(pr, "head_committed_at")
    }
  end

  defp review_context(_pr), do: review_context(%{})

  # An inline review thread stays actionable across pushes that did not touch
  # it, so thread comments carry only the approval half — matching
  # GithubCommentsPoller.approval_only_context/1.
  defp approval_only_context(context), do: Map.delete(context, "head_committed_at")

  @spec pull_request_triple(map(), map(), term(), String.t()) :: result()
  def pull_request_triple(payload, pr, action, repo) do
    merged? = merged_pull_request?(action, Map.get(pr, "merged"))
    actor = get_in(payload, ["sender", "login"])
    pr_number = Map.get(pr, "number")
    head_sha = get_in(pr, ["head", "sha"]) || ""

    with {:ok, target, _pr_number} <- Identity.pull_request_identity(payload),
         topic when is_binary(topic) <- pr_topic(target, action, merged?) do
      publish_opts = [
        actor: actor,
        issue_number: target,
        bypass_contamination: merged?,
        dedup_key: GithubKeys.pr_dedup_key(repo, pr_number, action, head_sha)
      ]

      {:publish, [{topic, %{action: action, pr: pr, timestamp: pull_request_timestamp(pr)}, publish_opts}]}
    else
      {:drop, _reason} = drop -> drop
      {:error, _reason} = error -> error
      nil -> {:drop, {:uninteresting_action, "pull_request", action}}
    end
  end

  defp pr_topic(target, "opened", _merged), do: "ticket.#{target}.pr.opened"
  defp pr_topic(target, "ready_for_review", _merged), do: "ticket.#{target}.pr.ready_for_review"
  defp pr_topic(target, _action, true), do: "ticket.#{target}.pr.merged"
  defp pr_topic(_target, _action, _merged), do: nil

  defp merged_pull_request?("closed", true), do: true
  defp merged_pull_request?("merged", _merged), do: true
  defp merged_pull_request?(_action, _merged), do: false

  # GithubFirehose stamps the Events API envelope's `created_at` — the moment
  # the event happened. A webhook body has no envelope, so the pull request's
  # own last-modified timestamp is the equivalent statement of when this
  # transition occurred.
  defp pull_request_timestamp(pr), do: Map.get(pr, "updated_at") || Map.get(pr, "created_at")

  # The poller reads reviews from `GET /pulls/N/reviews`, which reports `state`
  # in upper case; a `pull_request_review` delivery reports the same states in
  # lower case. `actionable_review?/1` already folds case so the *filter* agrees,
  # but the published review carried the delivery's own casing, so a consumer
  # matching `"CHANGES_REQUESTED"` on the event would see it only on the polling
  # path. Nothing reads it off the event today; this keeps it that way by
  # accident rather than by luck.
  #
  # Upper case is the shape to converge on because it is the poller's, and this
  # is a no-op when a delivery already agrees.
  defp upcase_review_state(%{"state" => state} = review) when is_binary(state),
    do: Map.put(review, "state", String.upcase(state))

  defp upcase_review_state(review), do: review
end
