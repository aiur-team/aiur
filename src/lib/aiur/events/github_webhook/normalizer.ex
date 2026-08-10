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

  alias Aiur.Events.{CommentFilter, GithubKeys}
  alias Aiur.TicketBranch

  @type triple :: {String.t(), map(), keyword()}
  @type result ::
          {:publish, [triple()]}
          | {:reconcile, map()}
          | {:drop, term()}
          | {:error, term()}

  @closing_keyword ~r/\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\s+#(\d+)\b/i

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

  defp tracked_repo(payload, opts) do
    tracked = Keyword.get(opts, :repo) || Aiur.Tracker.project_identity()
    delivered = get_in(payload, ["repository", "full_name"])

    cond do
      not is_binary(delivered) or delivered == "" ->
        {:error, :missing_repository}

      not is_binary(tracked) or tracked == "" ->
        {:drop, {:untracked_repository, delivered}}

      String.downcase(delivered) == String.downcase(tracked) ->
        {:ok, delivered}

      true ->
        {:drop, {:untracked_repository, delivered}}
    end
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
        issue_comment_triple(issue, comment, repo)
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
        review_submission_triple(payload, review, repo)
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
        review_comment_triple(payload, comment, repo)
    end
  end

  # ---------------------------------------------------------------------------
  # pull_request -> ticket.<id>.pr.opened / .pr.merged, or a CI reconcile
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
        ci_reconcile(pr, "pull_request", action)

      true ->
        pull_request_triple(payload, pr, action, repo)
    end
  end

  # ---------------------------------------------------------------------------
  # issues labeled / unlabeled / closed -> issue-state reconcile
  #
  # The polling path does not publish these through Publisher: IssueSync diffs
  # the observed label set and emits `ticket.<id>.issue.label.added.agent.<state>`
  # from that diff, and the same diff drives dispatch. GitHub does not order
  # deliveries, so an `unlabeled` can arrive before the `labeled` it followed —
  # another reason to treat the delivery as "state changed, go look" rather than
  # as an ordered instruction.
  # ---------------------------------------------------------------------------

  defp normalize_event("issues", payload, _repo) when is_map(payload) do
    action = Map.get(payload, "action")
    issue = Map.get(payload, "issue")

    cond do
      action not in ["labeled", "unlabeled", "closed", "reopened"] ->
        {:drop, {:uninteresting_action, "issues", action}}

      not is_map(issue) ->
        {:error, {:malformed_payload, "issues"}}

      true ->
        case ticket_identifier(Map.get(issue, "number")) do
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
        check_reconcile(subject, event_type)
    end
  end

  defp normalize_event(event_type, _payload, _repo), do: {:drop, {:unsupported_event, event_type}}

  # ---------------------------------------------------------------------------
  # Triple builders — these must stay byte-identical to their poller twins.
  # ---------------------------------------------------------------------------

  defp issue_comment_triple(issue, comment, repo) do
    pull_request? = is_map(Map.get(issue, "pull_request"))
    number = ticket_identifier(Map.get(issue, "number"))

    target =
      if pull_request?,
        do: ticket_from_pr_body(Map.get(issue, "body")),
        else: number

    cond do
      is_nil(number) ->
        {:error, {:malformed_payload, "issue_comment"}}

      is_nil(target) ->
        {:drop, {:unresolved_ticket, "issue_comment", number}}

      true ->
        {:publish,
         [
           comment_triple(
             "ticket.#{target}.issue.commented",
             target,
             comment,
             GithubKeys.comment_dedup_key(repo, "issue_comment", String.to_integer(number), Map.get(comment, "id")),
             if(pull_request?, do: review_context(Map.get(issue, "pull_request")))
           )
         ]}
    end
  end

  defp review_submission_triple(payload, review, repo) do
    with {:ok, target, pr_number} <- pull_request_identity(payload) do
      {:publish,
       [
         comment_triple(
           "ticket.#{target}.pr.review_comment",
           target,
           review,
           GithubKeys.pr_review_dedup_key(repo, pr_number, Map.get(review, "id")),
           review_context(Map.get(payload, "pull_request"))
         )
       ]}
    end
  end

  defp review_comment_triple(payload, comment, repo) do
    with {:ok, target, pr_number} <- pull_request_identity(payload) do
      {:publish,
       [
         comment_triple(
           "ticket.#{target}.pr.review_comment",
           target,
           comment,
           GithubKeys.comment_dedup_key(repo, "pr_review_comment", pr_number, Map.get(comment, "id")),
           payload |> Map.get("pull_request") |> review_context() |> approval_only_context()
         )
       ]}
    end
  end

  # GithubCommentsPoller.publish_comment/4: payload keyed by the ticket
  # identifier string, actor from the comment author, contamination bypassed so
  # an inbound human comment can reactivate a deactivated ticket.
  defp comment_triple(topic, target, comment, dedup_key, review_context) do
    actor = get_in(comment, ["user", "login"])

    payload =
      case review_context do
        %{} = context -> %{issue_number: target, comment: comment, pull_request: context}
        nil -> %{issue_number: target, comment: comment}
      end

    {topic, payload,
     [
       issue_number: target,
       dedup_key: dedup_key,
       actor: actor,
       bypass_contamination: true
     ]}
  end

  # Review-staleness context for the orchestrator's rework gate
  # (`Aiur.Orchestrator.ReviewFreshness`), mirroring
  # GithubCommentsPoller.review_context/1 key for key.
  #
  # A webhook delivery carries the REST pull request object, which exposes
  # neither `reviewDecision` nor the head commit date, so both read nil — the
  # same fail-open state the poller publishes on its REST fallback path, where
  # the gate stays inert and routing behaves as it did before the gate existed.
  # Reading through `Map.get/2` rather than hardcoding nil keeps the two
  # producers converging automatically if a delivery ever carries the fields.
  #
  # Failing open is also correct by construction here: a push delivery *is* the
  # review or comment that just happened, so there is no stale judgement for the
  # gate to suppress. See the PR discussion for the one residual divergence — a
  # PR-attached issue comment on an already-APPROVED pull request.
  defp review_context(pr) when is_map(pr) do
    %{
      "review_decision" => Map.get(pr, "review_decision"),
      "head_committed_at" => Map.get(pr, "head_committed_at")
    }
  end

  defp review_context(_pr), do: review_context(%{})

  # An inline review thread stays actionable across pushes that did not touch
  # it, so thread comments carry only the approval half — matching
  # GithubCommentsPoller.approval_only_context/1.
  defp approval_only_context(context), do: Map.delete(context, "head_committed_at")

  defp pull_request_triple(payload, pr, action, repo) do
    merged? = merged_pull_request?(action, Map.get(pr, "merged"))
    actor = get_in(payload, ["sender", "login"])
    pr_number = Map.get(pr, "number")
    head_sha = get_in(pr, ["head", "sha"]) || ""

    with {:ok, target, _pr_number} <- pull_request_identity(payload),
         topic when is_binary(topic) <- pr_topic(target, action, merged?) do
      publish_opts = [
        actor: actor,
        issue_number: target,
        bypass_contamination: merged?,
        dedup_key: GithubKeys.pr_dedup_key(repo, pr_number, action, head_sha)
      ]

      {:publish, [{topic, %{action: action, pr: pr, timestamp: pull_request_timestamp(pr)}, publish_opts}]}
    else
      {:drop, _reason} = drop -> drop
      {:error, _reason} = error -> error
      nil -> {:drop, {:uninteresting_action, "pull_request", action}}
    end
  end

  defp pr_topic(target, "opened", _merged), do: "ticket.#{target}.pr.opened"
  defp pr_topic(target, _action, true), do: "ticket.#{target}.pr.merged"
  defp pr_topic(_target, _action, _merged), do: nil

  defp merged_pull_request?("closed", true), do: true
  defp merged_pull_request?("merged", _merged), do: true
  defp merged_pull_request?(_action, _merged), do: false

  # GithubFirehose stamps the Events API envelope's `created_at` — the moment
  # the event happened. A webhook body has no envelope, so the pull request's
  # own last-modified timestamp is the equivalent statement of when this
  # transition occurred.
  defp pull_request_timestamp(pr), do: Map.get(pr, "updated_at") || Map.get(pr, "created_at")

  # ---------------------------------------------------------------------------
  # Reconcile hints
  # ---------------------------------------------------------------------------

  defp ci_reconcile(pr, event_type, action) do
    case ticket_from_head_ref(pr) do
      nil ->
        {:drop, {:unresolved_ticket, event_type, action}}

      ticket ->
        {:reconcile,
         %{
           kind: :ci,
           ticket: ticket,
           head_sha: get_in(pr, ["head", "sha"]),
           source: event_type,
           action: action
         }}
    end
  end

  defp check_reconcile(subject, event_type) do
    pull_requests = Map.get(subject, "pull_requests") || []

    tickets =
      pull_requests
      |> Enum.filter(&is_map/1)
      |> Enum.map(&ticket_from_head_ref/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    case tickets do
      [] ->
        {:drop, {:unresolved_ticket, event_type, "completed"}}

      tickets ->
        {:reconcile,
         %{
           kind: :ci,
           tickets: tickets,
           head_sha: Map.get(subject, "head_sha"),
           conclusion: Map.get(subject, "conclusion"),
           source: event_type,
           action: "completed"
         }}
    end
  end

  # ---------------------------------------------------------------------------
  # Identity helpers
  # ---------------------------------------------------------------------------

  defp pull_request_identity(payload) do
    pr = Map.get(payload, "pull_request")
    pr_number = if is_map(pr), do: Map.get(pr, "number")

    if is_map(pr) and is_integer(pr_number) do
      case ticket_from_head_ref(pr) do
        nil -> {:drop, {:unresolved_ticket, "pull_request", pr_number}}
        ticket -> {:ok, ticket, pr_number}
      end
    else
      {:error, {:malformed_payload, "pull_request"}}
    end
  end

  defp ticket_from_head_ref(pr) do
    case get_in(pr, ["head", "ref"]) do
      ref when is_binary(ref) -> TicketBranch.ticket_id_from_ref("refs/heads/" <> ref)
      _other -> nil
    end
  end

  # An `issue_comment` delivery on a pull request carries the PR body as
  # `issue.body` but no head ref. Every Aiur PR description opens with a
  # closing keyword, so that keyword is the ticket mapping for this one case.
  defp ticket_from_pr_body(body) when is_binary(body) do
    case Regex.run(@closing_keyword, body) do
      [_match, number] -> number
      _other -> nil
    end
  end

  defp ticket_from_pr_body(_body), do: nil

  defp ticket_identifier(number) when is_integer(number) and number > 0, do: Integer.to_string(number)

  defp ticket_identifier(number) when is_binary(number) do
    case Integer.parse(number) do
      {parsed, ""} when parsed > 0 -> Integer.to_string(parsed)
      _other -> nil
    end
  end

  defp ticket_identifier(_number), do: nil

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
