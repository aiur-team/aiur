defmodule Aiur.Orchestrator.ReworkGate do
  @moduledoc """
  The preconditions every `agent:rework` transition must satisfy.

  `rework` means "work exists and was rejected" — a reviewer (or CI) rejected
  existing work. A ticket with no open pull request has nothing a reviewer
  could have rejected, so stamping it `rework` asserts a verdict that never
  happened: the agent wastes a dispatch discovering there is nothing to rework
  (#1844), and the flip can transiently leave the ticket carrying two state
  labels, silently undispatchable (#2075).

  Since #2422 / #2450 the gate also decides *whether a reviewer is currently
  asking for a change*: routing on unresolved review threads, not on GitHub's
  sticky `reviewDecision`. A `CHANGES_REQUESTED` verdict never clears when
  findings are addressed, so it cannot distinguish "outstanding findings" from
  "was once told to change something" — routing rework on it re-enters
  `agent:rework` forever. Both rework writers route through this module's
  unresolved-thread check: the comment-wake path (#2422) via
  `verify_unresolved_review_threads/2` and the merged-ticket reconciler (#2450)
  via `open_pull_request_rework_verdict/2`, so the rule lives in exactly one
  place. This module is the single place that verifies these preconditions.
  Each rework writer calls it before writing `rework`, and each names the
  precondition in a test so a future writer cannot be added without stating
  one.
  """

  alias Aiur.Alerts
  alias Aiur.GitHub.Client, as: GitHubClient
  alias Aiur.GitHub.ReviewThreads
  alias Aiur.GitHub.Tracker, as: GitHubTracker
  alias Aiur.Orchestrator.State
  alias Aiur.Tracker

  @doc """
  Returns the open pull request for the rework target.

  Returns:
    * `{:ok, pr}` — an open PR exists;
    * `{:skip, :no_open_pr}` — the ticket has no open PR; rework must be
      refused at the source;
    * `{:error, reason}` — the PR lookup itself failed transiently; callers
      decide whether to retry or park.
  """
  @spec open_pr(String.t() | integer(), keyword()) ::
          {:ok, map()} | {:skip, :no_open_pr} | {:error, term()}
  def open_pr(issue_key, opts \\ []) do
    fetcher = Keyword.get(opts, :open_pr_fetcher, &default_fetcher/1)

    case fetcher.(to_string(issue_key)) do
      {:ok, %{} = pr} -> {:ok, pr}
      {:ok, _no_open_pr} -> {:skip, :no_open_pr}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Verifies that the rework target still has an open pull request.

  Returns:
    * `:ok` — an open PR exists, so a rework verdict is meaningful;
    * `{:skip, :no_open_pr}` — the ticket has no open PR; rework must be
      refused at the source;
    * `{:error, reason}` — the PR lookup itself failed transiently; callers
      decide whether to retry or park.
  """
  @spec verify_open_pr(String.t() | integer(), keyword()) ::
          :ok | {:skip, :no_open_pr} | {:error, term()}
  def verify_open_pr(issue_key, opts \\ []) do
    case open_pr(issue_key, opts) do
      {:ok, %{} = _pr} -> :ok
      {:skip, reason} -> {:skip, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Decides whether an open pull request is currently a rework target.

  `rework` means "a reviewer is currently asking for a change", and the only
  signal that reliably answers that is unresolved review threads: GitHub's
  `reviewDecision` is sticky by design — a `CHANGES_REQUESTED` verdict never
  clears when findings are addressed — so it cannot distinguish "outstanding
  findings" from "was once told to change something" (#2422, #2450). A pull
  request whose review threads are all resolved (or that has none) is not a
  rework target, whatever its verdict says.

  This is the per-PR form of the rule, for callers that already hold the
  open-PR listing (e.g. `MergedTicketReconciler`). It shares the same default
  thread read as `verify_unresolved_review_threads/2` — the rule lives here,
  not in a second copy — and the read is injectable via
  `:unresolved_threads_fetcher` for tests.

  Returns:
    * `{:ok, :rework}` — the PR has unresolved review threads, so routing it to
      rework is justified;
    * `{:skip, :no_unresolved_review_threads}` — the PR's threads are all
      resolved (or it has none); the reviewer is not currently asking for a
      change, so rework must be refused;
    * `{:error, reason}` — the thread read failed transiently; callers decide
      whether to retry or park.
  """
  @spec open_pull_request_rework_verdict(map(), keyword()) ::
          {:ok, :rework} | {:skip, :no_unresolved_review_threads} | {:error, term()}
  def open_pull_request_rework_verdict(pull_request, opts \\ []) do
    threads_fetcher = Keyword.get(opts, :unresolved_threads_fetcher, &default_threads_fetcher/1)

    case pull_request do
      %{} ->
        case threads_fetcher.(pull_request) do
          {:ok, comments} when is_list(comments) and comments != [] -> {:ok, :rework}
          {:ok, _no_unresolved_threads} -> no_thread_verdict(opts)
          {:error, reason} -> {:error, reason}
        end

      # A PR that is not a map has nothing a reviewer could have rejected.
      _non_map ->
        {:skip, :no_unresolved_review_threads}
    end
  end

  # A `CHANGES_REQUESTED` review submitted with a body and no inline comments
  # opens no review thread at all, so the thread read below reports zero
  # unresolved threads and #2422's rule alone refuses a verdict a reviewer very
  # much did make (#2473). Where the caller is routing *that review submission*
  # itself, the submission is the outstanding finding, and this does not reopen
  # the #2422 loop.
  #
  # What keeps it closed is that a review submission is delivered ONCE, not
  # re-derived every cycle the way `reviewDecision` was. Read the guard in the
  # publisher, not here:
  #
  #   * `Aiur.Events.Publisher` consults `resource_processed?/1` BEFORE its
  #     volatile dedup window. A review publishes as
  #     `{:pr_review, owner, repo, review_id}` at `resource_version =
  #     submitted_at`, which is immutable for a review, and `ResourceStore`
  #     keeps that identity for 72h across daemon restarts — sized to GitHub's
  #     redelivery ceiling. A redelivered or duplicated `pull_request_review`
  #     is dropped at publish and never reaches this gate.
  #   * The poller's `poll_pr_review_submissions/6` applies the
  #     `pr_review_seen_at` / `current_target_since` / boot cutoff, and
  #     `review_submission_enabled?/2` only reads `/reviews` for tickets still
  #     in `human-review` — so a ticket already moved to `agent:rework` is not
  #     re-polled into rework again.
  #   * `verify_rework_attempt/4`'s head-SHA bound applies on top of both.
  #
  # Do NOT justify this by `ReviewFreshness`. Its staleness half needs
  # `pull_request.head_committed_at`, which only the poller's GraphQL batch
  # populates; `Normalizer.review_context/1` reads it off the REST pull request
  # object, which never carries it, so that half is structurally inert on every
  # webhook delivery. The single-delivery identity gate above is the guard, and
  # it is the one a refactor must not delete.
  #
  # The option defaults to `false`, so every caller that is *not* holding a live
  # changes-requested review keeps the pre-#2473 behaviour exactly.
  defp no_thread_verdict(opts) do
    if Keyword.get(opts, :changes_requested_review?, false) do
      {:ok, :rework}
    else
      {:skip, :no_unresolved_review_threads}
    end
  end

  @doc """
  Verifies that the rework target has an open pull request with at least one
  unresolved review thread.

  `rework` means "a reviewer asked for a change", and the only signal that
  reliably answers that question is the per-thread `isResolved` state: GitHub
  never clears `reviewDecision` when findings are addressed, so a
  `CHANGES_REQUESTED` verdict cannot distinguish "outstanding findings" from
  "was once told to change something" (#2422). A pull request whose review
  threads are all resolved (or that has none) is not a rework target, whatever
  its verdict says.

  This is the ticket-key form of the rule, for callers that hold only the issue
  key (e.g. `CommentWake`). It shares the same default thread read as
  `open_pull_request_rework_verdict/2` — the rule lives here, not in a second
  copy — and the read is injectable via `:unresolved_threads_fetcher` for
  tests.

  Returns:
    * `{:ok, pr}` — an open PR exists with unresolved review threads, so
      rework is justified; the PR is returned so the caller can also read its
      head SHA for the rework-attempt bound;
    * `{:skip, :no_open_pr}` — the ticket has no open PR; rework refused;
    * `{:skip, :no_unresolved_review_threads}` — the open PR has no unresolved
      threads; the reviewer is not currently asking for a change, so the ticket
      must not be routed to rework;
    * `{:error, reason}` — the PR or thread lookup failed transiently; callers
      decide whether to retry or park.

  Pass `changes_requested_review?: true` when the caller is routing a live
  `CHANGES_REQUESTED` review submission. A body-only review opens no review
  thread, so the thread read cannot see it (#2473); the submission is itself
  the outstanding finding and stands in for an unresolved thread.
  """
  @spec verify_unresolved_review_threads(String.t() | integer(), keyword()) ::
          {:ok, map()}
          | {:skip, :no_open_pr | :no_unresolved_review_threads}
          | {:error, term()}
  def verify_unresolved_review_threads(issue_key, opts \\ []) do
    case open_pr(issue_key, opts) do
      {:ok, %{} = pr} ->
        case open_pull_request_rework_verdict(pr, opts) do
          {:ok, :rework} -> {:ok, pr}
          {:skip, reason} -> {:skip, reason}
          {:error, reason} -> {:error, reason}
        end

      {:skip, reason} ->
        {:skip, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Applies the rework-attempt bound for a single head SHA.

  Whatever the routing signal, the same head must not re-enter `agent:rework`
  indefinitely: if rework completes and the gating signal has not moved, that
  is a *stuck* condition, not a review finding. The bound turns an unbounded
  slot leak into a single attention (#2422). A new head SHA starts a fresh
  count, so a genuine rework push is never affected.

  Returns:
    * `{:ok, state}` — the bound is not exhausted for `{issue_id, head_sha}`;
      the rework write may proceed;
    * `{:skip, :rework_attempt_limit_reached, state}` — the same head has been
      routed to rework `State.rework_attempt_limit/0` times already; a one-time
      attention has been raised and the rework write must be refused.
  """
  @spec verify_rework_attempt(State.t(), String.t(), String.t() | nil, keyword()) ::
          {:ok, State.t()} | {:skip, :rework_attempt_limit_reached, State.t()}
  def verify_rework_attempt(%State{} = state, issue_id, head_sha, opts \\ [])
      when is_binary(issue_id) do
    if State.rework_attempt_limit_reached?(state, issue_id, head_sha) do
      {:skip, :rework_attempt_limit_reached, raise_rework_attempt_attention(state, issue_id, head_sha, opts)}
    else
      {:ok, state}
    end
  end

  @doc false
  # The head commit SHA of the open PR, used to key the rework-attempt bound so
  # a head that never moves cannot be routed to rework forever (#2422).
  @spec head_sha(map()) :: String.t() | nil
  def head_sha(%{} = pr) do
    case get_in(pr, ["head", "sha"]) do
      sha when is_binary(sha) and sha != "" -> sha
      _other -> nil
    end
  end

  def head_sha(_pr), do: nil

  @doc false
  # The thread gate only applies where a live review-thread read is meaningful:
  # the GitHub tracker behind a client that can answer
  # `fetch_open_pull_request_for_branch/1`. Non-GitHub trackers and stub/fake
  # clients (which predate this gate) fail open — they have no notion of a PR
  # or review threads, so the rework writers keep their legacy behaviour there,
  # and the precondition is still pinned by the dedicated tests.
  @spec available?() :: boolean()
  def available? do
    Tracker.adapter() == GitHubTracker and
      github_client_exported?()
  end

  defp default_fetcher(issue_key) do
    if available?() do
      Tracker.fetch_open_pull_request_for_branch(issue_key)
    else
      {:ok, %{}}
    end
  end

  # Fails open whenever the unresolved-thread question cannot be answered: a
  # non-GitHub tracker, a stub client, or a PR without a number means we cannot
  # prove the threads are clear, so rework keeps its pre-#2422 behaviour rather
  # than silently stranding a ticket whose findings can no longer be checked.
  defp default_threads_fetcher(%{} = pr) do
    with true <- available?(),
         number when is_integer(number) <- Map.get(pr, "number") do
      ReviewThreads.fetch_unaddressed_pr_review_thread_comments(number)
    else
      _unavailable -> {:ok, [:unresolved]}
    end
  end

  defp raise_rework_attempt_attention(%State{} = state, issue_id, head_sha, opts) do
    if is_binary(head_sha) and not State.rework_attempt_alerted?(state, issue_id, head_sha) do
      emit_alert_fun = Keyword.get(opts, :emit_alert_fun, &Alerts.emit_system/2)
      limit = State.rework_attempt_limit()

      emit_alert_fun.(
        "ticket.#{issue_id}.agent.attention.rework_attempt_limit",
        issue: issue_id,
        message: "Ticket #{issue_id} has been routed to rework #{limit} times for head #{String.slice(head_sha, 0, 7)} without the head moving; the rework routing has stopped.",
        reason:
          "A rework turn keeps being routed for the same head SHA more than #{limit} times, so there is nothing new for the rework turn to address (#2422). " <>
            "The rework routing is stopped rather than looping; release this ticket by re-reviewing the PR, dismissing the stale review verdict, or pushing a real head change.",
        needs_attention: true,
        severity: "warning",
        central: true
      )

      State.mark_rework_attempt_alerted(state, issue_id, head_sha)
    else
      state
    end
  end

  defp github_client_exported? do
    client = Application.get_env(:aiur, :github_client_module, GitHubClient)

    Code.ensure_loaded?(client) and
      function_exported?(client, :fetch_open_pull_request_for_branch, 1)
  end
end
