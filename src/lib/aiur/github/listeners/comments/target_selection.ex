defmodule Aiur.GitHub.Listeners.Comments.TargetSelection do
  @moduledoc """
  Comment-poll target discovery, ordering, capping, and cursor bookkeeping.
  Discovery runs in the listener's owned poll tree.
  """

  require Logger

  alias Aiur.GitHub.Client, as: GitHubClient
  alias Aiur.GitHub.Config, as: GitHubConfig
  alias Aiur.GitHub.Listeners.Comments.{Cursor, Input}
  alias Aiur.GitHub.Listeners.Comments.TargetSelection.HumanReview

  @watch_comment_targets_per_poll 25
  @reconcile_targets_per_poll 25

  @doc false
  @spec max_comment_poll_target_count(Cursor.t(), Input.t(), keyword()) :: non_neg_integer()
  def max_comment_poll_target_count(%Cursor{} = state, %Input{} = input, opts) do
    if reconcile_only?(opts) do
      state |> reconcile_targets_for_poll(input, opts) |> MapSet.size()
    else
      length(input.running_targets) +
        HumanReview.limit(opts) +
        watch_comment_target_limit(opts) +
        (state |> reconcile_targets_for_poll(input, opts) |> MapSet.size())
    end
  end

  @doc false
  @spec reconcile_targets_for_poll(Cursor.t(), Input.t(), keyword()) :: MapSet.t(String.t())
  def reconcile_targets_for_poll(%Cursor{reconcile_targets: targets}, %Input{} = _input, opts) do
    targets
    |> MapSet.to_list()
    |> normalize_comment_targets()
    |> Enum.sort()
    |> Enum.take(reconcile_target_limit(opts))
    |> MapSet.new()
  end

  @spec github_comment_poll_targets(Cursor.t(), Input.t(), keyword()) ::
          {:ok, [String.t()], [map()], [map()]} | {:error, term()}
  def github_comment_poll_targets(%Cursor{} = state, %Input{} = input, opts) do
    if reconcile_only?(opts) do
      {:ok, forced_reconcile_targets(state, input, opts), [], []}
    else
      with {:ok, human_review_targets} <- HumanReview.targets(state, opts),
           {:ok, watch_targets} <- watch_comment_poll_targets(state, opts) do
        running_targets = input.running_targets

        targets =
          running_targets
          |> Kernel.++(Enum.map(human_review_targets, & &1.target))
          |> Kernel.++(Enum.map(watch_targets, & &1.target))
          |> Kernel.++(forced_reconcile_targets(state, input, opts))
          |> Enum.uniq()

        {:ok, targets, human_review_targets, watch_targets}
      end
    end
  end

  @spec github_comment_poll_targets_with_cache(Cursor.t(), Input.t(), keyword()) ::
          {:ok, [String.t()], [map()], [map()], map()} | {:error, term()}
  def github_comment_poll_targets_with_cache(%Cursor{} = state, %Input{} = input, opts) do
    if reconcile_only?(opts) do
      {:ok, forced_reconcile_targets(state, input, opts), [], [], state.issue_list_cache}
    else
      with {:ok, human_review_targets, cache} <-
             HumanReview.targets_with_cache(state, opts),
           {:ok, watch_targets} <- watch_comment_poll_targets(state, opts) do
        running_targets = input.running_targets

        targets =
          running_targets
          |> Kernel.++(Enum.map(human_review_targets, & &1.target))
          |> Kernel.++(Enum.map(watch_targets, & &1.target))
          |> Kernel.++(forced_reconcile_targets(state, input, opts))
          |> Enum.uniq()

        {:ok, targets, human_review_targets, watch_targets, cache}
      end
    end
  end

  defp reconcile_only?(opts), do: Keyword.get(opts, :reconcile_only, false) == true

  defp forced_reconcile_targets(%Cursor{} = state, input, opts) do
    state
    |> reconcile_targets_for_poll(input, opts)
    |> MapSet.to_list()
  end

  @doc false
  @spec reconcile_target_limit(keyword()) :: pos_integer()
  def reconcile_target_limit(opts) do
    case Keyword.get(opts, :reconcile_target_limit, @reconcile_targets_per_poll) do
      limit when is_integer(limit) and limit > 0 -> limit
      _other -> @reconcile_targets_per_poll
    end
  end

  # Discovers open PRs labeled agent:watch repo-wide and turns each into a
  # PR-number-keyed comment poll target carrying its PR object, so the poller
  # never branch-derives for watched PRs (it consumes the passed PR via
  # open_pull_requests_by_target). Mirrors human_review_comment_poll_targets/2:
  # closed/merged PRs are excluded at the query, the set is deduped and capped per
  # poll, and the drop is logged (never silent). Returns {:ok, []} when the
  # feature is disabled so the rest of the poll cycle is untouched.
  defp watch_comment_poll_targets(%Cursor{} = _state, opts) do
    if GitHubConfig.pr_watch_enabled?() do
      case watch_pull_requests(GitHubConfig.watch_label(), opts) do
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

  # Watch-target discovery reads the open-pull-request collection every cycle
  # (one `GET /pulls?state=open&per_page=100`). It used to be conditional
  # (#2069) so steady state was a budget-free `304` — but the listing is
  # `created` desc, so a page-1 validator cannot answer the multi-page question
  # once the listing grows past 100: a watch label added to an older PR on
  # page 2+ would be hidden by a page-1 `304` forever. The read is now
  # unconditional — correct beats quietly wrong, and the read is one per cycle
  # (website/docs-app/apis/github.md, #2330).
  defp watch_pull_requests(label, opts) do
    case watch_pull_request_fetcher(opts).(label) do
      {:ok, pull_requests} when is_list(pull_requests) -> {:ok, pull_requests}
      {:error, _reason} = error -> error
      other -> {:error, {:unexpected_watch_targets, other}}
    end
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

  @spec normalize_comment_targets(list()) :: [String.t()]
  def normalize_comment_targets(targets) when is_list(targets) do
    targets
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end
end
