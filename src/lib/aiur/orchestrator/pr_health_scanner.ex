defmodule Aiur.Orchestrator.PRHealthScanner do
  @moduledoc """
  Periodically scans open pull requests for the two conditions that stall PRs
  silently for days (#2337, causes 1 and 3):

  * **Unmergeable author (cause 1)** — a PR authored by a configured human
    merger can never be approved or merged: GitHub blocks self-approval, and
    the human merger set is the only identity that approves and merges. Such a
    PR accrues review attention that can never result in a merge. The scanner
    flags it loudly — a needs-attention alert plus a one-time bot comment on
    the PR — instead of letting it sit for four days.
  * **Ageing, unreviewed PR (cause 3)** — a non-draft PR older than the
    configured `pr_health.stale_hours` threshold with no completed review is
    unseen, not blocked or conflicted. The scanner raises a needs-attention
    alert, the same way a stale agent does, so an ageing PR surfaces in the
    Executor's alert feed instead of depending on someone remembering to fan
    out.

  Runs on the `pr_health` cadence (`pr_health.interval_seconds`, default 30
  minutes) as an opt-in supervised worker (`pr_health.enabled`). The open-PR
  list is a plain `GET /pulls?state=open`; only candidate PRs (very few — the
  4-day tail and the human-merger PRs) incur a per-PR reviews read. Alerts are
  deduped per condition per PR while the PR keeps matching, so a steady-state
  scan costs one list read and no repeated alerts.

  The scan is deliberately separate from the orchestrator's hot poll path: a
  burst of open PRs or a slow reviews endpoint must never delay dispatch.
  """

  use Aiur.PeriodicWorker

  require Logger

  alias Aiur.{Alerts, Tracker}
  alias Aiur.GitHub.Client, as: GitHubClient
  alias Aiur.GitHub.Config, as: GitHubConfig
  alias Aiur.GitHub.Tracker, as: GitHubTracker

  @default_interval_ms 30 * 60 * 1_000
  @default_stale_hours 24

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
    # configured interval and threshold each cycle, so an edit applies without
    # a restart and a config that is briefly unreadable falls back to the
    # previous values instead of crashing the schedule.
    state = %{
      interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms),
      stale_hours: Keyword.get(opts, :stale_hours, @default_stale_hours),
      open_prs_fetcher: Keyword.get(opts, :open_prs_fetcher, &default_open_prs/0),
      reviews_fetcher: Keyword.get(opts, :reviews_fetcher, &default_reviews/1),
      human_mergers_fun: Keyword.get(opts, :human_mergers_fun, &GitHubConfig.human_mergers/0),
      comment_fun: Keyword.get(opts, :comment_fun, &Tracker.create_comment/2),
      alert_fun: Keyword.get(opts, :alert_fun, &Alerts.emit_system/2),
      enabled?: Keyword.get(opts, :enabled?, &default_enabled?/0),
      alerted: MapSet.new(),
      commented: MapSet.new(),
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

  # Re-read the configured cadence and threshold each cycle so a config edit
  # applies without a restart. Both fall back to the previous value when the
  # workflow config is not readable at that moment (early boot, mid-reload).
  defp refresh_from_config(state) do
    state
    |> Map.put(:stale_hours, config_value(&GitHubConfig.pr_health_stale_hours/0, state.stale_hours))
    |> Map.put(:next_delay_ms, config_value(&GitHubConfig.pr_health_interval_ms/0, state.interval_ms))
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

  # ---------------------------------------------------------------------------
  # Scan
  # ---------------------------------------------------------------------------

  defp scan(state) do
    case state.open_prs_fetcher.() do
      {:ok, prs} when is_list(prs) ->
        human_mergers = state.human_mergers_fun.()
        {unmergeable, stale_candidates} = evaluate(prs, state.stale_hours, DateTime.utc_now(), human_mergers)

        state =
          unmergeable
          |> Enum.reduce(state, &flag_unmergeable/2)

        state =
          stale_candidates
          |> Enum.reduce(state, &flag_stale_if_unreviewed/2)

        prune_resolved(state, prs, unmergeable, stale_candidates)

      {:error, reason} ->
        Logger.warning("PRHealthScanner open-PR list failed: reason=#{inspect(reason)}")
        state
    end
  end

  @doc """
  Pure evaluation of one open-PR list into `{unmergeable, stale_unreviewed}`
  findings. Exposed for tests so the decision rules are asserted without
  driving the worker.

  * `unmergeable` — open PRs authored by a configured human merger.
  * `stale_unreviewed` — non-draft PRs older than `stale_hours` (caller still
    has to confirm each has no review before alerting).
  """
  @spec evaluate(list(), integer(), DateTime.t(), [String.t()]) ::
          {[map()], [map()]}
  def evaluate(prs, stale_hours, now, human_mergers) when is_list(prs) and is_list(human_mergers) do
    unmergeable = Enum.filter(prs, &unmergeable_author?(&1, human_mergers))
    stale_unreviewed = Enum.filter(prs, &stale_unreviewed_candidate?(&1, stale_hours, now))
    {unmergeable, stale_unreviewed}
  end

  # Unmergeable-author flagging (cause 1): alert once, comment once.
  defp flag_unmergeable(pr, state) do
    number = pr_number(pr)
    key = {:unmergeable, number}

    if MapSet.member?(state.alerted, key) do
      state
    else
      state
      |> emit_unmergeable_alert(pr)
      |> comment_unmergeable(pr)
      |> Map.put(:alerted, MapSet.put(state.alerted, key))
    end
  end

  defp emit_unmergeable_alert(state, pr) do
    number = pr_number(pr)
    author = pr_author(pr)
    title = pr_title(pr)

    state.alert_fun.(
      "system.pr_health.unmergeable_author",
      message: "PR ##{number} (#{title}) is authored by #{author}, who is also the only identity that approves and merges; GitHub blocks self-approval, so this PR can never merge.",
      issue: to_string(number),
      reason: "PR authored by a configured human merger is unmergeable by construction; flag it at open instead of letting it accrue review attention.",
      needs_attention: true,
      severity: "warning"
    )

    state
  end

  defp comment_unmergeable(state, pr) do
    number = pr_number(pr)
    author = pr_author(pr)

    if MapSet.member?(state.commented, number) do
      state
    else
      body =
        "This PR is authored by `#{author}`, which is also the only identity that approves and merges. " <>
          "GitHub blocks self-approval, so this PR cannot be merged by construction — " <>
          "it will sit unmerged unless another approved merger reviews and merges it, " <>
          "or the branch is re-based into an agent-authored PR."

      case state.comment_fun.(to_string(number), body) do
        :ok ->
          %{state | commented: MapSet.put(state.commented, number)}

        {:error, reason} ->
          Logger.warning("PRHealthScanner unmergeable-author comment failed: pr=#{number} reason=#{inspect(reason)}")
          state
      end
    end
  end

  # Ageing-unreviewed flagging (cause 3): the list read already bounded
  # candidates; each candidate pays one reviews read to confirm it truly has no
  # completed review before alerting.
  defp flag_stale_if_unreviewed(pr, state) do
    number = pr_number(pr)
    key = {:stale_unreviewed, number}

    if MapSet.member?(state.alerted, key) do
      state
    else
      case state.reviews_fetcher.(number) do
        {:ok, reviews} when is_list(reviews) ->
          if has_review?(reviews) do
            state
          else
            emit_stale_alert(state, pr)
            %{state | alerted: MapSet.put(state.alerted, key)}
          end

        {:error, reason} ->
          Logger.warning("PRHealthScanner stale-PR reviews fetch failed: pr=#{number} reason=#{inspect(reason)}")
          state
      end
    end
  end

  defp emit_stale_alert(state, pr) do
    number = pr_number(pr)
    title = pr_title(pr)
    age_hours = pr_age_hours(pr, DateTime.utc_now())

    state.alert_fun.(
      "system.pr_health.stale_unreviewed",
      message: "PR ##{number} (#{title}) has been open #{age_hours} hours with no review — it is unseen, not blocked.",
      issue: to_string(number),
      reason: "Non-draft PR older than the pr_health.stale_hours threshold with no completed review.",
      needs_attention: true,
      severity: "warning"
    )

    state
  end

  # Forget alert/comment dedup for PRs that no longer match any finding (closed,
  # merged, reviewed, or no longer authored by a human merger), so a recurrence
  # alerts again and the maps cannot grow without bound.
  defp prune_resolved(state, prs, unmergeable, stale_candidates) do
    active_unmergeable = MapSet.new(unmergeable, &{:unmergeable, pr_number(&1)})
    active_stale = MapSet.new(stale_candidates, &{:stale_unreviewed, pr_number(&1)})
    active = MapSet.union(active_unmergeable, active_stale)
    active_numbers = MapSet.new(prs, &pr_number/1)

    %{
      state
      | alerted: MapSet.intersection(state.alerted, active),
        commented: MapSet.intersection(state.commented, active_numbers)
    }
  end

  # ---------------------------------------------------------------------------
  # Decision rules
  # ---------------------------------------------------------------------------

  defp unmergeable_author?(pr, human_mergers) do
    case pr_author(pr) do
      nil -> false
      author -> GitHubConfig.human_merger_allowed?(author, human_mergers)
    end
  end

  # A candidate must be non-draft and older than the threshold. `draft?/1`
  # returns true only when the PR is explicitly a draft, so the default (field
  # absent) counts as non-draft.
  defp stale_unreviewed_candidate?(pr, stale_hours, now) do
    case {draft?(pr), pr_age_hours(pr, now)} do
      {false, age_hours} when is_integer(age_hours) -> age_hours >= stale_hours
      _other -> false
    end
  end

  defp draft?(pr), do: Map.get(pr, "draft") == true

  defp has_review?(reviews) do
    Enum.any?(reviews, fn review ->
      case Map.get(review, "state") do
        state when is_binary(state) -> String.upcase(state) != "PENDING"
        _other -> false
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # PR field helpers
  # ---------------------------------------------------------------------------

  defp pr_number(pr) when is_map(pr) do
    case Map.get(pr, "number") do
      number when is_integer(number) -> number
      number when is_binary(number) -> number
      _other -> nil
    end
  end

  defp pr_author(pr) do
    case get_in(pr, ["user", "login"]) do
      login when is_binary(login) and login != "" -> login
      _other -> nil
    end
  end

  defp pr_title(pr) do
    case Map.get(pr, "title") do
      title when is_binary(title) and title != "" -> title
      _other -> "untitled"
    end
  end

  defp pr_age_hours(pr, now) do
    with created_at when is_binary(created_at) <- Map.get(pr, "created_at"),
         {:ok, created, _offset} <- DateTime.from_iso8601(created_at) do
      max(DateTime.diff(now, created, :hour), 0)
    else
      _other -> nil
    end
  end

  defp default_open_prs, do: GitHubClient.fetch_open_pull_requests()
  defp default_reviews(pr_number), do: GitHubClient.fetch_pull_request_reviews(pr_number)
end
