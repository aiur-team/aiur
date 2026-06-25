defmodule Aiur.Events.GithubCommentsPoller do
  @moduledoc """
  Polls direct GitHub comment endpoints for watched tickets.

  The repo `/events` feed is delayed and sampled, so issue comments can
  be crowded out before Aiur sees them. This poller queries each watched
  ticket's issue comments and open PR review comments directly, then
  publishes the same event topics as `Aiur.Events.GithubFirehose`.
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

    if targets == [] do
      {:ok, %{since: since_by_target, count: 0, errors: []}}
    else
      do_poll(targets, since_by_target, opts)
    end
  end

  defp do_poll(targets, since_by_target, opts) do
    repo = Keyword.get(opts, :repo) || Aiur.Tracker.project_identity()

    results =
      targets
      |> target_task_results(since_by_target, repo, opts)
      |> Enum.zip(targets)
      |> Enum.map(fn
        {{:ok, result}, _target} ->
          result

        {{:exit, reason}, target} ->
          Logger.warning("GithubCommentsPoller target task exited: issue=#{target} reason=#{inspect(reason)}")

          failed_target_result(
            target,
            Map.fetch!(since_by_target, target),
            {:target, {:exit, reason}}
          )
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

    {:ok, %{since: next_since, count: count, errors: errors}}
  end

  defp target_task_results(targets, since_by_target, repo, opts) do
    run_target = fn target ->
      poll_target(target, Map.fetch!(since_by_target, target), repo, opts)
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

  defp failed_target_result(target, since, reason) do
    %{target: target, count: 0, since: since, errors: [reason]}
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

  defp poll_target(target, since, repo, opts) do
    {issue_count, issue_newest, issue_result} = poll_issue_comments(target, since, repo, opts)
    {pr_count, pr_newest, pr_results} = poll_pr_comments(target, since, repo, opts)
    results = [issue_result | pr_results]
    errors = collect_errors(results)
    newest_seen_at = max_datetime(issue_newest, pr_newest)

    %{
      target: target,
      count: issue_count + pr_count,
      since: if(errors == [], do: advance_since(since, newest_seen_at), else: since),
      errors: errors
    }
  end

  defp poll_issue_comments(target, since, repo, opts) do
    case Client.fetch_issue_comments(target, Keyword.put(opts, :since, since)) do
      {:ok, comments} ->
        count =
          comments
          |> Enum.reject(&CommentFilter.agent_workpad?/1)
          |> Enum.map(&publish_issue_comment(target, &1, repo))
          |> Enum.count(&match?({:ok, _, _}, &1))

        {count, newest_comment_datetime(comments), :ok}

      {:error, reason} ->
        Logger.warning("GithubCommentsPoller issue comments failed: issue=#{target} reason=#{inspect(reason)}")

        {0, nil, {:error, {:issue_comments, reason}}}
    end
  end

  defp poll_pr_comments(target, since, repo, opts) do
    with {:ok, pr} when is_map(pr) <- Client.fetch_open_pull_request_for_branch(target, opts),
         pr_number when is_integer(pr_number) <- parse_integer(Map.get(pr, "number")) do
      {conversation_count, conversation_newest, conversation_result} =
        poll_pr_issue_comments(target, pr_number, since, repo, opts)

      {review_count, review_newest, review_result} =
        poll_pr_review_comments(target, pr_number, since, repo, opts)

      {thread_count, thread_result} =
        poll_unaddressed_pr_review_threads(target, pr_number, repo, opts)

      {
        conversation_count + review_count + thread_count,
        max_datetime(conversation_newest, review_newest),
        [conversation_result, review_result, thread_result]
      }
    else
      {:ok, nil} ->
        {0, nil, [:ok]}

      {:error, reason} ->
        Logger.warning("GithubCommentsPoller PR lookup/comments failed: issue=#{target} reason=#{inspect(reason)}")

        {0, nil, [{:error, {:pr_lookup, reason}}]}

      nil ->
        {0, nil, [:ok]}
    end
  end

  defp poll_pr_issue_comments(target, pr_number, since, repo, opts) do
    case Client.fetch_issue_comments(pr_number, Keyword.put(opts, :since, since)) do
      {:ok, comments} ->
        count =
          comments
          |> Enum.reject(&CommentFilter.agent_workpad?/1)
          |> Enum.map(&publish_pr_issue_comment(target, pr_number, &1, repo))
          |> Enum.count(&match?({:ok, _, _}, &1))

        {count, newest_comment_datetime(comments), :ok}

      {:error, reason} ->
        Logger.warning("GithubCommentsPoller PR conversation comments failed: issue=#{target} pr=#{pr_number} reason=#{inspect(reason)}")

        {0, nil, {:error, {:pr_issue_comments, reason}}}
    end
  end

  defp poll_pr_review_comments(target, pr_number, since, repo, opts) do
    case Client.fetch_pull_request_review_comments(pr_number, Keyword.put(opts, :since, since)) do
      {:ok, comments} ->
        count =
          comments
          |> Enum.map(&publish_pr_review_comment(target, pr_number, &1, repo))
          |> Enum.count(&match?({:ok, _, _}, &1))

        {count, newest_comment_datetime(comments), :ok}

      {:error, reason} ->
        Logger.warning("GithubCommentsPoller PR review comments failed: issue=#{target} pr=#{pr_number} reason=#{inspect(reason)}")

        {0, nil, {:error, {:pr_review_comments, reason}}}
    end
  end

  defp poll_unaddressed_pr_review_threads(target, pr_number, repo, opts) do
    case Client.fetch_unaddressed_pr_review_thread_comments(pr_number, opts) do
      {:ok, comments} ->
        count =
          comments
          |> Enum.map(&publish_pr_review_comment(target, pr_number, &1, repo))
          |> Enum.count(&match?({:ok, _, _}, &1))

        {count, :ok}

      {:error, reason} ->
        Logger.warning("GithubCommentsPoller PR review threads failed: issue=#{target} pr=#{pr_number} reason=#{inspect(reason)}")

        {0, {:error, {:pr_review_threads, reason}}}
    end
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

  defp publish_pr_issue_comment(target, pr_number, comment, repo) when is_map(comment) do
    actor = get_in(comment, ["user", "login"])

    publish_comment(
      "ticket.#{target}.issue.commented",
      %{issue_number: target, comment: comment},
      actor,
      issue_number: target,
      dedup_key: GithubKeys.comment_dedup_key(repo, "issue_comment", pr_number, Map.get(comment, "id"))
    )
  end

  defp publish_pr_review_comment(target, pr_number, comment, repo) when is_map(comment) do
    actor = get_in(comment, ["user", "login"])
    dedup_key = pr_review_comment_dedup_key(repo, pr_number, comment)

    publish_comment(
      "ticket.#{target}.pr.review_comment",
      %{issue_number: target, comment: comment},
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
    sanitized =
      payload
      |> Map.put(:source, :github)
      |> Sanitizer.scrub()
      |> Sanitizer.stamp_author_trust(actor: actor)
      |> Sanitizer.put_comment_message()

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
