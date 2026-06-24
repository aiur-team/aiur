defmodule Aiur.Events.GithubCommentsPoller do
  @moduledoc """
  Polls direct GitHub comment endpoints for watched tickets.

  The repo `/events` feed is delayed and sampled, so issue comments can
  be crowded out before Aiur sees them. This poller queries each watched
  ticket's issue comments and open PR review comments directly, then
  publishes the same event topics as `Aiur.Events.GithubFirehose`.
  """

  require Logger

  alias Aiur.Events.{Publisher, Sanitizer}
  alias Aiur.GitHub.Client

  @pre_boot_buffer_seconds 60

  @type target :: String.t() | integer()

  @spec poll([target()], keyword()) :: {:ok, map()} | {:error, term()}
  def poll(targets, opts \\ []) when is_list(targets) do
    targets = normalize_targets(targets)
    since = Keyword.get(opts, :since) || default_since(opts)

    if targets == [] do
      {:ok, %{since: since, count: 0}}
    else
      do_poll(targets, since, opts)
    end
  end

  defp do_poll(targets, since, opts) do
    repo = Keyword.get(opts, :repo) || Aiur.Tracker.project_identity()

    {count, newest_seen_at, successes, errors} =
      Enum.reduce(targets, {0, nil, 0, []}, fn target, acc ->
        poll_target(target, since, repo, opts, acc)
      end)

    if successes == 0 and errors != [] do
      {:error, Enum.reverse(errors)}
    else
      {:ok, %{since: advance_since(since, newest_seen_at), count: count}}
    end
  end

  defp normalize_targets(targets) do
    targets
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp poll_target(target, since, repo, opts, {count, newest_seen_at, successes, errors}) do
    {issue_count, issue_newest, issue_result} = poll_issue_comments(target, since, repo, opts)
    {pr_count, pr_newest, pr_result} = poll_pr_review_comments(target, since, repo, opts)

    {
      count + issue_count + pr_count,
      max_datetime(newest_seen_at, max_datetime(issue_newest, pr_newest)),
      successes + success_count(issue_result) + success_count(pr_result),
      collect_error(errors, target, issue_result, pr_result)
    }
  end

  defp poll_issue_comments(target, since, repo, opts) do
    case Client.fetch_issue_comments(target, Keyword.put(opts, :since, since)) do
      {:ok, comments} ->
        count =
          comments
          |> Enum.map(&publish_issue_comment(target, &1, repo))
          |> Enum.count(&match?({:ok, _, _}, &1))

        {count, newest_comment_datetime(comments), :ok}

      {:error, reason} ->
        Logger.warning("GithubCommentsPoller issue comments failed: issue=#{target} reason=#{inspect(reason)}")

        {0, nil, {:error, {:issue_comments, reason}}}
    end
  end

  defp poll_pr_review_comments(target, since, repo, opts) do
    with {:ok, pr} when is_map(pr) <- Client.fetch_open_pull_request_for_branch(target, opts),
         pr_number when not is_nil(pr_number) <- Map.get(pr, "number"),
         {:ok, comments} <-
           Client.fetch_pull_request_review_comments(pr_number, Keyword.put(opts, :since, since)) do
      count =
        comments
        |> Enum.map(&publish_pr_review_comment(target, pr_number, &1, repo))
        |> Enum.count(&match?({:ok, _, _}, &1))

      {count, newest_comment_datetime(comments), :ok}
    else
      {:ok, nil} ->
        {0, nil, :ok}

      {:error, reason} ->
        Logger.warning("GithubCommentsPoller PR lookup/comments failed: issue=#{target} reason=#{inspect(reason)}")

        {0, nil, {:error, {:pr_review_comments, reason}}}

      nil ->
        {0, nil, :ok}
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
      dedup_key: comment_dedup_key(repo, "issue_comment", parent_number, Map.get(comment, "id"))
    )
  end

  defp publish_pr_review_comment(target, pr_number, comment, repo) when is_map(comment) do
    actor = get_in(comment, ["user", "login"])

    publish_comment(
      "ticket.#{target}.pr.review_comment",
      %{issue_number: target, comment: comment},
      actor,
      issue_number: target,
      dedup_key: comment_dedup_key(repo, "pr_review_comment", pr_number, Map.get(comment, "id"))
    )
  end

  defp publish_comment(topic, payload, actor, publish_opts) do
    sanitized =
      payload
      |> Map.put(:source, :github)
      |> Sanitizer.scrub()
      |> Sanitizer.stamp_author_trust(actor: actor)

    publish_opts =
      publish_opts
      |> Keyword.put(:actor, actor)
      |> Keyword.put(:bypass_contamination, true)

    Publisher.publish(topic, sanitized, publish_opts)
  end

  defp success_count(:ok), do: 1
  defp success_count({:error, _}), do: 0

  defp collect_error(errors, target, issue_result, pr_result) do
    [issue_result, pr_result]
    |> Enum.reduce(errors, fn
      {:error, reason}, acc -> [{target, reason} | acc]
      _ok, acc -> acc
    end)
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
    opts
    |> boot_epoch_seconds()
    |> Kernel.-(@pre_boot_buffer_seconds)
    |> DateTime.from_unix!()
    |> DateTime.to_iso8601()
  end

  defp boot_epoch_seconds(opts) do
    case Keyword.get(opts, :boot_time) do
      ts when is_integer(ts) -> ts
      _ -> Aiur.Boot.epoch_seconds()
    end
  end

  defp comment_dedup_key(repo, kind, parent_number, comment_id)
       when is_binary(repo) and is_binary(kind) and is_integer(parent_number) and
              is_integer(comment_id),
       do: {repo, "#{kind}:#{parent_number}", Integer.to_string(comment_id)}

  defp comment_dedup_key(_, _, _, _), do: nil

  defp parse_integer(value) when is_integer(value), do: value

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> nil
    end
  end

  defp parse_integer(_value), do: nil
end
