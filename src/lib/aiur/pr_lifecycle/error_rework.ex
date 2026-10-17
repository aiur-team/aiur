defmodule Aiur.PRLifecycle.ErrorRework do
  @moduledoc """
  Routes `agent:error` tickets whose open PR carries a blocking review to
  `agent:rework` (#4535).

  The review-driven rework triggers only watch tickets in the review states
  (`human-review`, `ci-wait`, `merging`, `rework`). A ticket that landed in
  `agent:error` with a `CHANGES_REQUESTED` review on its open PR was never
  redispatched: #4463 sat in `agent:error` while its PR had an Executor
  changes-requested review until the Executor relabelled it by hand.

  Runs inside the `ReworkRequeue` tick. A ticket is routed when its open PR's
  latest verdict from some trusted reviewer is `CHANGES_REQUESTED` — a later
  approval or dismissal by the same reviewer supersedes it. The PR must be
  ready for review and the review must be on its current head: a push after
  the review means the ticket already answered it. Each
  `{ticket, review}` pair is routed once per daemon lifetime, so a rework turn
  that ends back in `agent:error` is not looped on the same review; a new
  blocking review routes it again. Error tickets with no open PR, or whose PR
  has no blocking review, keep the existing behaviour.
  """

  require Logger
  alias Aiur.Issue

  @doc "Routes each eligible error ticket to rework once; returns the updated worker state."
  @spec scan(map()) :: map()
  def scan(state) do
    case state.error_tickets_fetcher.() do
      {:ok, tickets} when is_list(tickets) ->
        tickets
        |> Enum.reject(&(Issue.paused?(&1) or Issue.parked?(&1)))
        |> Enum.reduce(state, &route_ticket/2)

      other ->
        Logger.warning("ErrorRework error-ticket list failed: #{inspect(other)}")
        state
    end
  end

  defp route_ticket(issue, state) do
    key = issue.identifier || issue.id

    # A draft is still being worked; a missing draft flag or head fails closed.
    with {:ok, %{"number" => number, "draft" => false, "head" => %{"sha" => head_sha}} = pr}
         when is_integer(number) and is_binary(head_sha) <- state.open_pr_fetcher.(key),
         {:ok, reviews} when is_list(reviews) <- state.classified_reviews_fetcher.(number),
         %{"id" => review_id, "commit_id" => ^head_sha} = review <- blocking_review(reviews),
         false <- MapSet.member?(state.error_rework_routed, {key, review_id}) do
      write_rework(state, key, pr, review)
    else
      _no_open_pr_or_no_blocking_review -> state
    end
  end

  defp write_rework(state, key, pr, review) do
    case state.state_writer.(to_string(key), "rework") do
      :ok ->
        reviewer = get_in(review, ["user", "login"])
        Logger.info("ErrorRework routed error ticket to rework: issue=#{key} pr=#{pr["number"]} review=#{review["id"]}")

        state.alert_fun.("system.pr_health.error_rework",
          message: "Ticket #{key} was in agent:error with a CHANGES_REQUESTED review on PR ##{pr["number"]}; moved to agent:rework.",
          issue: to_string(key),
          reason: "Review #{review["id"]} by #{reviewer} on PR ##{pr["number"]} still requests changes and nothing dispatches error tickets (#4535).",
          needs_attention: false,
          severity: "info"
        )

        %{state | error_rework_routed: MapSet.put(state.error_rework_routed, {key, review["id"]})}

      {:error, reason} ->
        # Not recorded, so the next tick retries the write.
        Logger.warning("ErrorRework rework write failed: issue=#{key} reason=#{inspect(reason)}")
        state
    end
  end

  @doc "The latest `CHANGES_REQUESTED` review that is still each trusted reviewer's current verdict, or `nil`."
  @spec blocking_review([map()]) :: map() | nil
  def blocking_review(reviews) do
    reviews
    |> Enum.filter(&(&1["state"] in ~w(APPROVED CHANGES_REQUESTED DISMISSED)))
    |> Enum.group_by(&get_in(&1, ["user", "login"]))
    |> Enum.map(fn {_author, submissions} -> Enum.max_by(submissions, &{&1["submitted_at"], &1["id"]}) end)
    |> Enum.filter(&(&1[:authoritative] == true and &1["state"] == "CHANGES_REQUESTED"))
    |> Enum.max_by(&{&1["submitted_at"], &1["id"]}, fn -> nil end)
  end
end
