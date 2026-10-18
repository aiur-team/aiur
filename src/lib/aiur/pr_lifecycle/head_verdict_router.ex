defmodule Aiur.PRLifecycle.HeadVerdictRouter do
  @moduledoc """
  Routes a ticket on the configured reviewer's verdict at its PR's current head
  (#4811):

    * `CHANGES_REQUESTED` at the head moves `agent:human-review` or
      `agent:ci-wait` to `agent:rework`;
    * `APPROVED` at the head that supersedes the same reviewer's
      `CHANGES_REQUESTED` at that same head moves `agent:rework` to
      `agent:ci-wait`: the findings were answered without a push (for example
      a PR-body fix), so no worker should push onto the approved PR;
    * `CHANGES_REQUESTED` at the head moves `agent:error` to `agent:rework`
      and raises `system.pr_health.error_rework` (#4535): nothing else
      dispatches an error ticket, so a blocking review would otherwise sit
      until the Executor relabels it. A paused error ticket is skipped.

  An approval that does not follow a same-head changes request never routes.
  CI failure, a merge-group failure and a restack conflict all move an approved
  ticket to `agent:rework` with the approval still at the head; routing that
  approval would undo them before the fixer pushes. An approval first seen on
  an `agent:human-review` or `agent:ci-wait` ticket is marked routed for the
  same reason.

  `Aiur.Orchestrator.CommentWake` routes a review submission when it is
  delivered, but a submission is delivered once and that path has racy exits
  that drop it without a label write: a review landing while a rework turn is
  handing itself back is folded into that ending turn's digest (#4528 / PR
  #4794), and a runner that changes mid-gate discards the result (#3145 / PR
  #4805). The Executor then relabels by hand. This worker is the
  level-triggered backstop: it re-reads the tickets and derives the verdict
  from the PR itself.

  A verdict counts only when the PR is open and ready for review (a draft, or a
  listing without the draft flag, is still being worked), the reviewer is authoritative
  (`Aiur.CodeHost.fetch_classified_pr_reviews/1`), the review is that
  reviewer's latest `APPROVED`/`CHANGES_REQUESTED`/`DISMISSED` review, and its
  `commit_id` is the PR's `head.sha`. `COMMENTED` reviews never route.

  Each review id routes at most once. A rework turn that disputes every finding
  hands back at the same head, and routing that review again would loop. A
  changes request seen at the head of an `agent:rework` ticket counts as
  routed, so a review the event path already acted on is not routed twice.

  Writes go through `TicketTransition.write_state/3` with `expected_state`, so
  they add the new label before removing the old one and refuse if the ticket
  moved since it was read.

  Opt-in with `pr_health.enabled` and paced by `pr_health.interval_seconds`,
  like `Aiur.PRLifecycle.ReworkRequeue`. A tick makes one open-pull-request
  listing (one page for up to 100 open PRs) and re-reads a PR's reviews only
  when its `head.sha` or `updated_at` changed since the last tick (a submitted
  or dismissed review bumps `updated_at`). With the four state-label issue
  listings, the default 1800s cadence makes 10 listing calls an hour plus one
  conditional reviews read per changed PR.
  """

  use Aiur.PeriodicWorker

  require Logger
  alias Aiur.GitHub.Client, as: GitHubClient
  alias Aiur.GitHub.Config, as: GitHubConfig
  alias Aiur.{Issue, Signal, TicketBranch, Tracker}
  alias Aiur.Orchestrator.TicketTransition

  @default_interval_ms 30 * 60 * 1_000
  @waiting_states ["human-review", "ci-wait"]
  @requestable_states ["error" | @waiting_states]
  @verdicts ~w(APPROVED CHANGES_REQUESTED DISMISSED)

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    state = %{
      interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms),
      tickets_fetcher: Keyword.get(opts, :tickets_fetcher, fn -> Tracker.fetch_issues_by_states(["rework" | @requestable_states]) end),
      open_prs_fetcher: Keyword.get(opts, :open_prs_fetcher, &GitHubClient.fetch_open_pull_requests/0),
      reviews_fetcher: Keyword.get(opts, :reviews_fetcher, &Aiur.CodeHost.fetch_classified_pr_reviews/1),
      tracker: Keyword.get(opts, :tracker, Tracker),
      alert_fun: Keyword.get(opts, :alert_fun, &Signal.alert/2),
      enabled?: Keyword.get(opts, :enabled?, &default_enabled?/0),
      # Review ids already routed (or observed on a rework ticket). Error routes
      # use a ticket-scoped key so a prior waiting/rework observation cannot
      # suppress the error-state recovery route. In memory: a
      # restart can route a disputed same-head review once more, or re-route a
      # body-fix approval after CI moved that ticket back to rework (one wasted
      # landing cycle until the next failure returns it).
      routed: MapSet.new(),
      # PR number => {head sha, updated_at, deciding review or nil}. The reviews
      # read is skipped while both are unchanged.
      verdicts: %{},
      start_paused?: Keyword.get(opts, :start_paused?, false)
    }

    {:ok, Aiur.PeriodicWorker.schedule_first_tick(state)}
  end

  @impl Aiur.PeriodicWorker
  def tick(state) do
    state = Map.put(state, :next_delay_ms, config_value(&GitHubConfig.pr_health_interval_ms/0, state.interval_ms))
    if state.enabled?.(), do: scan(state), else: state
  end

  defp config_value(fun, fallback) do
    fun.()
  rescue
    _error -> fallback
  catch
    _kind, _reason -> fallback
  end

  defp default_enabled? do
    GitHubConfig.pr_health_enabled?() and Aiur.CodeHost.available?()
  rescue
    _error -> false
  catch
    _kind, _reason -> false
  end

  defp scan(state) do
    with {:ok, [_ | _] = tickets} <- state.tickets_fetcher.(),
         {:ok, prs} when is_list(prs) <- state.open_prs_fetcher.() do
      state = Enum.reduce(tickets, state, &scan_ticket(&1, prs, &2))
      open = MapSet.new(prs, & &1["number"])
      %{state | verdicts: Map.filter(state.verdicts, fn {number, _cached} -> number in open end)}
    else
      {:ok, _no_tickets} ->
        state

      {:error, reason} ->
        Logger.warning("HeadVerdictRouter list failed: reason=#{inspect(reason)}")
        state
    end
  end

  defp scan_ticket(%Issue{} = issue, prs, state) do
    from_state = String.replace_prefix(issue.state || "", "agent:", "")

    with false <- Issue.held?(issue) or (from_state == "error" and Issue.paused?(issue)),
         %{"draft" => false} = pr <- Enum.find(prs, &ticket_pr?(&1, issue.identifier)),
         {%{"id" => id} = review, state} <- live_verdict(pr, state),
         false <- MapSet.member?(state.routed, routed_key(from_state, id)) do
      route(issue, from_state, review, state)
    else
      {nil, state} -> state
      _no_live_unrouted_verdict -> state
    end
  end

  defp scan_ticket(_issue, _prs, state), do: state

  # The listing is newest first, so a ticket with two open PRs routes on the newer.
  defp ticket_pr?(%{"head" => %{"ref" => ref}}, identifier), do: TicketBranch.ticket_branch?(ref, identifier)
  defp ticket_pr?(_pr, _identifier), do: false

  defp route(_issue, "rework", %{"state" => "CHANGES_REQUESTED", "id" => id}, state), do: mark(state, id, "rework")

  defp route(issue, from_state, %{"state" => "CHANGES_REQUESTED"} = review, state) when from_state in @requestable_states,
    do: write(issue, from_state, "rework", review, state)

  defp route(issue, "rework", %{"state" => "APPROVED", :supersedes_changes_request => true} = review, state),
    do: write(issue, "rework", "ci-wait", review, state)

  defp route(_issue, from_state, %{"state" => "APPROVED", "id" => id}, state) when from_state in @waiting_states,
    do: mark(state, id, from_state)

  defp route(_issue, _from_state, _review, state), do: state

  defp write(issue, from_state, to_state, %{"id" => id} = review, state) do
    opts = [writer: :head_verdict_router, expected_state: from_state, identifier: issue.identifier, tracker: state.tracker]

    case TicketTransition.write_state(issue.id, to_state, opts) do
      :ok ->
        Logger.info("HeadVerdictRouter moved issue=#{issue.identifier} #{from_state} -> #{to_state} review=#{id}")
        if from_state == "error", do: alert_error_rework(issue, review, state)
        mark(state, id, from_state)

      {:error, reason} ->
        # Not marked: the next tick retries.
        Logger.warning("HeadVerdictRouter #{to_state} write failed: issue=#{issue.identifier} reason=#{inspect(reason)}")
        state
    end
  end

  defp alert_error_rework(issue, %{"id" => id} = review, state) do
    state.alert_fun.("system.pr_health.error_rework",
      message: "Ticket #{issue.identifier} was in agent:error with a CHANGES_REQUESTED review at its PR head; moved to agent:rework.",
      issue: to_string(issue.identifier),
      reason: "Review #{id} by #{get_in(review, ["user", "login"])} still requests changes and nothing dispatches error tickets (#4535).",
      needs_attention: false,
      severity: "info"
    )
  end

  defp routed_key("error", id), do: {:error, id}
  defp routed_key(_state, id), do: id

  defp mark(state, id, from_state), do: %{state | routed: MapSet.put(state.routed, routed_key(from_state, id))}

  defp live_verdict(%{"number" => number, "head" => %{"sha" => head}} = pr, state) when is_integer(number) and is_binary(head) do
    updated_at = pr["updated_at"]

    case state.verdicts do
      %{^number => {^head, ^updated_at, review}} when is_binary(updated_at) ->
        {review, state}

      _changed_or_unseen ->
        with "open" <- Map.get(pr, "state", "open"),
             {:ok, reviews} when is_list(reviews) <- state.reviews_fetcher.(number) do
          review = verdict_at_head(reviews, head)
          {review, %{state | verdicts: Map.put(state.verdicts, number, {head, updated_at, review})}}
        else
          # Not cached: the next tick re-reads.
          _closed_or_unreadable -> {nil, state}
        end
    end
  end

  defp live_verdict(_pr, state), do: {nil, state}

  @doc """
  The review that decides routing at `head`: an authoritative reviewer's latest
  verdict that is `CHANGES_REQUESTED` at `head`, else one that is `APPROVED` at
  `head`, else `nil`. An approval carries `supersedes_changes_request: true`
  when that reviewer's previous verdict was `CHANGES_REQUESTED` at `head`.
  """
  @spec verdict_at_head([map()], String.t()) :: map() | nil
  def verdict_at_head(reviews, head) do
    at_head =
      reviews
      |> Enum.filter(&(&1[:authoritative] == true and &1["state"] in @verdicts))
      |> Enum.group_by(&get_in(&1, ["user", "login"]))
      |> Enum.map(fn {_login, verdicts} -> Enum.sort_by(verdicts, &{&1["submitted_at"], &1["id"]}, :desc) end)
      |> Enum.filter(&(hd(&1)["commit_id"] == head))
      |> Enum.map(&with_supersede(&1, head))

    Enum.find(at_head, &(&1["state"] == "CHANGES_REQUESTED")) || Enum.find(at_head, &(&1["state"] == "APPROVED"))
  end

  defp with_supersede([latest | earlier], head) do
    supersedes? = match?([%{"state" => "CHANGES_REQUESTED", "commit_id" => ^head} | _], earlier)
    Map.put(latest, :supersedes_changes_request, supersedes?)
  end
end
