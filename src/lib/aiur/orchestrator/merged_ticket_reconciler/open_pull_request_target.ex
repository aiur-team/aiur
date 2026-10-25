defmodule Aiur.Orchestrator.MergedTicketReconciler.OpenPullRequestTarget do
  @moduledoc false

  require Logger
  alias Aiur.Orchestrator.ReworkGate
  @stale_draft_after_seconds 7 * 24 * 60 * 60

  @doc """
  Decides where a ticket named by a merged PR should land.

  Before any path writes `done` for a merged-PR ticket it must consult this,
  because a ticket can legitimately carry more than one open pull request — two
  `aiur/<ticket>-<slug>` branches worked in parallel. Returns `{:ok, "done"}`
  only when no blocking open PR remains, `{:ok, "rework"}` when a remaining open
  PR has unresolved review findings, `{:ok, "ci-wait"}` when all remaining PRs
  await CI, `{:ok, "human-review"}` when they otherwise await review, and
  `{:error, reason}` when the open-PR lookup itself failed — callers must never
  close the ticket on that path.

  A remaining open PR that is a stale draft does not block `done`: a superseded
  or abandoned attempt left open forever must not pin its ticket out of its
  terminal state. Every other open PR blocks, because its review findings or
  review state are still live work.

  The open-PR listing and the per-PR unresolved-findings predicate are
  injectable via opts (`:open_pull_requests_fun` and
  `:open_pull_request_unresolved_findings_fun`) so callers can supply their own
  review-state source. The defaults route unresolved review threads through
  `ReworkGate` — the single place that owns that rule (#2450) — via the tracker
  boundary.
  """
  @spec merged_ticket_target(String.t() | integer(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def merged_ticket_target(identifier, opts)
      when is_binary(identifier) or is_integer(identifier) do
    open_pull_requests_fun =
      Keyword.get(
        opts,
        :open_pull_requests_fun,
        &Aiur.CodeHost.fetch_open_pull_requests_for_branch/1
      )

    case open_pull_requests_fun.(to_string(identifier)) do
      {:ok, []} ->
        {:ok, "done"}

      {:ok, pull_requests} when is_list(pull_requests) ->
        merged_ticket_target_for_open_pull_requests(pull_requests, opts)

      {:ok, _other} ->
        # An unexpected listing shape must never close the ticket: fail safe so
        # the caller retains it and retries rather than guessing at done.
        {:error, :invalid_open_pull_requests_listing}

      {:error, _reason} = error ->
        error
    end
  end

  def merged_ticket_target(_identifier, _opts), do: {:ok, "done"}

  # Classifies a known-valid open-PR listing into the ticket's post-merge
  # target. Extracted so the caller's case stays flat (Credo's nesting cap):
  # a non-blocking set means the merge closed the ticket's last live PR, while
  # a blocking set routes to rework when any of it carries unresolved findings
  # and to human-review when it merely awaits review.
  defp merged_ticket_target_for_open_pull_requests(pull_requests, opts) do
    case blocking_open_pull_requests(pull_requests, opts) do
      [] ->
        {:ok, "done"}

      blocking ->
        if Enum.any?(blocking, &open_pull_request_has_unresolved_findings?(&1, opts)) do
          {:ok, "rework"}
        else
          {:ok, if(Enum.all?(blocking, &(ReworkGate.post_agent_handoff_target(&1, "human-review", opts) == "ci-wait")), do: "ci-wait", else: "human-review")}
        end
    end
  end

  # The open PRs that still stand between the ticket and `done` after a merge.
  # A stale draft is treated as a superseded attempt and filtered out: a dead
  # draft left open forever must not pin its ticket out of `done` (the
  # mirror-image of the abandonment this reconciler prevents). Every other open
  # PR blocks, because its review findings or review state are still live work.
  # Missing or unparseable draft/staleness signals fail open to blocking — a
  # wrongly-ignored PR abandons work, while a wrongly-blocking one merely keeps
  # the ticket active and dispatchable.
  defp blocking_open_pull_requests(pull_requests, opts) do
    now = now_fun(opts).()
    Enum.reject(pull_requests, &stale_draft?(&1, now))
  end

  defp now_fun(opts), do: Keyword.get(opts, :now_fun, &DateTime.utc_now/0)

  defp stale_draft?(pull_request, now) do
    draft_pull_request?(pull_request) and stale_since?(pull_request, now)
  end

  defp draft_pull_request?(pull_request) when is_map(pull_request) do
    Map.get(pull_request, "draft") == true or Map.get(pull_request, :draft) == true
  end

  defp draft_pull_request?(_pull_request), do: false

  defp stale_since?(pull_request, now) do
    case updated_at(pull_request) do
      %DateTime{} = updated_at ->
        DateTime.diff(now, updated_at, :second) > @stale_draft_after_seconds

      _ ->
        false
    end
  end

  defp updated_at(pull_request) do
    case Map.get(pull_request, "updated_at") || Map.get(pull_request, :updated_at) do
      %DateTime{} = updated_at ->
        updated_at

      value when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, updated_at, _offset} -> updated_at
          _ -> nil
        end

      _ ->
        nil
    end
  end

  # Per-PR unresolved-findings predicate, injectable so callers can substitute
  # their own review-state source. The default routes on unresolved review
  # threads via `ReworkGate` — the single place that owns that rule (#2450) —
  # with the #1756 carve-out that an `APPROVED` verdict outranks a thread
  # nobody clicked "resolve" on, so an approved PR merely awaits review.
  defp open_pull_request_has_unresolved_findings?(pull_request, opts) do
    unresolved_findings_fun =
      Keyword.get(
        opts,
        :open_pull_request_unresolved_findings_fun,
        &default_open_pull_request_unresolved_findings?(&1, opts)
      )

    unresolved_findings_fun.(pull_request)
  end

  defp default_open_pull_request_unresolved_findings?(pull_request, opts)
       when is_map(pull_request) do
    case review_decision(pull_request) do
      # #1756: a reviewer's approval is a judgement on the whole change and
      # outranks a thread nobody resolved; the PR merely awaits review.
      "APPROVED" ->
        false

      _other ->
        # #2450: `reviewDecision` is sticky — a `CHANGES_REQUESTED` verdict never
        # clears when findings are addressed — so it is not a rework signal.
        # Unresolved review threads are: a PR whose threads are all resolved is
        # merely awaiting a fresh review and must not be routed to rework.
        case ReworkGate.open_pull_request_rework_verdict(pull_request, opts) do
          {:ok, :rework} ->
            true

          {:skip, :no_unresolved_review_threads} ->
            Logger.info(
              "merged-ticket reconcile: PR ##{pull_request_number(pull_request)} has zero unresolved review threads " <>
                "(#{inspect(:no_unresolved_review_threads)}); skipping rework (#2450)"
            )

            false

          # Fails open to "no unresolved findings": a transient thread lookup
          # must never fabricate a rework verdict. A wrongly-clear answer can at
          # worst route the ticket to `human-review`, whose entry gate re-checks
          # threads before letting the transition land, so it can never write
          # `done` over a finding.
          {:error, _reason} ->
            false
        end
    end
  end

  defp default_open_pull_request_unresolved_findings?(_pull_request, _opts), do: false

  defp review_decision(pull_request) do
    Map.get(pull_request, "review_decision") || Map.get(pull_request, :review_decision)
  end

  defp pull_request_number(%{"number" => number}) when is_integer(number), do: number
  defp pull_request_number(%{number: number}) when is_integer(number), do: number
  defp pull_request_number(_pull_request), do: nil
end
