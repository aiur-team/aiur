defmodule Aiur.Orchestrator.ReworkRequeue do
  @moduledoc """
  The inverse of #2337 cause 2's auto-rework trigger.

  Cause 2 moves a ticket to `agent:rework` on a live `CHANGES_REQUESTED`
  review. Nothing ever moved it back: GitHub keeps `reviewDecision =
  CHANGES_REQUESTED` until a *brand-new* review, so a genuinely reworked PR
  kept its stale verdict, the ticket sat in `agent:rework`, and the reviewer
  waited for a second look that nothing scheduled. Measured on this repo: 15 of
  20 `CHANGES_REQUESTED` PRs were already reworked and simply stuck (#2337
  review follow-up, 2026-08-23).

  This worker periodically re-reads rework tickets and re-queues a PR for
  review when its own contribution has genuinely changed since the blocking
  review:

  * `:addressed` — the PR's own contribution diff (`merge-base..head`) changed
    since the blocking review. Re-queue: write `agent:human-review` so the
    reviewer sees the reworked PR again. This is a direct state write, the
    mirror of the rework trigger; the thread-clearance gate used by agent-side
    `human-review` claims does not apply because GitHub holds
    `reviewDecision=CHANGES_REQUESTED` until a new review.
  * `:merge_only` — commits landed since the blocking review but the own
    contribution diff is byte-identical (only merges of the base branch). NOT
    re-queued — a full review on an unchanged PR is the exact waste this
    ticket exists to stop — and raised as a distinct needs-attention alert so
    the merge-only state is visible rather than silently filtered (#2296 in the
    review follow-up).
  * `:not_addressed` — the head is still the commit the blocking review judged.
    No-op.
  * `:unknown` — transient fetch failure. No-op (fail closed; retried next
    tick).

  Detection is **diff-based, not timestamp-based**: a merge of `main` moves
  `head.sha` and `head_committed_at` without touching the PR's own
  contribution, so a timestamp heuristic wrongly reads a merge-only PR as
  reworked. The comparison of the own contribution at the blocking review's
  `commit_id` (the head the review actually judged) against the current head is
  the reliable signal the follow-up asked for.

  Loop safety: classification is against the LATEST `CHANGES_REQUESTED`
  review. A fresh review posted after rework makes the head equal the new
  review's `commit_id` → `:not_addressed`, so the ticket stays in rework and
  nothing re-queues. Once re-queued, the ticket leaves the `agent:rework`
  set and this worker drops it.

  Opt-in via `pr_health.enabled` (same cadence as the PR-health scanner), so a
  repo that has not opted into the scan pays no GitHub API budget. Steady-state
  cost is bounded: a ticket's reviews and compare are only re-read when its PR
  head changes (`last_seen` throttle).
  """

  use Aiur.PeriodicWorker

  require Logger

  alias Aiur.{Alerts, Issue, Tracker}
  alias Aiur.GitHub.Client, as: GitHubClient
  alias Aiur.GitHub.Config, as: GitHubConfig
  alias Aiur.GitHub.Tracker, as: GitHubTracker

  @default_interval_ms 30 * 60 * 1_000

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    # Constant defaults here, not a config read: boot must never depend on the
    # workflow config being loadable at child-init time. The tick re-reads the
    # configured cadence each cycle, so an edit applies without a restart.
    state = %{
      interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms),
      tickets_fetcher: Keyword.get(opts, :tickets_fetcher, &default_tickets/0),
      open_pr_fetcher: Keyword.get(opts, :open_pr_fetcher, &default_open_pr/1),
      reviews_fetcher: Keyword.get(opts, :reviews_fetcher, &default_reviews/1),
      diff_fetcher: Keyword.get(opts, :diff_fetcher, &default_diff/1),
      state_writer: Keyword.get(opts, :state_writer, &Tracker.update_issue_state/2),
      alert_fun: Keyword.get(opts, :alert_fun, &Alerts.emit_system/2),
      enabled?: Keyword.get(opts, :enabled?, &default_enabled?/0),
      # Per-ticket throttle: id => %{head_sha: String.t(), classification: atom()}.
      # A ticket whose head has not changed since we classified it is not
      # re-read, so a steady-state tick makes no reviews/compare calls.
      last_seen: %{},
      # Merge-only tickets already alerted once, pruned when they leave rework.
      merge_only_alerted: MapSet.new(),
      start_paused?: Keyword.get(opts, :start_paused?, false)
    }

    {:ok, Aiur.PeriodicWorker.schedule_first_tick(state)}
  end

  @impl Aiur.PeriodicWorker
  def tick(state) do
    state = refresh_from_config(state)

    if state.enabled?.() do
      scan(state)
    else
      state
    end
  end

  # Re-read the configured cadence each cycle so a config edit applies without
  # a restart; falls back to the previous value when the workflow config is not
  # readable at that moment (early boot, mid-reload).
  defp refresh_from_config(state) do
    Map.put(state, :next_delay_ms, config_value(&GitHubConfig.pr_health_interval_ms/0, state.interval_ms))
  end

  defp config_value(fun, fallback) do
    fun.()
  rescue
    _error -> fallback
  catch
    _kind, _reason -> fallback
  end

  defp default_enabled? do
    GitHubConfig.pr_health_enabled?() and Tracker.adapter() == GitHubTracker
  rescue
    _error -> false
  catch
    _kind, _reason -> false
  end

  defp default_tickets, do: Tracker.fetch_issues_by_states(["rework"])

  defp default_open_pr(issue_key), do: Tracker.fetch_open_pull_request_for_branch(issue_key)

  # `fetch_pull_request_reviews/2` was retired (#2326) in favour of the
  # conditional reader; adapt its 3-tuple back to the `{:ok, list}` shape the
  # `reviews_fetcher` contract promises. No etag is held, so a 304 cannot occur.
  defp default_reviews(pr_number) do
    case GitHubClient.fetch_pull_request_reviews_conditional(pr_number) do
      {:ok, reviews, _etag} when is_list(reviews) -> {:ok, reviews}
      {:not_modified, _etag} -> {:ok, []}
      {:error, reason} -> {:error, reason}
    end
  end

  defp default_diff({base_sha, head_sha}), do: GitHubClient.fetch_compare_files(base_sha, head_sha)

  # ---------------------------------------------------------------------------
  # Scan
  # ---------------------------------------------------------------------------

  defp scan(state) do
    case state.tickets_fetcher.() do
      {:ok, tickets} when is_list(tickets) ->
        {last_seen, findings} = collect_findings(tickets, state.last_seen, state)

        Enum.reduce(findings, state, &apply_finding/2)
        |> Map.put(:last_seen, prune_last_seen(last_seen, tickets))
        |> Map.update!(:merge_only_alerted, &prune_merge_only_alerted(&1, tickets))

      {:error, reason} ->
        Logger.warning("ReworkRequeue rework-ticket list failed: reason=#{inspect(reason)}")
        state
    end
  end

  defp collect_findings(tickets, last_seen, state) do
    Enum.reduce(tickets, {last_seen, []}, fn issue, {last_seen_acc, findings_acc} ->
      key = issue_key(issue)

      case classify_issue(issue, last_seen, state) do
        :skip ->
          {last_seen_acc, findings_acc}

        {classification, _head_sha} when classification == :unknown ->
          # A transient fetch failure must be retried, so it is deliberately not
          # cached: the head stays "unseen" and the next tick re-reads it.
          {last_seen_acc, [{issue, classification} | findings_acc]}

        {classification, head_sha} ->
          updated =
            Map.put(last_seen_acc, key, %{head_sha: head_sha, classification: classification})

          {updated, [{issue, classification} | findings_acc]}
      end
    end)
  end

  # Fetch the ticket's open PR and, when the head is new since the last
  # classification, fetch reviews + own-diff and classify. A head we have
  # already classified is a `:skip` — no reviews/compare calls.
  defp classify_issue(issue, last_seen, state) do
    key = issue_key(issue)

    case state.open_pr_fetcher.(key) do
      {:ok, %{"head" => %{"sha" => head_sha}} = pr} when is_binary(head_sha) ->
        case Map.get(last_seen, key) do
          %{head_sha: ^head_sha} -> :skip
          _ -> classify_new_head(issue, pr, head_sha, state)
        end

      _other ->
        :skip
    end
  end

  defp classify_new_head(issue, pr, head_sha, state) do
    case latest_blocking_review_for(issue, pr, state) do
      nil ->
        :skip

      blocking_review ->
        classification = classify(pr, blocking_review, diff_fetcher: state.diff_fetcher)
        {classification, head_sha}
    end
  end

  defp latest_blocking_review_for(issue, _pr, state) do
    case state.reviews_fetcher.(pr_number(issue)) do
      {:ok, reviews} when is_list(reviews) -> latest_blocking_review(reviews)
      _other -> nil
    end
  end

  # ---------------------------------------------------------------------------
  # Findings
  # ---------------------------------------------------------------------------

  defp apply_finding({issue, :addressed}, state) do
    key = issue_key(issue)

    case state.state_writer.(to_string(key), "human-review") do
      :ok ->
        Logger.info("ReworkRequeue re-queued reworked PR for review: issue=#{key} -> agent:human-review")
        state

      {:error, reason} ->
        Logger.warning("ReworkRequeue re-queue failed: issue=#{key} reason=#{inspect(reason)}")
        state
    end
  end

  defp apply_finding({issue, :merge_only}, state) do
    key = issue_key(issue)
    number = pr_number(issue)
    title = pr_title(issue)

    if MapSet.member?(state.merge_only_alerted, key) do
      state
    else
      Logger.warning("ReworkRequeue merge-only rework push detected (not re-queued): issue=#{key} pr=#{number}")

      state.alert_fun.(
        "system.pr_health.rework_merge_only",
        message:
          "PR ##{number} (#{title}) moved since its CHANGES_REQUESTED review but only via merges of the base branch — " <>
            "the PR's own contribution is unchanged, so it is still not addressed and has not been re-queued for review.",
        issue: to_string(number),
        reason:
          "The PR's own contribution diff (merge-base..head) is identical to what the blocking review judged; " <>
            "only base-branch merges landed. Re-queueing would spend a full review on an unchanged PR.",
        needs_attention: true,
        severity: "warning"
      )

      %{state | merge_only_alerted: MapSet.put(state.merge_only_alerted, key)}
    end
  end

  defp apply_finding({_issue, _classification}, state), do: state

  defp prune_merge_only_alerted(merge_only_alerted, tickets) do
    active = MapSet.new(tickets, &issue_key/1)
    MapSet.intersection(merge_only_alerted, active)
  end

  # Forget throttle entries for tickets that left `agent:rework` (re-queued,
  # closed, or re-labelled), so the map cannot grow without bound.
  defp prune_last_seen(last_seen, tickets) do
    active = MapSet.new(tickets, &issue_key/1)
    Map.take(last_seen, MapSet.to_list(active))
  end

  # ---------------------------------------------------------------------------
  # Pure classification
  # ---------------------------------------------------------------------------

  @doc """
  Returns the latest `CHANGES_REQUESTED` review in a review list, or `nil`.

  "Latest" is by `submitted_at`. The latest blocking review is the verdict the
  PR must currently be judged against: a review posted after rework keeps the
  ticket in rework (`:not_addressed`), while a stale pre-rework review lets a
  changed own-diff classify as `:addressed`.
  """
  @spec latest_blocking_review([map()]) :: map() | nil
  def latest_blocking_review(reviews) when is_list(reviews) do
    reviews
    |> Enum.filter(&(Map.get(&1, "state") == "CHANGES_REQUESTED"))
    |> Enum.max_by(&Map.get(&1, "submitted_at"), fn -> nil end)
  end

  @doc """
  Classifies a PR's rework state against a blocking review.

  Returns:

  * `:not_addressed` — the current head is the commit the review judged.
  * `:addressed` — the PR's own contribution diff (`merge-base..head`) changed
    since the review's commit; the rework is genuine and the PR should be
    re-queued.
  * `:merge_only` — commits landed but the own contribution diff is identical
    (only merges of the base branch); still not addressed, not re-queued.
  * `:unknown` — a required field (head/base sha, review `commit_id`) is absent
    or the own-diff could not be fetched. Fail closed; retried next tick.

  The own-diff comparison uses the three-dot compare
  (`compare(base...head)`), which excludes the base's own commits from the
  result — so merging the base into the branch does not change the compared
  fingerprint, exactly the "ignore merges of the base branch" requirement.
  """
  @spec classify(map(), map(), keyword()) :: :not_addressed | :addressed | :merge_only | :unknown
  def classify(pr, blocking_review, opts \\ []) when is_map(pr) and is_map(blocking_review) do
    head_sha = get_in(pr, ["head", "sha"])
    review_commit = Map.get(blocking_review, "commit_id")
    base_sha = get_in(pr, ["base", "sha"])

    cond do
      head_sha in [nil, ""] or review_commit in [nil, ""] or base_sha in [nil, ""] -> :unknown
      head_sha == review_commit -> :not_addressed
      true -> classify_by_own_diff(base_sha, review_commit, head_sha, opts)
    end
  end

  defp classify_by_own_diff(base_sha, review_commit, head_sha, opts) do
    diff_fetcher = Keyword.get(opts, :diff_fetcher, &default_diff/1)

    with {:ok, review_files} <- diff_fetcher.({base_sha, review_commit}),
         {:ok, head_files} <- diff_fetcher.({base_sha, head_sha}) do
      if review_files == head_files, do: :merge_only, else: :addressed
    else
      _other -> :unknown
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp issue_key(%Issue{id: id, identifier: _identifier}) when is_binary(id) and id != "",
    do: id

  defp issue_key(%Issue{id: _id, identifier: identifier})
       when is_binary(identifier) and identifier != "",
       do: identifier

  defp issue_key(%Issue{id: id}) when is_binary(id), do: id
  defp issue_key(%Issue{id: id}) when is_integer(id), do: to_string(id)
  defp issue_key(%Issue{identifier: identifier}) when is_binary(identifier), do: identifier
  defp issue_key(_issue), do: ""

  defp pr_number(%Issue{identifier: identifier}) when is_binary(identifier) do
    case Integer.parse(identifier) do
      {number, ""} -> number
      _other -> nil
    end
  end

  defp pr_number(_issue), do: nil

  defp pr_title(%Issue{title: title}) when is_binary(title), do: title
  defp pr_title(_issue), do: ""
end
