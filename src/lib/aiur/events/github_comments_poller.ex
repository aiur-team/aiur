defmodule Aiur.Events.GithubCommentsPoller do
  @moduledoc """
  Polls direct GitHub comment endpoints for watched tickets.

  The repo `/events` feed is delayed and sampled, so issue comments can
  be crowded out before Aiur sees them. This poller queries each watched
  ticket's issue comments, PR conversation comments, and unresolved PR
  review threads directly.
  """

  require Logger

  alias Aiur.Events.CommentFilter
  alias Aiur.Events.GithubCommentsPoller.{Publish, Reviews, Validators}
  alias Aiur.GitHub.{Client, ResourceStore}
  alias Aiur.Orchestrator.ReadyForReviewTransitions

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
    since_by_target = Validators.normalize_since(Keyword.get(opts, :since), targets, opts)
    etags_by_target = Validators.normalize_etags(Keyword.get(opts, :etags), targets)

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

    # The draft flag of each PR this poll read, for the orchestrator's
    # draft-to-ready tracking (#2707). The flag rides on the PR read the poll
    # already makes, so it costs no request.
    pr_draft_observations =
      Enum.flat_map(results, fn
        %{pr_draft_observation: %{} = observation} -> [observation]
        _ -> []
      end)

    {:ok,
     %{
       since: next_since,
       etags: next_etags,
       count: count,
       errors: errors,
       pr_review_seen_at: pr_review_seen_at,
       pr_draft_observations: pr_draft_observations
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

  defp poll_target(target, since, etags, repo, opts) do
    opts = Keyword.put(opts, :current_target_since, since)

    {issue_count, issue_newest, issue_result, issue_etag} =
      poll_issue_comments(target, since, Map.get(etags, :issue), repo, opts)

    {pr_count, pr_newest, pr_results, pr_etags, review_seen_at, pr_draft_observation} =
      poll_pr_comments(target, since, etags, repo, opts)

    results = [issue_result | pr_results]
    errors = collect_errors(results)
    # Reviews failures are reported but do not stall the issue-comment watermark.
    # A transient 403 on /reviews must not freeze comment ingestion for the ticket.
    watermark_errors = Enum.reject(errors, &match?({:pr_reviews, _}, &1))
    newest_seen_at = Validators.max_datetime(issue_newest, pr_newest)

    # The issue-comment cursor may advance while /reviews is disabled for a
    # ci-wait ticket, or while that endpoint fails. Seed a separate review
    # cursor from the target's first cutoff and carry it through those cycles.
    # Otherwise a later issue comment can hide a CHANGES_REQUESTED review when
    # the ticket returns to human-review (#2817).
    prior_review_seen_at = Map.get(Keyword.get(opts, :pr_review_seen_at, %{}), target)
    review_baseline = prior_review_seen_at || since
    review_seen_at = max(review_baseline, review_seen_at || review_baseline)

    %{
      target: target,
      count: issue_count + pr_count,
      since: if(watermark_errors == [], do: Validators.advance_since(since, newest_seen_at), else: since),
      etags: etags |> Map.put(:issue, issue_etag) |> Map.merge(pr_etags),
      errors: errors,
      review_seen_at: review_seen_at,
      pr_draft_observation: pr_draft_observation
    }
  end

  defp poll_issue_comments(target, since, etag, repo, opts) do
    case batch_value(opts, target, :issue_comments) do
      {:ok, comments} ->
        {publish_issue_comments(target, comments, repo), Validators.newest_comment_datetime(comments), :ok, etag}

      :missing ->
        resource = ResourceStore.key_for_repo(:issue_comments, repo, target)
        {etag, provenance} = Validators.request_etag(resource, etag)
        request_opts = opts |> Keyword.put(:since, since) |> Keyword.put(:etag, etag)

        case Client.fetch_issue_comments_conditional(target, request_opts) do
          {:ok, comments, next_etag} ->
            count = publish_issue_comments(target, comments, repo)
            Validators.remember_list(resource, comments, next_etag)
            {count, Validators.newest_comment_datetime(comments), :ok, next_etag}

          {:not_modified, next_etag} ->
            unchanged_issue_comments(target, resource, provenance, next_etag, repo)

          {:error, reason} ->
            Logger.warning("GithubCommentsPoller issue comments failed: issue=#{target} reason=#{inspect(reason)}")

            {0, nil, {:error, {:issue_comments, reason}}, etag}
        end
    end
  end

  defp unchanged_issue_comments(target, resource, provenance, next_etag, repo) do
    case Validators.unchanged_list(resource, provenance) do
      {:ok, comments} ->
        count = publish_issue_comments(target, comments, repo)
        Validators.remember_list(resource, comments, next_etag)
        {count, nil, :ok, next_etag}

      :nothing_to_recover ->
        {0, nil, :ok, next_etag}

      :unusable_validator ->
        {0, nil, :ok, Validators.forget_validator(resource)}
    end
  end

  defp unchanged_pr_issue_comments(target, pr_number, resource, {provenance, next_etag}, repo, review_context) do
    case Validators.unchanged_list(resource, provenance) do
      {:ok, comments} ->
        count = publish_pr_issue_comments(target, pr_number, comments, repo, review_context)
        Validators.remember_list(resource, comments, next_etag)
        {count, nil, :ok, next_etag}

      :nothing_to_recover ->
        {0, nil, :ok, next_etag}

      :unusable_validator ->
        {0, nil, :ok, Validators.forget_validator(resource)}
    end
  end

  defp publish_issue_comments(target, comments, repo) do
    comments
    |> Enum.reject(&CommentFilter.agent_workpad?/1)
    |> Enum.map(&Publish.publish_issue_comment(target, &1, repo))
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

            {0, nil, [{:error, {:pr_lookup, reason}}], %{}, nil, nil}
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
    case Publish.parse_integer(Map.get(pr, "number")) do
      pr_number when is_integer(pr_number) ->
        review_context = review_context(pr)

        {conversation_count, conversation_newest, conversation_result, conversation_etag} =
          poll_pr_issue_comments(target, pr_number, since, Map.get(etags, {:pr_issue, pr_number}), repo, review_context, opts)

        {thread_count, thread_result} =
          Reviews.poll_unaddressed_pr_review_threads(
            target,
            pr_number,
            repo,
            Reviews.approval_only_context(review_context),
            batch_value(opts, target, :review_thread_comments),
            opts
          )

        {review_count, review_result, review_etag, review_seen_at} =
          if Reviews.review_submission_enabled?(target, opts),
            do: Reviews.poll_pr_review_submissions(target, pr_number, Map.get(etags, :pr_reviews), repo, review_context, opts),
            else: {0, :ok, Map.get(etags, :pr_reviews), nil}

        {
          conversation_count + thread_count + review_count,
          conversation_newest,
          [conversation_result, thread_result, review_result],
          %{{:pr_issue, pr_number} => conversation_etag, :pr_reviews => review_etag},
          review_seen_at,
          pr_draft_observation(pr, opts)
        }

      nil ->
        {0, nil, [:ok], %{}, nil, nil}
    end
  end

  defp poll_pr_comments_for_open_pull_request(_target, nil, _since, _etags, _repo, _opts),
    do: {0, nil, [:ok], %{}, nil, nil}

  # A ready PR the orchestrator's ledger has never seen is classified here, in
  # the poll task, so the one history read it needs never blocks the
  # orchestrator. Only an orchestrator-driven poll passes the ledger; without
  # it the observation goes back unclassified and costs nothing.
  defp pr_draft_observation(pr, opts) do
    observation = ReadyForReviewTransitions.from_pull_request(pr)

    with {:ok, ledger} <- Keyword.fetch(opts, :pr_ready_ledger),
         true <- ReadyForReviewTransitions.needs_history?(ledger, observation) do
      case Client.fetch_pull_request_was_draft(observation.pr_number, opts) do
        {:ok, was_draft?} ->
          Map.put(observation, :was_draft?, was_draft?)

        {:error, reason} ->
          Logger.warning("GithubCommentsPoller PR draft history read failed: pr=#{observation.pr_number} reason=#{inspect(reason)}")

          # Recorded with a backoff by the orchestrator, so a persistent 403
          # or 404 does not cost a read on every poll.
          Map.put(observation, :was_draft?, :error)
      end
    else
      _no_history_needed -> observation
    end
  end

  defp poll_pr_issue_comments(target, pr_number, since, etag, repo, review_context, opts) do
    case batch_value(opts, target, :pr_issue_comments) do
      {:ok, comments} ->
        {publish_pr_issue_comments(target, pr_number, comments, repo, review_context), Validators.newest_comment_datetime(comments), :ok, etag}

      :missing ->
        resource = ResourceStore.key_for_repo(:pr_issue_comments, repo, pr_number)
        {etag, provenance} = Validators.request_etag(resource, etag)
        request_opts = opts |> Keyword.put(:since, since) |> Keyword.put(:etag, etag)

        case Client.fetch_issue_comments_conditional(pr_number, request_opts) do
          {:ok, comments, next_etag} ->
            count = publish_pr_issue_comments(target, pr_number, comments, repo, review_context)
            Validators.remember_list(resource, comments, next_etag)
            {count, Validators.newest_comment_datetime(comments), :ok, next_etag}

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
    |> Enum.map(&Publish.publish_pr_issue_comment(target, pr_number, &1, repo, review_context))
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

  defp batch_value(opts, target, key) do
    with %{} = batch <- Keyword.get(opts, :comment_batch),
         %{} = target_batch <- Map.get(batch, target),
         {:ok, value} <- Map.fetch(target_batch, key) do
      {:ok, value}
    else
      _ -> :missing
    end
  end

  defp collect_errors(results) do
    results
    |> Enum.reduce([], fn
      {:error, reason}, acc -> [reason | acc]
      _ok, acc -> acc
    end)
    |> Enum.reverse()
  end
end
