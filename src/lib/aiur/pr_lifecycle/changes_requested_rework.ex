defmodule Aiur.PRLifecycle.ChangesRequestedRework do
  @moduledoc """
  Moves a waiting ticket to `agent:rework` when the configured reviewer's
  latest verdict is `CHANGES_REQUESTED` at the PR's current head (#4811).

  `Aiur.Orchestrator.CommentWake` routes a review submission when it is
  delivered, but a submission is delivered once and that path has racy exits
  that drop it without a label write: a review landing while a rework turn is
  handing itself back is folded into that ending turn's digest (#4528 / PR
  #4794), and a runner that changes mid-gate discards the result (#3145 / PR
  #4805). The Executor then relabels by hand. This worker is the
  level-triggered backstop: it re-reads `agent:human-review` and
  `agent:ci-wait` tickets and derives the verdict from the PR itself.

  A ticket moves only when all hold: the PR is open, the reviewer is
  authoritative (`Aiur.CodeHost.fetch_classified_pr_reviews/1`), that
  reviewer's latest `APPROVED`/`CHANGES_REQUESTED`/`DISMISSED` review is
  `CHANGES_REQUESTED`, and its `commit_id` is the PR's `head.sha`. `COMMENTED`
  reviews never move a ticket here.

  Each review id is routed at most once. A rework turn that disputes every
  finding hands back at the same head, and routing that review again would loop.
  Reviews seen at the head of an `agent:rework` ticket count as routed, so a
  review the event path already acted on is not routed a second time.

  The `rework` write goes through `TicketTransition.write_state/3` with
  `expected_state`, so it adds the new label before removing the old one and
  refuses if the ticket moved since it was read.

  Opt-in with `pr_health.enabled`, like `Aiur.PRLifecycle.ReworkRequeue`.
  """

  use Aiur.PeriodicWorker

  require Logger
  alias Aiur.GitHub.Config, as: GitHubConfig
  alias Aiur.{Issue, Tracker}
  alias Aiur.Orchestrator.TicketTransition

  @default_interval_ms 5 * 60 * 1_000
  @waiting_states ["human-review", "ci-wait"]
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
      tickets_fetcher: Keyword.get(opts, :tickets_fetcher, fn -> Tracker.fetch_issues_by_states(["rework" | @waiting_states]) end),
      open_pr_fetcher: Keyword.get(opts, :open_pr_fetcher, &Aiur.CodeHost.fetch_open_pull_request_for_branch/1),
      reviews_fetcher: Keyword.get(opts, :reviews_fetcher, &Aiur.CodeHost.fetch_classified_pr_reviews/1),
      tracker: Keyword.get(opts, :tracker, Tracker),
      enabled?: Keyword.get(opts, :enabled?, &default_enabled?/0),
      # Review ids already routed (or observed on a rework ticket). In memory: a
      # restart can route a disputed same-head review once more.
      routed: MapSet.new(),
      start_paused?: Keyword.get(opts, :start_paused?, false)
    }

    {:ok, Aiur.PeriodicWorker.schedule_first_tick(state)}
  end

  @impl Aiur.PeriodicWorker
  def tick(state) do
    if state.enabled?.(), do: scan(state), else: state
  end

  defp default_enabled? do
    GitHubConfig.pr_health_enabled?() and Aiur.CodeHost.available?()
  rescue
    _error -> false
  catch
    _kind, _reason -> false
  end

  defp scan(state) do
    case state.tickets_fetcher.() do
      {:ok, tickets} when is_list(tickets) ->
        Enum.reduce(tickets, state, &scan_ticket/2)

      {:error, reason} ->
        Logger.warning("ChangesRequestedRework ticket list failed: reason=#{inspect(reason)}")
        state
    end
  end

  defp scan_ticket(%Issue{} = issue, state) do
    from_state = String.replace_prefix(issue.state || "", "agent:", "")

    with false <- Issue.parked?(issue),
         %{"id" => id} = review <- live_changes_request(issue, state),
         false <- MapSet.member?(state.routed, id) do
      route(issue, from_state, review, state)
    else
      _no_live_unrouted_review -> state
    end
  end

  defp scan_ticket(_issue, state), do: state

  defp route(_issue, "rework", %{"id" => id}, state), do: mark(state, id)

  defp route(issue, from_state, %{"id" => id}, state) when from_state in @waiting_states do
    opts = [writer: :changes_requested_rework, expected_state: from_state, identifier: issue.identifier, tracker: state.tracker]

    case TicketTransition.write_state(issue.id, "rework", opts) do
      :ok ->
        Logger.info("ChangesRequestedRework moved issue=#{issue.identifier} #{from_state} -> rework review=#{id}")
        mark(state, id)

      {:error, reason} ->
        # Not marked: the next tick retries.
        Logger.warning("ChangesRequestedRework rework write failed: issue=#{issue.identifier} reason=#{inspect(reason)}")
        state
    end
  end

  defp route(_issue, _from_state, _review, state), do: state

  defp mark(state, id), do: %{state | routed: MapSet.put(state.routed, id)}

  defp live_changes_request(issue, state) do
    with {:ok, %{"number" => number, "head" => %{"sha" => head}} = pr} when is_integer(number) and is_binary(head) <-
           state.open_pr_fetcher.(issue.identifier),
         true <- Map.get(pr, "state", "open") == "open",
         {:ok, reviews} when is_list(reviews) <- state.reviews_fetcher.(number) do
      changes_request_at_head(reviews, head)
    else
      _no_open_pr_or_unreadable -> nil
    end
  end

  @doc "The authoritative `CHANGES_REQUESTED` review that is some reviewer's latest verdict at `head`, or `nil`."
  @spec changes_request_at_head([map()], String.t()) :: map() | nil
  def changes_request_at_head(reviews, head) do
    reviews
    |> Enum.filter(&(&1[:authoritative] == true and &1["state"] in @verdicts))
    |> Enum.group_by(&get_in(&1, ["user", "login"]))
    |> Enum.map(fn {_login, verdicts} -> Enum.max_by(verdicts, &{&1["submitted_at"], &1["id"]}) end)
    |> Enum.find(&(&1["state"] == "CHANGES_REQUESTED" and &1["commit_id"] == head))
  end
end
