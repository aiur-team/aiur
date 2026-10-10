defmodule Aiur.Events.GithubCommentsPoller.Reviews do
  @moduledoc """
  Review-thread and review-submission polling for
  `Aiur.Events.GithubCommentsPoller`.

  Threads are published as they are read. Submissions are read conditionally,
  filtered by the per-target review cutoff, and reduced to each reviewer's
  latest actionable review before publishing.
  """

  require Logger

  alias Aiur.Events.GithubCommentsPoller.{Publish, Validators}
  alias Aiur.Events.GithubKeys
  alias Aiur.GitHub.{Client, ResourceStore}

  @doc false
  @spec poll_unaddressed_pr_review_threads(term(), integer(), term(), map(), {:ok, list()} | :missing, keyword()) ::
          {non_neg_integer(), :ok | {:error, term()}}
  def poll_unaddressed_pr_review_threads(target, pr_number, repo, review_context, batched, opts) do
    case batched do
      {:ok, comments} ->
        {publish_pr_review_comments(target, pr_number, comments, repo, review_context), :ok}

      :missing ->
        case Client.fetch_unaddressed_pr_review_thread_comments(pr_number, opts) do
          {:ok, comments} ->
            {publish_pr_review_comments(target, pr_number, comments, repo, review_context), :ok}

          {:error, reason} ->
            Logger.warning("GithubCommentsPoller PR review threads failed: issue=#{target} pr=#{pr_number} reason=#{inspect(reason)}")

            {0, {:error, {:pr_review_threads, reason}}}
        end
    end
  end

  defp publish_pr_review_comments(target, pr_number, comments, repo, review_context) do
    comments
    |> Enum.map(&Publish.publish_pr_review_comment(target, pr_number, &1, repo, review_context))
    |> Enum.count(&match?({:ok, _, _}, &1))
  end

  # An inline review thread is a per-finding conversation with its own
  # resolution protocol, and it stays actionable across pushes that did not
  # touch it — so thread comments carry only the approval half of the context.
  # An APPROVED pull request is never rework; an old thread comment still is.
  @doc false
  @spec approval_only_context(map()) :: map()
  def approval_only_context(review_context),
    do: Map.delete(review_context, "head_committed_at")

  # Review submissions are the last comment kind the poller still re-read at
  # full price every cycle: the webhook delivers `pull_request_review` free and
  # marks the `:pr_review` resource, and the sweep re-read the same list
  # unconditionally (#2069). The read is now conditional like the issue-comment
  # sweep — a 304 costs nothing against the primary limit — and the per-review
  # identity suppression keeps a delivered review from waking the agent twice.
  # A `304` reuses the list the store still holds, which keeps the cutoff
  # watermark moving and recovers any review whose delivery was lost.
  @doc false
  @spec poll_pr_review_submissions(term(), integer(), term(), term(), map(), keyword()) ::
          {non_neg_integer(), :ok | {:error, term()}, String.t() | nil, String.t() | nil}
  def poll_pr_review_submissions(target, pr_number, etag, repo, review_context, opts) do
    since = Map.get(Keyword.get(opts, :pr_review_seen_at, %{}), to_string(target))
    # Fall back to the issue-comment cursor so reviews submitted before it are
    # treated as already processed — mirrors the ?since= filter used for comments
    # and prevents restart-replay of old CHANGES_REQUESTED on resolved PRs.
    issue_since = Keyword.get(opts, :current_target_since)
    cutoff = since || issue_since || GithubKeys.boot_cutoff_iso8601(opts)
    resource = ResourceStore.key_for_repo(:pull_request_reviews, repo, pr_number)
    {etag, provenance} = Validators.request_etag(resource, etag)
    request_opts = Keyword.put(opts, :etag, etag)

    case Client.fetch_pull_request_reviews_conditional(pr_number, request_opts) do
      {:ok, reviews, next_etag} ->
        {count, max_seen} = publish_review_submissions(target, pr_number, reviews, cutoff, repo, review_context)
        Validators.remember_list(resource, reviews, next_etag)
        {count, :ok, next_etag, max_seen}

      {:not_modified, next_etag} ->
        unchanged_review_submissions(target, pr_number, resource, provenance, next_etag, cutoff, repo, review_context)

      {:error, reason} ->
        Logger.warning("GithubCommentsPoller PR reviews failed: issue=#{target} pr=#{pr_number} reason=#{inspect(reason)}")

        {0, {:error, {:pr_reviews, reason}}, etag, nil}
    end
  end

  defp publish_review_submissions(target, pr_number, reviews, cutoff, repo, review_context) do
    actionable =
      reviews
      |> Enum.filter(&review_after_cutoff?(&1, cutoff))
      |> most_recent_actionable_per_reviewer()

    count =
      actionable
      |> Enum.map(&Publish.publish_pr_review_submission(target, pr_number, &1, repo, review_context))
      |> Enum.count(&match?({:ok, _, _}, &1))

    max_seen =
      reviews
      |> Enum.map(&Map.get(&1, "submitted_at"))
      |> Enum.reject(&is_nil/1)
      |> Enum.max(fn -> nil end)

    {count, max_seen}
  end

  # What a `304` against the review-list validator is worth, decided by the same
  # store/provenance contract as `unchanged_issue_comments/5`: a held list is
  # republished (each review suppressed by identity when it was already handled),
  # a cycle-minted validator with no body has nothing to recover, and a
  # store-minted validator with no body is unusable — drop it so the next read
  # is unconditional rather than spent on an empty `304`.
  defp unchanged_review_submissions(target, pr_number, resource, provenance, next_etag, cutoff, repo, review_context) do
    case Validators.unchanged_list(resource, provenance) do
      {:ok, reviews} ->
        {count, max_seen} = publish_review_submissions(target, pr_number, reviews, cutoff, repo, review_context)
        Validators.remember_list(resource, reviews, next_etag)
        {count, :ok, next_etag, max_seen}

      :nothing_to_recover ->
        {0, :ok, next_etag, nil}

      :unusable_validator ->
        {0, :ok, Validators.forget_validator(resource), nil}
    end
  end

  defp review_after_cutoff?(%{"submitted_at" => submitted_at}, cutoff)
       when is_binary(submitted_at) and is_binary(cutoff),
       do: submitted_at > cutoff

  defp review_after_cutoff?(_review, _cutoff), do: true

  # CHANGES_REQUESTED always requires rework. COMMENTED only when the reviewer
  # included a body — GitHub creates an empty-bodied COMMENTED review as the
  # container for inline-only comments, which are already published via
  # poll_unaddressed_pr_review_threads; filtering blanks avoids a double wake.
  defp actionable_review?(%{"state" => "CHANGES_REQUESTED"}), do: true
  defp actionable_review?(%{"state" => "COMMENTED", "body" => body}) when is_binary(body) and body != "", do: true
  defp actionable_review?(_review), do: false

  # A later APPROVED (or DISMISSED) review supersedes that reviewer's earlier
  # CHANGES_REQUESTED, so it suppresses the wake. Reviews that are neither
  # actionable nor suppressing — most importantly the empty-bodied COMMENTED
  # container GitHub creates for inline-only comments — are transparent: they
  # must not mask an earlier unresolved CHANGES_REQUESTED from the same
  # reviewer, which is why the actionable filter runs per reviewer here rather
  # than after a plain most-recent pick.
  defp most_recent_actionable_per_reviewer(reviews) do
    reviews
    |> Enum.filter(&(get_in(&1, ["user", "login"]) != nil))
    |> Enum.group_by(&get_in(&1, ["user", "login"]))
    |> Enum.flat_map(fn {_login, reviewer_reviews} -> latest_actionable_review(reviewer_reviews) end)
  end

  defp latest_actionable_review(reviews) do
    reviews
    |> Enum.sort_by(&submitted_at_key/1, :desc)
    |> Enum.find(&(actionable_review?(&1) or suppressing_review?(&1)))
    |> case do
      nil -> []
      review -> if actionable_review?(review), do: [review], else: []
    end
  end

  defp submitted_at_key(review) do
    case Map.get(review, "submitted_at") do
      submitted_at when is_binary(submitted_at) -> submitted_at
      _other -> ""
    end
  end

  defp suppressing_review?(%{"state" => state}) when state in ["APPROVED", "DISMISSED"], do: true
  defp suppressing_review?(_review), do: false

  # Limits /reviews fetches to targets whose issue is in a review-awaiting state
  # — `human-review`, `merging`, `rework`, or `ci-wait` (`TargetSelection`'s
  # `@comment_poll_review_states`). This avoids polling the endpoint for every
  # active PR each cycle, which would consume ~48% of the 5,000 req/hr GitHub
  # budget at 20 agents.
  #
  # `rework` is in the set deliberately: a ticket whose rework turn finished is
  # exactly where a *second* `CHANGES_REQUESTED` review lands, and excluding it
  # made that review invisible while the aggregate `reviewDecision` stayed
  # sticky from the first one (#2601). The read stays cheap because the review
  # list is conditional — a `304` costs nothing against the primary limit — and
  # the same review cannot be routed twice: see the cutoff and durable
  # review-identity argument in `Aiur.Orchestrator.ReworkGate`.
  @doc false
  @spec review_submission_enabled?(term(), keyword()) :: boolean()
  def review_submission_enabled?(target, opts) do
    case Keyword.get(opts, :review_submission_targets) do
      nil -> true
      targets -> MapSet.member?(targets, to_string(target))
    end
  end
end
