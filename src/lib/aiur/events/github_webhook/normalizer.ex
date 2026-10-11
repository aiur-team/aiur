defmodule Aiur.Events.GithubWebhook.Normalizer do
  @moduledoc """
  Turns a verified GitHub webhook delivery into the *same* publish the
  polling path would have produced for the same underlying GitHub event.

  ## One shape, two producers

  `Aiur.Events.GithubCommentsPoller` and `Aiur.Events.GithubFirehose` already
  publish the topics the fleet subscribes to (see
  `Aiur.Orchestrator.AutoSubscriptions`). Webhooks are a second *producer* for
  those same topics, never a second *shape*. This module therefore returns the
  exact `{topic, payload, publish_opts}` triple the corresponding poller builds,
  and `Aiur.Events.GithubWebhook` runs it through the same
  `Sanitizer.github_payload/2` + `Publisher.publish/3` tail. A consumer cannot
  tell which producer woke it.

  The dedup keys are the poller's keys on purpose: when both producers observe
  the same GitHub event, `Publisher`'s replay dedup collapses them into one
  wake rather than two.

  ## Publish vs reconcile

  Not every event the fleet reacts to is published directly by a poller. Label
  transitions and CI outcomes are emitted by *stateful* reconcilers
  (`Aiur.Orchestrator.IssueSync` diffs the observed label set;
  `Aiur.Orchestrator.CILifecycle` owns approved/failed head tracking). Handing
  those deliveries straight to `Publisher` would invent an event shape no poller
  produces — exactly the drift this ticket exists to prevent. They normalize to
  `{:reconcile, hint}` instead: the delivery becomes a *nudge* to run the
  existing reconciler now, so the existing producer still emits the event.

  ## Ticket identity

  Every delivery must resolve to the ticket identifier the fleet keys on:

    * `pull_request`, `pull_request_review`, `pull_request_review_comment` carry
      `pull_request.head.ref`, which maps through `Aiur.TicketBranch`. This is
      the same mapping the firehose uses.
    * `issue_comment` on a plain issue uses the issue number directly.
    * `issue_comment` on a pull request carries no head ref, so the ticket is
      read from the PR body's `Closes #N` keyword (every Aiur PR description
      opens with one). When that is absent the delivery is dropped and the
      comments poller remains the path for it.

  Deliveries for repositories the fleet does not track are dropped before any
  of the above runs.
  """

  alias Aiur.Events.CommentFilter
  alias Aiur.Events.GithubWebhook.{Identity, ReconcileHints, Triples}

  @type triple :: Triples.triple()
  @type result ::
          {:publish, [triple()]}
          | {:reconcile, map()}
          | {:drop, term()}
          | {:error, term()}

  @doc """
  Normalizes one delivery.

  `event_type` is the `X-GitHub-Event` header value; `payload` is the decoded
  JSON body.

  Returns:

    * `{:publish, triples}` — one or more ready-to-publish
      `{topic, payload, publish_opts}` triples, identical to the poller's.
    * `{:reconcile, hint}` — the delivery is a statement of current state whose
      event is owned by a stateful reconciler; run that reconciler.
    * `{:drop, reason}` — deliberately not published (untracked repo,
      uninteresting action, unresolvable ticket, unsupported event type).
    * `{:error, reason}` — the payload is malformed or partial.

  Options:

    * `:repo` — `"owner/repo"` the fleet tracks; defaults to
      `Aiur.Tracker.project_identity/0`.
  """
  @spec normalize(term(), term(), keyword()) :: result()
  def normalize(event_type, payload, opts \\ [])

  def normalize(event_type, payload, opts) when is_binary(event_type) and is_map(payload) do
    with {:ok, repo} <- tracked_repo(payload, opts) do
      normalize_event(event_type, payload, repo)
    end
  rescue
    error -> {:error, {:normalizer_exception, Exception.message(error)}}
  end

  def normalize(event_type, _payload, _opts) when is_binary(event_type),
    do: {:error, {:malformed_payload, event_type}}

  def normalize(event_type, _payload, _opts), do: {:drop, {:unsupported_event, event_type}}

  # ---------------------------------------------------------------------------
  # Tracked-repo filter
  # ---------------------------------------------------------------------------

  @doc """
  Resolves the delivery to the repository the fleet tracks.

  Public because the publish tail needs the same answer this module's own filter
  reaches: a delivery only counts as proof that webhooks work for a repo the
  fleet actually tracks, and that judgement must not be made twice by two
  slightly different rules.

  Takes the same `:repo` option as `normalize/3`.
  """
  @spec tracked_repo(term(), keyword()) ::
          {:ok, String.t()} | {:drop, {:untracked_repository, String.t()}} | {:error, term()}
  def tracked_repo(payload, opts \\ [])

  def tracked_repo(payload, opts) when is_map(payload) do
    tracked = Keyword.get(opts, :repo) || Aiur.Tracker.project_identity()
    candidates = delivery_repos(payload)

    cond do
      candidates == [] ->
        {:error, :missing_repository}

      not is_binary(tracked) or tracked == "" ->
        {:drop, {:untracked_repository, hd(candidates)}}

      true ->
        case Enum.find(candidates, &(String.downcase(&1) == String.downcase(tracked))) do
          nil -> {:drop, {:untracked_repository, hd(candidates)}}
          repo -> {:ok, repo}
        end
    end
  end

  def tracked_repo(_payload, _opts), do: {:error, :missing_repository}

  # The repositories a delivery names, most specific first. Every other event
  # type carries the whole object's repo as `repository.full_name`; the two
  # graph-edge events carry their repos as `*_repo` fields instead, because
  # neither `sub_issues` nor `issue_dependencies` wraps a `repository` object.
  # Resolving both lets a delivery count as tracked — and therefore get
  # deposited and recorded — when either endpoint of the edge is in the repo
  # the fleet tracks (#2313).
  defp delivery_repos(payload) do
    [
      get_in(payload, ["repository", "full_name"]),
      Map.get(payload, "parent_issue_repo"),
      Map.get(payload, "sub_issue_repo"),
      Map.get(payload, "blocked_issue_repo"),
      Map.get(payload, "blocking_issue_repo")
    ]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
  end

  # ---------------------------------------------------------------------------
  # issue_comment -> ticket.<id>.issue.commented
  #
  # Mirrors GithubCommentsPoller.publish_issue_comment/3 and
  # publish_pr_issue_comment/4, including the Agent Workpad filter.
  # ---------------------------------------------------------------------------

  defp normalize_event("issue_comment", payload, repo) when is_map(payload) do
    action = Map.get(payload, "action")
    comment = Map.get(payload, "comment")
    issue = Map.get(payload, "issue")

    cond do
      action not in ["created", "edited"] ->
        {:drop, {:uninteresting_action, "issue_comment", action}}

      not is_map(comment) or not is_map(issue) ->
        {:error, {:malformed_payload, "issue_comment"}}

      CommentFilter.agent_workpad?(comment) ->
        {:drop, :agent_workpad_comment}

      true ->
        Triples.issue_comment_triple(issue, comment, repo)
    end
  end

  # ---------------------------------------------------------------------------
  # pull_request_review submitted -> ticket.<id>.pr.review_comment
  #
  # Mirrors GithubCommentsPoller.publish_pr_review_submission/4, including the
  # actionable-review filter that keeps empty COMMENTED containers from waking
  # an agent twice for inline comments already published as review comments.
  # ---------------------------------------------------------------------------

  defp normalize_event("pull_request_review", payload, repo) when is_map(payload) do
    action = Map.get(payload, "action")
    review = Map.get(payload, "review")

    cond do
      action != "submitted" ->
        {:drop, {:uninteresting_action, "pull_request_review", action}}

      not is_map(review) ->
        {:error, {:malformed_payload, "pull_request_review"}}

      not actionable_review?(review) ->
        {:drop, {:non_actionable_review, Map.get(review, "state")}}

      true ->
        Triples.review_submission_triple(payload, review, repo)
    end
  end

  # ---------------------------------------------------------------------------
  # pull_request_review_comment -> ticket.<id>.pr.review_comment
  #
  # Mirrors GithubCommentsPoller.publish_pr_review_comment/4.
  # ---------------------------------------------------------------------------

  defp normalize_event("pull_request_review_comment", payload, repo) when is_map(payload) do
    action = Map.get(payload, "action")
    comment = Map.get(payload, "comment")

    cond do
      action not in ["created", "edited"] ->
        {:drop, {:uninteresting_action, "pull_request_review_comment", action}}

      not is_map(comment) ->
        {:error, {:malformed_payload, "pull_request_review_comment"}}

      true ->
        Triples.review_comment_triple(payload, comment, repo)
    end
  end

  # ---------------------------------------------------------------------------
  # pull_request_review_thread resolved / unresolved -> targeted comment reconcile
  #
  # GitHub changes thread resolution without creating a review comment. The
  # unresolved-thread poller owns publication, so the delivery names the exact
  # ticket that poller should reconcile rather than inventing another event.
  # ---------------------------------------------------------------------------

  defp normalize_event("pull_request_review_thread", payload, repo) when is_map(payload) do
    action = Map.get(payload, "action")
    thread = Map.get(payload, "thread")

    cond do
      action not in ["resolved", "unresolved"] ->
        {:drop, {:uninteresting_action, "pull_request_review_thread", action}}

      not is_map(thread) or not is_map(Map.get(payload, "pull_request")) ->
        {:error, {:malformed_payload, "pull_request_review_thread"}}

      true ->
        ReconcileHints.review_thread_reconcile(payload, thread, action, repo)
    end
  end

  # ---------------------------------------------------------------------------
  # pull_request -> ticket.<id>.pr.opened / .pr.ready_for_review / .pr.merged, or a CI reconcile
  #
  # Mirrors GithubFirehose.translate/2 for the PullRequestEvent case. A
  # `synchronize` push invalidates review state, which CILifecycle owns, so it
  # reconciles rather than publishing.
  # ---------------------------------------------------------------------------

  defp normalize_event("pull_request", payload, repo) when is_map(payload) do
    action = Map.get(payload, "action")
    pr = Map.get(payload, "pull_request")

    cond do
      not is_map(pr) ->
        {:error, {:malformed_payload, "pull_request"}}

      action == "synchronize" ->
        ReconcileHints.ci_reconcile(pr, "pull_request", action)

      true ->
        Triples.pull_request_triple(payload, pr, action, repo)
    end
  end

  # ---------------------------------------------------------------------------
  # issues labeled / unlabeled / closed / reopened / opened -> issue-state
  # reconcile
  #
  # The polling path does not publish these through Publisher: IssueSync diffs
  # the observed label set and emits `ticket.<id>.issue.label.added.agent.<state>`
  # from that diff, and the same diff drives dispatch. GitHub does not order
  # deliveries, so an `unlabeled` can arrive before the `labeled` it followed —
  # another reason to treat the delivery as "state changed, go look" rather than
  # as an ordered instruction. A freshly `opened` ticket reconciles the same way
  # so a new issue that already carries an active state label does not wait out
  # the poll interval (#2365); whether the opened issue implies work is decided
  # by the delivery tail, not here, so this module stays pure.
  # ---------------------------------------------------------------------------

  defp normalize_event("issues", payload, _repo) when is_map(payload) do
    action = Map.get(payload, "action")
    issue = Map.get(payload, "issue")

    cond do
      action not in ["labeled", "unlabeled", "closed", "reopened", "opened"] ->
        {:drop, {:uninteresting_action, "issues", action}}

      not is_map(issue) ->
        {:error, {:malformed_payload, "issues"}}

      true ->
        case Identity.ticket_identifier(Map.get(issue, "number")) do
          nil ->
            {:error, {:malformed_payload, "issues"}}

          ticket ->
            {:reconcile,
             %{
               kind: :issue_state,
               ticket: ticket,
               action: action,
               occurred_at: Map.get(issue, "updated_at")
             }}
        end
    end
  end

  # ---------------------------------------------------------------------------
  # sub_issues / issue_dependencies -> graph mutation, deposited not published
  #
  # These two event types mutate the Build Order graph — membership and
  # dependency edges — and neither has a fleet event the polling path produces
  # (`Aiur.Events.GithubWebhook.Deposit` is the only consumer that matters, and
  # it runs before this clause, in `record_tracked_delivery/3`). Publishing a
  # shape here would invent an event no poller emits, and reconciling through
  # the orchestrator would be wrong: the graph projection is woken by the
  # store's own `ResourceEvents`, not by a poll cycle. So the delivery is
  # dropped as a publish candidate with the reason naming what it was, and the
  # store already holds the edge (#2313).
  # ---------------------------------------------------------------------------

  defp normalize_event(event_type, payload, _repo)
       when event_type in ["sub_issues", "issue_dependencies"] and is_map(payload) do
    {:drop, {:graph_event, event_type, Map.get(payload, "action")}}
  end

  # ---------------------------------------------------------------------------
  # check_suite / check_run completed -> CI reconcile
  #
  # CI terminal events (`ticket.<id>.ci.passed` / `.ci.failed`) are published by
  # Orchestrator.CILifecycle from aggregated check state plus its own
  # approved/failed head bookkeeping. A single completed check cannot be turned
  # into that event without inventing a shape the poller never emits.
  # ---------------------------------------------------------------------------

  defp normalize_event(event_type, payload, _repo) when event_type in ["check_suite", "check_run"] and is_map(payload) do
    action = Map.get(payload, "action")
    subject = Map.get(payload, event_type)

    cond do
      action != "completed" ->
        {:drop, {:uninteresting_action, event_type, action}}

      not is_map(subject) ->
        {:error, {:malformed_payload, event_type}}

      true ->
        ReconcileHints.check_reconcile(subject, event_type)
    end
  end

  defp normalize_event(event_type, _payload, _repo), do: {:drop, {:unsupported_event, event_type}}

  # Same rule as GithubCommentsPoller.actionable_review?/1.
  defp actionable_review?(%{"state" => state} = review) when is_binary(state) do
    case String.upcase(state) do
      "CHANGES_REQUESTED" -> true
      "COMMENTED" -> is_binary(Map.get(review, "body")) and Map.get(review, "body") != ""
      _other -> false
    end
  end

  defp actionable_review?(_review), do: false
end
