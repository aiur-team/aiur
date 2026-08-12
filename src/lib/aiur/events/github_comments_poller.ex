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
  alias Aiur.GitHub.Client

  @type target :: String.t() | integer()
  @default_max_concurrency 4
  @default_target_timeout 60_000

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
      max_concurrency: Keyword.get(opts, :max_concurrency, @default_max_concurrency),
      timeout: Keyword.get(opts, :timeout, @default_target_timeout),
      on_timeout: :kill_task
    ]

    case Process.whereis(Aiur.TaskSupervisor) do
      pid when is_pid(pid) ->
        pid
        |> Task.Supervisor.async_stream_nolink(targets, run_target, task_opts)
        |> Enum.to_list()

      nil ->
        previous_trap_exit = Process.flag(:trap_exit, true)

        try do
          targets
          |> Task.async_stream(run_target, task_opts)
          |> Enum.to_list()
        after
          Process.flag(:trap_exit, previous_trap_exit)
        end
    end
  end

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
        request_opts = opts |> Keyword.put(:since, since) |> Keyword.put(:etag, etag)

        case Client.fetch_issue_comments_conditional(target, request_opts) do
          {:ok, comments, next_etag} ->
            {publish_issue_comments(target, comments, repo), newest_comment_datetime(comments), :ok, next_etag}

          {:not_modified, next_etag} ->
            {0, nil, :ok, next_etag}

          {:error, reason} ->
            Logger.warning("GithubCommentsPoller issue comments failed: issue=#{target} reason=#{inspect(reason)}")

            {0, nil, {:error, {:issue_comments, reason}}, etag}
        end
    end
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

        {review_count, review_result, review_seen_at} =
          if review_submission_enabled?(target, opts),
            do: poll_pr_review_submissions(target, pr_number, repo, review_context, opts),
            else: {0, :ok, nil}

        {
          conversation_count + thread_count + review_count,
          conversation_newest,
          [conversation_result, thread_result, review_result],
          %{{:pr_issue, pr_number} => conversation_etag},
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
        request_opts = opts |> Keyword.put(:since, since) |> Keyword.put(:etag, etag)

        case Client.fetch_issue_comments_conditional(pr_number, request_opts) do
          {:ok, comments, next_etag} ->
            {publish_pr_issue_comments(target, pr_number, comments, repo, review_context), newest_comment_datetime(comments), :ok, next_etag}

          {:not_modified, next_etag} ->
            {0, nil, :ok, next_etag}

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

  defp poll_pr_review_submissions(target, pr_number, repo, review_context, opts) do
    since = Map.get(Keyword.get(opts, :pr_review_seen_at, %{}), to_string(target))
    # Fall back to the issue-comment cursor so reviews submitted before it are
    # treated as already processed — mirrors the ?since= filter used for comments
    # and prevents restart-replay of old CHANGES_REQUESTED on resolved PRs.
    issue_since = Keyword.get(opts, :current_target_since)
    cutoff = since || issue_since || GithubKeys.boot_cutoff_iso8601(opts)

    case Client.fetch_pull_request_reviews(pr_number, opts) do
      {:ok, reviews} ->
        actionable =
          reviews
          |> Enum.filter(&review_after_cutoff?(&1, cutoff))
          |> most_recent_actionable_per_reviewer()

        count =
          actionable
          |> Enum.map(&publish_pr_review_submission(target, pr_number, &1, repo, review_context))
          |> Enum.count(&match?({:ok, _, _}, &1))

        max_seen = reviews |> Enum.map(&Map.get(&1, "submitted_at")) |> Enum.reject(&is_nil/1) |> Enum.max(fn -> nil end)

        {count, :ok, max_seen}

      {:error, reason} ->
        Logger.warning("GithubCommentsPoller PR reviews failed: issue=#{target} pr=#{pr_number} reason=#{inspect(reason)}")

        {0, {:error, {:pr_reviews, reason}}, nil}
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
      dedup_key: dedup_key
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
      dedup_key: GithubKeys.comment_dedup_key(repo, "issue_comment", parent_number, Map.get(comment, "id"))
    )
  end

  defp publish_pr_issue_comment(target, pr_number, comment, repo, review_context) when is_map(comment) do
    actor = get_in(comment, ["user", "login"])

    publish_comment(
      "ticket.#{target}.issue.commented",
      %{issue_number: target, comment: comment, pull_request: review_context},
      actor,
      issue_number: target,
      dedup_key: GithubKeys.comment_dedup_key(repo, "issue_comment", pr_number, Map.get(comment, "id"))
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
      dedup_key: dedup_key
    )
  end

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
