defmodule Aiur.Orchestrator.CommentPolling.TargetSelection do
  @moduledoc """
  Comment-poll target discovery, ordering, capping, and cursor bookkeeping.
  All functions execute inside the orchestrator GenServer process.
  """

  require Logger

  alias Aiur.GitHub.Client, as: GitHubClient
  alias Aiur.GitHub.Config, as: GitHubConfig
  alias Aiur.Issue
  alias Aiur.Orchestrator.State
  alias Aiur.Tracker

  @human_review_comment_targets_per_poll 25
  @watch_comment_targets_per_poll 25
  @human_review_state "human-review"
  @merging_state "merging"
  @comment_poll_review_states [@human_review_state, @merging_state]

  @doc false
  @spec max_comment_poll_target_count(State.t(), keyword()) :: non_neg_integer()
  def max_comment_poll_target_count(%State{} = state, opts) do
    map_size(state.running) + human_review_comment_target_limit(opts) + watch_comment_target_limit(opts)
  end

  @spec github_comment_poll_targets(State.t(), keyword()) ::
          {:ok, [String.t()], [map()], [map()]} | {:error, term()}
  def github_comment_poll_targets(%State{} = state, opts) do
    with {:ok, human_review_targets} <- human_review_comment_poll_targets(state, opts),
         {:ok, watch_targets} <- watch_comment_poll_targets(state, opts) do
      running_targets = running_comment_poll_targets(state)

      targets =
        running_targets
        |> Kernel.++(Enum.map(human_review_targets, & &1.target))
        |> Kernel.++(Enum.map(watch_targets, & &1.target))
        |> Enum.uniq()

      {:ok, targets, human_review_targets, watch_targets}
    end
  end

  @spec github_comment_poll_targets_with_cache(State.t(), keyword()) ::
          {:ok, [String.t()], [map()], [map()], map()} | {:error, term()}
  def github_comment_poll_targets_with_cache(%State{} = state, opts) do
    with {:ok, human_review_targets, cache} <-
           human_review_comment_poll_targets_with_cache(state, opts),
         {:ok, watch_targets} <- watch_comment_poll_targets(state, opts) do
      running_targets = running_comment_poll_targets(state)

      targets =
        running_targets
        |> Kernel.++(Enum.map(human_review_targets, & &1.target))
        |> Kernel.++(Enum.map(watch_targets, & &1.target))
        |> Enum.uniq()

      {:ok, targets, human_review_targets, watch_targets, cache}
    end
  end

  # Discovers open PRs labeled agent:watch repo-wide and turns each into a
  # PR-number-keyed comment poll target carrying its PR object, so the poller
  # never branch-derives for watched PRs (it consumes the passed PR via
  # open_pull_requests_by_target). Mirrors human_review_comment_poll_targets/2:
  # closed/merged PRs are excluded at the query, the set is deduped and capped per
  # poll, and the drop is logged (never silent). Returns {:ok, []} when the
  # feature is disabled so the rest of the poll cycle is untouched.
  defp watch_comment_poll_targets(%State{} = _state, opts) do
    if GitHubConfig.pr_watch_enabled?() do
      fetcher = watch_pull_request_fetcher(opts)

      case fetcher.(GitHubConfig.watch_label()) do
        {:ok, pull_requests} when is_list(pull_requests) ->
          {:ok, build_watch_targets(pull_requests, opts)}

        {:error, _reason} = error ->
          error

        other ->
          {:error, {:unexpected_watch_targets, other}}
      end
    else
      {:ok, []}
    end
  end

  defp watch_pull_request_fetcher(opts) do
    Keyword.get_lazy(opts, :watch_pull_request_fetcher, fn ->
      fn label -> GitHubClient.fetch_open_pull_requests_by_label(label, opts) end
    end)
  end

  defp build_watch_targets(pull_requests, opts) do
    targets =
      pull_requests
      |> Enum.map(&watch_comment_target_for_pull_request/1)
      |> Enum.reject(&is_nil/1)
      |> dedupe_watch_targets()

    limit = watch_comment_target_limit(opts)
    kept = Enum.take(targets, limit)

    dropped = length(targets) - length(kept)

    if dropped > 0 do
      Logger.warning("watch_comment_poll_targets capped: kept=#{length(kept)} dropped=#{dropped} limit=#{limit}")
    end

    kept
  end

  # A watched PR's identifier/topic is its PR number (string). Open/closed is
  # already filtered at the query, so any PR reaching here is an active watch
  # target. open defends against a fetcher that returns non-open PRs.
  defp watch_comment_target_for_pull_request(%{"number" => number} = pr)
       when is_integer(number) do
    if pull_request_open?(pr) do
      %{target: to_string(number), open_pull_request: pr}
    end
  end

  defp watch_comment_target_for_pull_request(_pr), do: nil

  defp pull_request_open?(%{"state" => state}) when is_binary(state), do: state == "open"
  defp pull_request_open?(%{"merged_at" => merged_at}) when is_binary(merged_at), do: false
  defp pull_request_open?(_pr), do: true

  defp dedupe_watch_targets(targets) do
    targets
    |> Enum.reduce(%{}, fn %{target: target} = entry, acc ->
      Map.put_new(acc, target, entry)
    end)
    |> Map.values()
  end

  defp watch_comment_target_limit(opts) do
    case Keyword.get(opts, :watch_comment_target_limit, @watch_comment_targets_per_poll) do
      limit when is_integer(limit) and limit > 0 -> limit
      _ -> @watch_comment_targets_per_poll
    end
  end

  defp running_comment_poll_targets(%State{} = state) do
    state.running
    |> Map.values()
    |> Enum.map(&Map.get(&1, :identifier))
    |> normalize_comment_targets()
  end

  # Discovers idle (non-running) tickets in the comment-actionable review states
  # (human-review + merging) and turns each into a comment poll target, so a
  # trusted reviewer comment on them is seen and promotes the ticket to rework
  # even though those states are not in active_states.
  defp human_review_comment_poll_targets(%State{} = state, opts) do
    fetcher = Keyword.get(opts, :review_issue_fetcher, &Tracker.fetch_issues_by_states/1)

    case fetcher.(@comment_poll_review_states) do
      {:ok, issues} when is_list(issues) ->
        targets =
          issues
          |> Enum.reject(&Issue.paused?/1)
          |> Enum.map(&human_review_comment_target_for_issue/1)
          |> Enum.reject(&is_nil/1)
          |> dedupe_human_review_targets()
          |> Enum.sort_by(&human_review_comment_target_sort_key(state, &1))
          |> Enum.take(human_review_comment_target_limit(opts))
          |> Enum.map(&with_human_review_pr_updated_at(&1, opts))
          |> Enum.reject(&unchanged_human_review_comment_target?(state, &1))

        {:ok, targets}

      {:error, _reason} = error ->
        error

      other ->
        {:error, {:unexpected_human_review_targets, other}}
    end
  end

  defp human_review_comment_poll_targets_with_cache(%State{} = state, opts) do
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

  defp issue_list_cache(%State{github_comment_issue_list_cache: cache}), do: cache

  defp human_review_targets_from_issues(state, issues, opts) do
    issues
    |> Enum.reject(&Issue.paused?/1)
    |> Enum.map(&human_review_comment_target_for_issue/1)
    |> Enum.reject(&is_nil/1)
    |> dedupe_human_review_targets()
    |> Enum.sort_by(&human_review_comment_target_sort_key(state, &1))
    |> Enum.take(human_review_comment_target_limit(opts))
    |> Enum.map(&with_human_review_pr_updated_at(&1, opts))
    |> Enum.reject(&unchanged_human_review_comment_target?(state, &1))
  end

  defp comment_target_for_issue(%Issue{identifier: identifier}) when not is_nil(identifier),
    do: identifier

  defp comment_target_for_issue(%Issue{id: id}) when not is_nil(id), do: id
  defp comment_target_for_issue(_issue), do: nil

  defp human_review_comment_target_for_issue(%Issue{} = issue) do
    case normalize_comment_targets([comment_target_for_issue(issue)]) do
      [target] ->
        issue_updated_at = issue_updated_at_key(issue.updated_at)
        %{target: target, issue_updated_at: issue_updated_at, updated_at: issue_updated_at}

      [] ->
        nil
    end
  end

  defp with_human_review_pr_updated_at(%{target: target} = entry, opts) do
    fetcher = human_review_pr_fetcher(opts)

    case fetcher.(target) do
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
         %State{github_comment_issue_updated_at: updated_at_by_target},
         %{target: target, updated_at: updated_at}
       )
       when is_binary(updated_at) do
    Map.get(updated_at_by_target, target) == updated_at
  end

  defp unchanged_human_review_comment_target?(_state, _target), do: false

  defp human_review_comment_target_sort_key(
         %State{
           github_comments_since: cursors,
           github_comment_issue_updated_at: updated_at_by_target
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

  defp human_review_comment_target_limit(opts) do
    case Keyword.get(opts, :human_review_comment_target_limit, @human_review_comment_targets_per_poll) do
      limit when is_integer(limit) and limit > 0 -> limit
      _ -> @human_review_comment_targets_per_poll
    end
  end

  @spec put_open_pull_requests_by_target(keyword(), [map()]) :: keyword()
  def put_open_pull_requests_by_target(opts, targets) do
    open_pull_requests =
      targets
      |> Enum.reduce(%{}, fn
        %{target: target} = entry, acc when is_binary(target) ->
          if Map.has_key?(entry, :open_pull_request) do
            Map.put(acc, target, Map.get(entry, :open_pull_request))
          else
            acc
          end

        _entry, acc ->
          acc
      end)

    if map_size(open_pull_requests) == 0 do
      opts
    else
      existing = Keyword.get(opts, :open_pull_requests_by_target, %{})
      Keyword.put(opts, :open_pull_requests_by_target, Map.merge(existing, open_pull_requests))
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

  @spec remember_polled_human_review_targets(map(), [map()], list()) :: map()
  def remember_polled_human_review_targets(updated_at_by_target, human_review_targets, errors) do
    failed_targets =
      errors
      |> Enum.map(fn {target, _reason} -> target end)
      |> MapSet.new()

    human_review_targets
    |> Enum.reject(&(MapSet.member?(failed_targets, &1.target) or is_nil(&1.updated_at)))
    |> Map.new(&{&1.target, &1.updated_at})
    |> then(&Map.merge(updated_at_by_target, &1))
  end

  @spec merge_comment_cursors(term(), term()) :: term()
  def merge_comment_cursors(%{} = previous, %{} = next), do: Map.merge(previous, next)
  def merge_comment_cursors(_previous, next), do: next

  defp normalize_comment_targets(targets) when is_list(targets) do
    targets
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end
end
