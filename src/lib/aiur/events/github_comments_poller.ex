defmodule Aiur.Events.GithubCommentsPoller do
  @moduledoc """
  Polls direct GitHub comment endpoints for watched tickets.

  The repo `/events` feed is delayed and sampled, so issue comments can
  be crowded out before Aiur sees them. This poller queries each watched
  ticket's issue comments, PR conversation comments, and unresolved PR
  review threads directly.
  """

  require Logger

  alias Aiur.Events.{CommentFilter, GithubKeys, Publisher, Sanitizer}
  alias Aiur.GitHub.{Client, ResourceStore}

  @type target :: String.t() | integer()
  @default_max_concurrency 4
  @default_target_timeout 60_000

  @doc false
  @spec max_duration_ms(non_neg_integer(), keyword()) :: non_neg_integer()
  def max_duration_ms(target_count, opts) when is_integer(target_count) and target_count >= 0 do
    max_concurrency = positive_integer_option(opts, :max_concurrency, @default_max_concurrency)
    target_timeout = positive_integer_option(opts, :timeout, @default_target_timeout)
    waves = ceil_div(target_count, max_concurrency)
    waves * target_timeout
  end

  @spec poll([target()], keyword()) :: {:ok, map()}
  def poll(targets, opts \\ []) when is_list(targets) do
    targets = normalize_targets(targets)
    since_by_target = normalize_since(Keyword.get(opts, :since), targets, opts)
    etags_by_target = normalize_etags(Keyword.get(opts, :etags), targets)

    if targets == [] do
      {:ok, %{since: since_by_target, etags: etags_by_target, count: 0, errors: [], pr_review_seen_at: %{}}}
    else
      do_poll(targets, since_by_target, etags_by_target, opts)
    end
  end

  defp do_poll(targets, since_by_target, etags_by_target, opts) do
    repo = Keyword.get(opts, :repo) || Aiur.Tracker.project_identity()

    results =
      targets
      |> target_task_results(since_by_target, etags_by_target, repo, opts)
      |> Enum.zip(targets)
      |> Enum.map(fn
        {{:ok, result}, _target} ->
          result

        {{:exit, reason}, target} ->
          Logger.warning("GithubCommentsPoller target task exited: issue=#{target} reason=#{inspect(reason)}")

          failed_target_result(
            target,
            Map.fetch!(since_by_target, target),
            Map.fetch!(etags_by_target, target),
            {:target, {:exit, reason}}
          )
      end)

    next_etags =
      Map.new(results, fn %{target: target, etags: etags} ->
        {target, etags}
      end)

    next_since =
      Map.new(results, fn %{target: target, since: since} ->
        {target, since}
      end)

    errors =
      results
      |> Enum.flat_map(fn %{target: target, errors: errors} ->
        Enum.map(errors, &{target, &1})
      end)

    count = Enum.reduce(results, 0, &(&1.count + &2))

    pr_review_seen_at =
      results
      |> Enum.flat_map(fn
        %{target: target, review_seen_at: ts} when is_binary(ts) -> [{target, ts}]
        _ -> []
      end)
      |> Map.new()

    {:ok,
     %{
       since: next_since,
       etags: next_etags,
       count: count,
       errors: errors,
       pr_review_seen_at: pr_review_seen_at
     }}
  end

  defp target_task_results(targets, since_by_target, etags_by_target, repo, opts) do
    run_target = fn target ->
      poll_target(target, Map.fetch!(since_by_target, target), Map.fetch!(etags_by_target, target), repo, opts)
    end

    task_opts = [
      max_concurrency: positive_integer_option(opts, :max_concurrency, @default_max_concurrency),
      timeout: positive_integer_option(opts, :timeout, @default_target_timeout),
      on_timeout: :kill_task
    ]

    previous_trap_exit = Process.flag(:trap_exit, true)

    try do
      targets
      |> Task.async_stream(run_target, task_opts)
      |> Enum.to_list()
    after
      Process.flag(:trap_exit, previous_trap_exit)
    end
  end

  defp positive_integer_option(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> value
      _other -> default
    end
  end

  defp ceil_div(0, _denominator), do: 0
  defp ceil_div(numerator, denominator), do: div(numerator + denominator - 1, denominator)

  defp normalize_targets(targets) do
    targets
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp failed_target_result(target, since, etags, reason) do
    %{target: target, count: 0, since: since, etags: etags, errors: [reason], review_seen_at: nil}
  end

  defp normalize_since(%{} = since_by_target, targets, opts) do
    default = default_since(opts)

    Map.new(targets, fn target ->
      {target, Map.get(since_by_target, target, default)}
    end)
  end

  defp normalize_since(since, targets, _opts) when is_binary(since) do
    Map.new(targets, &{&1, since})
  end

  defp normalize_since(_since, targets, opts) do
    default = default_since(opts)
    Map.new(targets, &{&1, default})
  end

  defp normalize_etags(%{} = etags_by_target, targets) do
    Map.new(targets, fn target -> {target, Map.get(etags_by_target, target, %{})} end)
  end

  defp normalize_etags(_etags, targets), do: Map.new(targets, &{&1, %{}})

  defp poll_target(target, since, etags, repo, opts) do
    opts = Keyword.put(opts, :current_target_since, since)

    {issue_count, issue_newest, issue_result, issue_etag} =
      poll_issue_comments(target, since, Map.get(etags, :issue), repo, opts)

    {pr_count, pr_newest, pr_results, pr_etags, review_seen_at} =
      poll_pr_comments(target, since, etags, repo, opts)

    results = [issue_result | pr_results]
    errors = collect_errors(results)
    # Reviews failures are reported but do not stall the issue-comment watermark.
    # A transient 403 on /reviews must not freeze comment ingestion for the ticket.
    watermark_errors = Enum.reject(errors, &match?({:pr_reviews, _}, &1))
    newest_seen_at = max_datetime(issue_newest, pr_newest)

    %{
      target: target,
      count: issue_count + pr_count,
      since: if(watermark_errors == [], do: advance_since(since, newest_seen_at), else: since),
      etags: etags |> Map.put(:issue, issue_etag) |> Map.merge(pr_etags),
      errors: errors,
      review_seen_at: review_seen_at
    }
  end

  defp poll_issue_comments(target, since, etag, repo, opts) do
    case batch_value(opts, target, :issue_comments) do
      {:ok, comments} ->
        {publish_issue_comments(target, comments, repo), newest_comment_datetime(comments), :ok, etag}

      :missing ->
        resource = ResourceStore.key_for_repo(:issue_comments, repo, target)
        {etag, provenance} = request_etag(resource, etag)
        request_opts = opts |> Keyword.put(:since, since) |> Keyword.put(:etag, etag)

        case Client.fetch_issue_comments_conditional(target, request_opts) do
          {:ok, comments, next_etag} ->
            count = publish_issue_comments(target, comments, repo)
            remember_list(resource, comments, next_etag)
            {count, newest_comment_datetime(comments), :ok, next_etag}

          {:not_modified, next_etag} ->
            unchanged_issue_comments(target, resource, provenance, next_etag, repo)

          {:error, reason} ->
            Logger.warning("GithubCommentsPoller issue comments failed: issue=#{target} reason=#{inspect(reason)}")

            {0, nil, {:error, {:issue_comments, reason}}, etag}
        end
    end
  end

  # The cycle's own map wins when it has an entry — it is the newest thing this
  # daemon knows. The store answers only for a target the in-memory map has
  # never seen, which after a restart is every target: without it the first
  # sweep of every boot re-reads every watched ticket's whole comment list at
  # full price, and restarts here are routine rather than rare.
  #
  # Where the validator came from is returned with it, because it decides what a
  # `304` against it is allowed to mean. A `:cycle` validator was minted by a
  # `200` this daemon already published, so "unchanged" is the truth and there is
  # nothing to recover. A `:store` validator may have outlived the publish it was
  # recorded beside, so "unchanged" alone is not enough — see `unchanged_list/2`.
  defp request_etag(_resource, etag) when is_binary(etag) and etag != "", do: {etag, :cycle}
  defp request_etag(resource, _etag), do: {ResourceStore.etag(resource), :store}

  # The list *and* its validator, deposited together and only after the comments
  # in it were published.
  #
  # A validator on its own is not safe to hold here. It is an endpoint-level
  # validator, so GitHub answering `304` to it suppresses the whole list at once
  # and no per-comment reconciliation can see inside that answer. Recording one
  # before publishing therefore had a routine loss: `ResourceStore` starts before
  # `Publisher` and this poller, so on SIGTERM the poller dies first while the
  # store checkpoints last, and a comment read but not yet published came back to
  # a validator GitHub was right to answer `304` to and a store holding nothing.
  # No exception was needed for that.
  #
  # Depositing the body closes it from the other side: the next `304` is served
  # from the store and publishes exactly what a `200` would have, so a cycle that
  # dies between the read and the publish loses nothing, and the recovery costs
  # no request. Publishing first as well means the crash window contains no
  # validator at all, and the sweep after it is unconditional.
  defp remember_list(resource, comments, etag) when is_list(comments) do
    ResourceStore.put_resource(resource, comments, etag: etag, source: :poll)
    etag
  end

  defp remember_list(_resource, _comments, etag), do: etag

  defp unchanged_issue_comments(target, resource, provenance, next_etag, repo) do
    case unchanged_list(resource, provenance) do
      {:ok, comments} ->
        count = publish_issue_comments(target, comments, repo)
        remember_list(resource, comments, next_etag)
        {count, nil, :ok, next_etag}

      :nothing_to_recover ->
        {0, nil, :ok, next_etag}

      :unusable_validator ->
        {0, nil, :ok, forget_validator(resource)}
    end
  end

  defp unchanged_pr_issue_comments(target, pr_number, resource, {provenance, next_etag}, repo, review_context) do
    case unchanged_list(resource, provenance) do
      {:ok, comments} ->
        count = publish_pr_issue_comments(target, pr_number, comments, repo, review_context)
        remember_list(resource, comments, next_etag)
        {count, nil, :ok, next_etag}

      :nothing_to_recover ->
        {0, nil, :ok, next_etag}

      :unusable_validator ->
        {0, nil, :ok, forget_validator(resource)}
    end
  end

  # What a `304` is worth, decided by what the store holds and where the
  # validator came from.
  #
  #   * the list itself — republish it. Every comment in it is either already
  #     marked processed, and suppressed for free, or was never published, and
  #     is recovered. That is what makes a `304` produce the same events a `200`
  #     would have.
  #   * no list, but the validator is this daemon's own from an earlier cycle —
  #     nothing to recover: the `200` that minted it was published first. Keep
  #     the validator, because dropping it would make every steady-state cycle a
  #     full-price read, which is the cost this whole path exists to remove.
  #   * no list, and the validator came out of the store — it may have outlived
  #     the publish it was recorded beside, and it is an *endpoint* validator, so
  #     GitHub's `304` suppressed the entire list and no per-comment
  #     reconciliation can see inside it. Unusable.
  defp unchanged_list(resource, provenance) do
    case ResourceStore.fetch(resource) do
      {:ok, %{data: comments}} when is_list(comments) -> {:ok, comments}
      _other when provenance == :cycle -> :nothing_to_recover
      _other -> :unusable_validator
    end
  end

  # A `304` against a durable validator with no body behind it spent a request
  # and learned nothing recoverable. So the validator goes, here and in the
  # cycle's own map, and the next sweep reads unconditionally. That is the
  # reader's half of the store's validator/body contract; see
  # `Aiur.GitHub.ResourceStore`.
  defp forget_validator(resource) do
    ResourceStore.drop_etag(resource)
    nil
  end

  defp publish_issue_comments(target, comments, repo) do
    comments
    |> Enum.reject(&CommentFilter.agent_workpad?/1)
    |> Enum.map(&publish_issue_comment(target, &1, repo))
    |> Enum.count(&match?({:ok, _, _}, &1))
  end

  defp poll_pr_comments(target, since, etags, repo, opts) do
    case batch_value(opts, target, :open_pull_request) do
      {:ok, pr} ->
        poll_pr_comments_for_open_pull_request(target, pr, since, etags, repo, opts)

      :missing ->
        poll_pr_comments_from_rest(target, since, etags, repo, opts)
    end
  end

  defp poll_pr_comments_from_rest(target, since, etags, repo, opts) do
    case open_pull_request_for_target(target, opts) do
      {:ok, pr} ->
        poll_pr_comments_for_open_pull_request(target, pr, since, etags, repo, opts)

      :fetch ->
        case Client.fetch_open_pull_request_for_branch(target, opts) do
          {:ok, pr} ->
            poll_pr_comments_for_open_pull_request(target, pr, since, etags, repo, opts)

          {:error, reason} ->
            Logger.warning("GithubCommentsPoller PR lookup/comments failed: issue=#{target} reason=#{inspect(reason)}")

            {0, nil, [{:error, {:pr_lookup, reason}}], %{}, nil}
        end
    end
  end

  defp open_pull_request_for_target(target, opts) do
    case Keyword.get(opts, :open_pull_requests_by_target) do
      %{} = open_pull_requests ->
        if Map.has_key?(open_pull_requests, target) do
          {:ok, Map.get(open_pull_requests, target)}
        else
          :fetch
        end

      _other ->
        :fetch
    end
  end

  defp poll_pr_comments_for_open_pull_request(target, pr, since, etags, repo, opts) when is_map(pr) do
    case parse_integer(Map.get(pr, "number")) do
      pr_number when is_integer(pr_number) ->
        review_context = review_context(pr)

        {conversation_count, conversation_newest, conversation_result, conversation_etag} =
          poll_pr_issue_comments(target, pr_number, since, Map.get(etags, {:pr_issue, pr_number}), repo, review_context, opts)

        {thread_count, thread_result} =
          poll_unaddressed_pr_review_threads(target, pr_number, repo, approval_only_context(review_context), opts)

        {review_count, review_result, review_etag, review_seen_at} =
          if review_submission_enabled?(target, opts),
            do: poll_pr_review_submissions(target, pr_number, Map.get(etags, :pr_reviews), repo, review_context, opts),
            else: {0, :ok, Map.get(etags, :pr_reviews), nil}

        {
          conversation_count + thread_count + review_count,
          conversation_newest,
          [conversation_result, thread_result, review_result],
          %{{:pr_issue, pr_number} => conversation_etag, :pr_reviews => review_etag},
          review_seen_at
        }

      nil ->
        {0, nil, [:ok], %{}, nil}
    end
  end

  defp poll_pr_comments_for_open_pull_request(_target, nil, _since, _etags, _repo, _opts),
    do: {0, nil, [:ok], %{}, nil}

  defp poll_pr_issue_comments(target, pr_number, since, etag, repo, review_context, opts) do
    case batch_value(opts, target, :pr_issue_comments) do
      {:ok, comments} ->
        {publish_pr_issue_comments(target, pr_number, comments, repo, review_context), newest_comment_datetime(comments), :ok, etag}

      :missing ->
        resource = ResourceStore.key_for_repo(:pr_issue_comments, repo, pr_number)
        {etag, provenance} = request_etag(resource, etag)
        request_opts = opts |> Keyword.put(:since, since) |> Keyword.put(:etag, etag)

        case Client.fetch_issue_comments_conditional(pr_number, request_opts) do
          {:ok, comments, next_etag} ->
            count = publish_pr_issue_comments(target, pr_number, comments, repo, review_context)
            remember_list(resource, comments, next_etag)
            {count, newest_comment_datetime(comments), :ok, next_etag}

          {:not_modified, next_etag} ->
            unchanged_pr_issue_comments(target, pr_number, resource, {provenance, next_etag}, repo, review_context)

          {:error, reason} ->
            Logger.warning("GithubCommentsPoller PR conversation comments failed: issue=#{target} pr=#{pr_number} reason=#{inspect(reason)}")

            {0, nil, {:error, {:pr_issue_comments, reason}}, etag}
        end
    end
  end

  defp publish_pr_issue_comments(target, pr_number, comments, repo, review_context) do
    comments
    |> Enum.reject(&CommentFilter.agent_workpad?/1)
    |> Enum.map(&publish_pr_issue_comment(target, pr_number, &1, repo, review_context))
    |> Enum.count(&match?({:ok, _, _}, &1))
  end

  # Review-staleness context the orchestrator's rework gate reads off the event
  # (`Aiur.Orchestrator.ReviewFreshness`). Only the GraphQL batch resolves these
  # fields; the REST fallback path publishes `nil` and the gate stays inert.
  defp review_context(pr) do
    %{
      "review_decision" => Map.get(pr, "review_decision"),
      "head_committed_at" => Map.get(pr, "head_committed_at")
    }
  end

  defp poll_unaddressed_pr_review_threads(target, pr_number, repo, review_context, opts) do
    case batch_value(opts, target, :review_thread_comments) do
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
    |> Enum.map(&publish_pr_review_comment(target, pr_number, &1, repo, review_context))
    |> Enum.count(&match?({:ok, _, _}, &1))
  end

  # An inline review thread is a per-finding conversation with its own
  # resolution protocol, and it stays actionable across pushes that did not
  # touch it — so thread comments carry only the approval half of the context.
  # An APPROVED pull request is never rework; an old thread comment still is.
  defp approval_only_context(review_context),
    do: Map.delete(review_context, "head_committed_at")

  defp batch_value(opts, target, key) do
    with %{} = batch <- Keyword.get(opts, :comment_batch),
         %{} = target_batch <- Map.get(batch, target),
         {:ok, value} <- Map.fetch(target_batch, key) do
      {:ok, value}
    else
      _ -> :missing
    end
  end

  # Review submissions are the last comment kind the poller still re-read at
  # full price every cycle: the webhook delivers `pull_request_review` free and
  # marks the `:pr_review` resource, and the sweep re-read the same list
  # unconditionally (#2069). The read is now conditional like the issue-comment
  # sweep — a 304 costs nothing against the primary limit — and the per-review
  # identity suppression keeps a delivered review from waking the agent twice.
  # A `304` reuses the list the store still holds, which keeps the cutoff
  # watermark moving and recovers any review whose delivery was lost.
  defp poll_pr_review_submissions(target, pr_number, etag, repo, review_context, opts) do
    since = Map.get(Keyword.get(opts, :pr_review_seen_at, %{}), to_string(target))
    # Fall back to the issue-comment cursor so reviews submitted before it are
    # treated as already processed — mirrors the ?since= filter used for comments
    # and prevents restart-replay of old CHANGES_REQUESTED on resolved PRs.
    issue_since = Keyword.get(opts, :current_target_since)
    cutoff = since || issue_since || GithubKeys.boot_cutoff_iso8601(opts)
    resource = ResourceStore.key_for_repo(:pull_request_reviews, repo, pr_number)
    {etag, provenance} = request_etag(resource, etag)
    request_opts = Keyword.put(opts, :etag, etag)

    case Client.fetch_pull_request_reviews_conditional(pr_number, request_opts) do
      {:ok, reviews, next_etag} ->
        {count, max_seen} = publish_review_submissions(target, pr_number, reviews, cutoff, repo, review_context)
        remember_list(resource, reviews, next_etag)
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
      |> Enum.map(&publish_pr_review_submission(target, pr_number, &1, repo, review_context))
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
    case unchanged_list(resource, provenance) do
      {:ok, reviews} ->
        {count, max_seen} = publish_review_submissions(target, pr_number, reviews, cutoff, repo, review_context)
        remember_list(resource, reviews, next_etag)
        {count, :ok, next_etag, max_seen}

      :nothing_to_recover ->
        {0, :ok, next_etag, nil}

      :unusable_validator ->
        {0, :ok, forget_validator(resource), nil}
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
  # (human-review). This avoids polling the endpoint for every active PR each cycle,
  # which would consume ~48% of the 5,000 req/hr GitHub budget at 20 agents.
  defp review_submission_enabled?(target, opts) do
    case Keyword.get(opts, :review_submission_targets) do
      nil -> true
      targets -> MapSet.member?(targets, to_string(target))
    end
  end

  defp publish_pr_review_submission(target, pr_number, review, repo, review_context) when is_map(review) do
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

  defp publish_issue_comment(target, comment, repo) when is_map(comment) do
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

  defp publish_pr_issue_comment(target, pr_number, comment, repo, review_context) when is_map(comment) do
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

  defp publish_pr_review_comment(target, pr_number, comment, repo, review_context) when is_map(comment) do
    actor = get_in(comment, ["user", "login"])
    dedup_key = pr_review_comment_dedup_key(repo, pr_number, comment)

    publish_comment(
      "ticket.#{target}.pr.review_comment",
      %{issue_number: target, comment: comment, pull_request: review_context},
      actor,
      issue_number: target,
      dedup_key: dedup_key,
      resource: pr_review_comment_resource(repo, comment),
      resource_version: resource_version(comment)
    )
  end

  # Deliberately mirrors `pr_review_comment_dedup_key/3`'s granularity rather
  # than improving on it. On the GraphQL batch path this poller dedups per
  # *thread*, a webhook delivery can only dedup per *comment*, and that
  # divergence is a known, pinned one (see `Normalizer`'s note and
  # `github_webhook_equivalence_test.exs`). Naming a comment resource on a
  # thread-keyed publish would silently reconcile the two at one granularity —
  # a real change to when an agent wakes, and not this ticket's to make. Where
  # the poller already keys per comment, the resource matches the delivery's
  # and the durable layer closes the restart gap the ETS window leaves open.
  defp pr_review_comment_resource(_repo, %{"review_thread_id" => thread_id})
       when is_binary(thread_id) and thread_id != "",
       do: nil

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

  defp pr_review_comment_dedup_key(repo, pr_number, %{"review_thread_id" => thread_id})
       when is_binary(thread_id) and thread_id != "" do
    GithubKeys.review_thread_dedup_key(repo, pr_number, thread_id)
  end

  defp pr_review_comment_dedup_key(repo, pr_number, comment) when is_map(comment) do
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

  defp collect_errors(results) do
    results
    |> Enum.reduce([], fn
      {:error, reason}, acc -> [reason | acc]
      _ok, acc -> acc
    end)
    |> Enum.reverse()
  end

  defp newest_comment_datetime(comments) when is_list(comments) do
    Enum.reduce(comments, nil, fn comment, newest ->
      max_datetime(newest, comment_datetime(comment))
    end)
  end

  defp comment_datetime(comment) when is_map(comment) do
    comment
    |> Map.get("updated_at", Map.get(comment, "created_at"))
    |> parse_datetime()
  end

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp max_datetime(nil, datetime), do: datetime
  defp max_datetime(datetime, nil), do: datetime

  defp max_datetime(%DateTime{} = left, %DateTime{} = right) do
    case DateTime.compare(left, right) do
      :lt -> right
      _ -> left
    end
  end

  defp advance_since(since, nil), do: since

  defp advance_since(_since, %DateTime{} = newest_seen_at) do
    newest_seen_at
    |> DateTime.add(-1, :second)
    |> DateTime.to_iso8601()
  end

  defp default_since(opts) do
    GithubKeys.boot_cutoff_iso8601(opts)
  end

  defp parse_integer(value) when is_integer(value), do: value

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> nil
    end
  end

  defp parse_integer(_value), do: nil
end
