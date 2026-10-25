defmodule Aiur.GitHub.Listeners.Comments.TargetSelection.HumanReview do
  @moduledoc false
  require Logger
  alias Aiur.GitHub.Client, as: GitHubClient
  alias Aiur.GitHub.Listeners.Comments.Cursor
  alias Aiur.GitHub.Listeners.Comments.TargetSelection
  alias Aiur.GitHub.LocalHold
  alias Aiur.Issue
  alias Aiur.Tracker
  @human_review_comment_targets_per_poll 25
  @human_review_state "human-review"
  @merging_state "merging"
  @rework_state "rework"

  # The idle states whose tickets are discovered for comment polling, and — via
  # `review_submission_targets` — the states whose PRs have `/reviews` read.
  #
  # `rework` is in the set because a rework ticket is exactly where a *second*
  # review lands. A ticket whose rework turn finished sits in `agent:rework`
  # with no live provider; excluding it made a brand-new body-only
  # `CHANGES_REQUESTED` review on a newer head invisible, because GitHub's
  # aggregate `reviewDecision` was already sticky from the first one and
  # nothing else re-derives the review (#2601). Excluding the state was never
  # what kept #2422's rework loop closed: the guard is per-review identity —
  # the durable `{:pr_review, owner, repo, review_id}` resource at
  # `resource_version = submitted_at`, the `pr_review_seen_at` cutoff, and
  # `ReworkGate.verify_rework_attempt/4`'s per-head bound. All three are
  # edge-triggered on a review's own identity, so re-reading `/reviews` for a
  # rework ticket cannot re-route the same review, and a new one wakes it once.
  # Reviews can reject work before CI completes, including an idle ci-wait ticket.
  @comment_poll_review_states [@human_review_state, @merging_state, @rework_state, "ci-wait"]

  # Discovers tickets in the comment-actionable review states (human-review,
  # merging, rework) and turns each into a comment poll target, so a trusted
  # reviewer comment or review submission on them is seen even when the ticket
  # has no live agent. Only paused tickets are excluded, so a running ticket in
  # one of these states is discovered too — `Enum.uniq` in the callers folds it
  # together with its running-target entry.
  @spec targets(Cursor.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def targets(%Cursor{} = state, opts) do
    fetcher = Keyword.get(opts, :review_issue_fetcher, &Tracker.fetch_issues_by_states/1)

    case fetcher.(@comment_poll_review_states) do
      {:ok, issues} when is_list(issues) ->
        targets =
          issues
          |> capped_review_targets(state, opts)
          |> Enum.map(&with_human_review_pr_updated_at(&1, opts))
          |> Enum.reject(&unchanged_human_review_comment_target?(state, &1))

        {:ok, targets}

      {:error, _reason} = error ->
        error

      other ->
        {:error, {:unexpected_human_review_targets, other}}
    end
  end

  @spec targets_with_cache(Cursor.t(), keyword()) :: {:ok, [map()], map()} | {:error, term()}
  def targets_with_cache(%Cursor{} = state, opts) do
    case Keyword.fetch(opts, :review_issue_fetcher) do
      {:ok, fetcher} ->
        case fetcher.(@comment_poll_review_states) do
          {:ok, issues} when is_list(issues) ->
            {:ok, human_review_targets_from_issues(state, issues, opts), issue_list_cache(state)}

          {:error, _reason} = error ->
            error

          other ->
            {:error, {:unexpected_human_review_targets, other}}
        end

      :error ->
        case GitHubClient.fetch_issues_by_states_conditional(
               @comment_poll_review_states,
               issue_list_cache(state),
               opts
             ) do
          {:ok, issues, cache} -> {:ok, human_review_targets_from_issues(state, issues, opts), cache}
          {:error, _reason} = error -> error
        end
    end
  end

  defp issue_list_cache(%Cursor{issue_list_cache: cache}), do: cache

  defp human_review_targets_from_issues(state, issues, opts) do
    issues
    |> capped_review_targets(state, opts)
    |> Enum.map(&with_human_review_pr_updated_at(&1, opts))
    |> Enum.reject(&unchanged_human_review_comment_target?(state, &1))
  end

  # Orders the review-state population and applies the per-poll cap.
  #
  # The cap is shared by every state in `@comment_poll_review_states`, and
  # `CommentPolling` derives `review_submission_targets` from exactly this
  # capped list — so a ticket the cap drops loses its `/reviews` read
  # entirely, which is #2601's failure returning under load. Once `rework`
  # joined the set, a plain sort made that loss systematic rather than random:
  # `human_review_comment_target_sort_key/2` puts a ticket whose issue
  # `updated_at` moved ahead of one whose has not; a rework ticket with a live
  # agent churns its issue (label writes, comments) while a `human-review`
  # ticket waiting on a review submission does not, because a review touches
  # the pull request and not the issue. The population most likely to be
  # evicted was precisely the one the review-submission poll exists for.
  #
  # Interleaving the two buckets keeps each state's own priority order while
  # splitting the cap roughly evenly, so neither `human-review` nor `rework`
  # can starve the other. The budget is unchanged: the same limit is applied
  # to the same combined population.
  defp capped_review_targets(issues, %Cursor{} = state, opts) do
    {rework_issues, review_awaiting_issues} =
      issues
      |> Enum.reject(&Issue.paused?/1)
      |> Enum.split_with(&rework_issue?/1)

    # Dedupe BEFORE sorting, and use an order-preserving uniq across the
    # buckets afterwards: `dedupe_human_review_targets/1` returns `Map.values/1`,
    # whose order is unspecified, so running it after the sort would discard
    # the priority order the cap then truncates.
    ordered = fn group ->
      group
      |> Enum.map(&human_review_comment_target_for_issue/1)
      |> Enum.reject(&is_nil/1)
      |> dedupe_human_review_targets()
      |> Enum.sort_by(&human_review_comment_target_sort_key(state, &1))
    end

    targets =
      review_awaiting_issues
      |> ordered.()
      |> interleave_targets(ordered.(rework_issues))
      |> Enum.uniq_by(& &1.target)

    limit = limit(opts)
    kept = Enum.take(targets, limit)
    dropped = length(targets) - length(kept)

    # The watch-target path logs its cap; this one did not, so a starving
    # review-state population was invisible in the logs.
    if dropped > 0 do
      Logger.warning("human_review_comment_poll_targets capped: kept=#{length(kept)} dropped=#{dropped} limit=#{limit}")
    end

    kept
  end

  defp rework_issue?(%Issue{state: issue_state}) when is_binary(issue_state),
    do: issue_state |> String.trim() |> String.downcase() == @rework_state

  defp rework_issue?(_issue), do: false

  defp interleave_targets([], rest), do: rest
  defp interleave_targets(rest, []), do: rest
  defp interleave_targets([a | as], [b | bs]), do: [a, b | interleave_targets(as, bs)]

  defp comment_target_for_issue(%Issue{identifier: identifier}) when not is_nil(identifier),
    do: identifier

  defp comment_target_for_issue(%Issue{id: id}) when not is_nil(id), do: id
  defp comment_target_for_issue(_issue), do: nil

  defp human_review_comment_target_for_issue(%Issue{} = issue) do
    case TargetSelection.normalize_comment_targets([comment_target_for_issue(issue)]) do
      [target] ->
        issue_updated_at = issue_updated_at_key(issue.updated_at)
        %{target: target, issue_updated_at: issue_updated_at, updated_at: issue_updated_at}

      [] ->
        nil
    end
  end

  defp with_human_review_pr_updated_at(%{target: target} = entry, opts) do
    fetcher = human_review_pr_fetcher(opts)

    case LocalHold.run(fn -> fetcher.(target) end, LocalHold.caller_opts(opts)) do
      {:ok, pr} when is_map(pr) ->
        pr_updated_at =
          pr
          |> Map.get("updated_at", Map.get(pr, :updated_at))
          |> issue_updated_at_key()

        entry
        |> Map.put(:open_pull_request, pr)
        |> Map.put(:updated_at, human_review_target_updated_at_key(entry.issue_updated_at, pr_updated_at))

      {:ok, nil} ->
        entry
        |> Map.put(:open_pull_request, nil)
        |> Map.put(:updated_at, human_review_target_updated_at_key(entry.issue_updated_at, nil))

      {:error, reason} ->
        Logger.warning("GithubCommentsPoller PR freshness lookup failed: issue=#{target} reason=#{inspect(reason)}")
        %{entry | updated_at: nil}

      other ->
        Logger.warning("GithubCommentsPoller PR freshness lookup returned unexpected value: issue=#{target} result=#{inspect(other)}")
        %{entry | updated_at: nil}
    end
  end

  defp human_review_pr_fetcher(opts) do
    Keyword.get_lazy(opts, :review_pull_request_fetcher, fn ->
      fn target -> GitHubClient.fetch_open_pull_request_for_branch(target, opts) end
    end)
  end

  defp dedupe_human_review_targets(targets) do
    targets
    |> Enum.reduce(%{}, fn %{target: target} = entry, acc ->
      Map.put_new(acc, target, entry)
    end)
    |> Map.values()
  end

  defp unchanged_human_review_comment_target?(
         %Cursor{issue_updated_at: updated_at_by_target},
         %{target: target, updated_at: updated_at}
       )
       when is_binary(updated_at) do
    Map.get(updated_at_by_target, target) == updated_at
  end

  defp unchanged_human_review_comment_target?(_state, _target), do: false

  defp human_review_comment_target_sort_key(
         %Cursor{
           since: cursors,
           issue_updated_at: updated_at_by_target
         },
         %{target: target, issue_updated_at: issue_updated_at}
       ) do
    {
      human_review_pr_probe_priority(updated_at_by_target, target, issue_updated_at),
      comment_cursor_sort_key(cursors, target),
      target
    }
  end

  defp comment_cursor_sort_key(%{} = cursors, target), do: Map.get(cursors, target) || ""
  defp comment_cursor_sort_key(cursor, _target) when is_binary(cursor), do: cursor
  defp comment_cursor_sort_key(_cursor, _target), do: ""

  defp human_review_pr_probe_priority(%{} = updated_at_by_target, target, issue_updated_at)
       when is_binary(issue_updated_at) do
    case Map.get(updated_at_by_target, target) do
      updated_at when is_binary(updated_at) ->
        if human_review_target_known_at_issue_updated_at?(updated_at, issue_updated_at), do: 1, else: 0

      _other ->
        0
    end
  end

  defp human_review_pr_probe_priority(_updated_at_by_target, _target, _issue_updated_at), do: 0

  defp human_review_target_known_at_issue_updated_at?(updated_at, issue_updated_at) do
    updated_at == issue_updated_at or String.starts_with?(updated_at, "issue=#{issue_updated_at};pr=")
  end

  @spec limit(keyword()) :: pos_integer()
  def limit(opts) do
    case Keyword.get(opts, :human_review_comment_target_limit, @human_review_comment_targets_per_poll) do
      limit when is_integer(limit) and limit > 0 -> limit
      _ -> @human_review_comment_targets_per_poll
    end
  end

  defp issue_updated_at_key(%DateTime{} = updated_at), do: DateTime.to_iso8601(updated_at)
  defp issue_updated_at_key(updated_at) when is_binary(updated_at), do: updated_at
  defp issue_updated_at_key(_updated_at), do: nil

  defp human_review_target_updated_at_key(issue_updated_at, pr_updated_at)
       when is_binary(pr_updated_at) do
    IO.iodata_to_binary(["issue=", issue_updated_at || "", ";pr=", pr_updated_at])
  end

  defp human_review_target_updated_at_key(issue_updated_at, _pr_updated_at), do: issue_updated_at
end
