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
  alias Aiur.GitHub.ResourceStore
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
  # pull_request_review_thread resolved -> reconciliation only
  # ---------------------------------------------------------------------------

  defp normalize_event("pull_request_review_thread", payload, _repo) when is_map(payload) do
    action = Map.get(payload, "action")
    thread = Map.get(payload, "thread")

    cond do
      action != "resolved" ->
        {:drop, {:uninteresting_action, "pull_request_review_thread", action}}

      not is_map(thread) ->
        {:error, {:malformed_payload, "pull_request_review_thread"}}

      true ->
        with {:ok, target, pr_number} <- pull_request_identity(payload) do
          {:reconcile,
           %{
             kind: :review_threads,
             ticket: target,
             pull_request: pr_number,
             source: "pull_request_review_thread"
           }}
        end
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
             poller_comment_shape(comment),
             GithubKeys.comment_dedup_key(repo, "issue_comment", String.to_integer(number), Map.get(comment, "id")),
             if(pull_request?, do: review_context(Map.get(issue, "pull_request"))),
             ResourceStore.key_for_repo(:issue_comment, repo, Map.get(comment, "id"))
           )
         ]}
    end
  end

  # Deliberately NOT projected through `poller_comment_shape/1`. Review
  # submissions are the one comment topic the poller does not normalize: it
  # fetches `/pulls/N/reviews` over REST and publishes the review object as-is,
  # so the delivery's own REST review is already the matching shape. Projecting
  # here would drop `state` and `submitted_at`, which decide CHANGES_REQUESTED
  # routing and `ReviewFreshness` staleness respectively.
  defp review_submission_triple(payload, review, repo) do
    with {:ok, target, pr_number} <- pull_request_identity(payload) do
      {:publish,
       [
         comment_triple(
           "ticket.#{target}.pr.review_comment",
           target,
           upcase_review_state(review),
           GithubKeys.pr_review_dedup_key(repo, pr_number, Map.get(review, "id")),
           review_context(Map.get(payload, "pull_request")),
           ResourceStore.key_for_repo(:pr_review, repo, Map.get(review, "id"))
         )
       ]}
    end
  end

  # One granularity, both pipes. `GithubCommentsPoller` keys review thread
  # comments on the GraphQL thread node id, and the delivery path resolves that
  # id for webhook deliveries (`Aiur.Events.GithubWebhook.ThreadResolver`), so
  # the two pipes derive the same key for the same event and `Publisher`
  # collapses them into one wake.
  #
  # Thread is the deliberate granularity (see #2081). A review thread is
  # GitHub's own unit of feedback — one finding plus its replies — and keying
  # per comment would multiply wakes for a multi-comment review, which is a real
  # cost, not neutral correctness. The tradeoff: a follow-up comment on an
  # already-woken thread within the replay window does not wake a second time.
  #
  # A delivery whose thread could not be resolved (no `node_id`, or a failed
  # lookup) keys per comment — the fail-open degradation, unchanged from before
  # this change. A duplicate wake is recoverable; a dropped delivery is not.
  defp review_comment_triple(payload, comment, repo) do
    with {:ok, target, pr_number} <- pull_request_identity(payload) do
      {dedup_key, resource} = review_comment_keys(repo, pr_number, comment)

      {:publish,
       [
         comment_triple(
           "ticket.#{target}.pr.review_comment",
           target,
           poller_comment_shape(comment),
           dedup_key,
           payload |> Map.get("pull_request") |> review_context() |> approval_only_context(),
           resource
         )
       ]}
    end
  end

  defp review_comment_keys(repo, pr_number, %{"review_thread_id" => thread_id})
       when is_binary(thread_id) and thread_id != "" do
    {GithubKeys.review_thread_dedup_key(repo, pr_number, thread_id), ResourceStore.key_for_repo(:pr_review_thread, repo, thread_id)}
  end

  defp review_comment_keys(repo, pr_number, comment) when is_map(comment) do
    {GithubKeys.comment_dedup_key(repo, "pr_review_comment", pr_number, Map.get(comment, "id")), ResourceStore.key_for_repo(:pr_review_comment, repo, Map.get(comment, "id"))}
  end

  # GithubCommentsPoller.publish_comment/4: payload keyed by the ticket
  # identifier string, actor from the comment author, contamination bypassed so
  # an inbound human comment can reactivate a deactivated ticket.
  defp comment_triple(topic, target, comment, dedup_key, review_context, resource) do
    actor = get_in(comment, ["user", "login"])

    payload =
      case review_context do
        %{} = context -> %{issue_number: target, comment: comment, pull_request: context}
        nil -> %{issue_number: target, comment: comment}
      end

    # `:resource` names the GitHub object this delivery *is*, so the poll sweep
    # that later re-reads the same object recognises it as already handled. It
    # is the free pipe's contribution to the expensive one: a delivery costs
    # nothing and arrives first, so it is the right writer of that fact.
    #
    # `:resource_version` is what keeps that from over-reaching. This module
    # normalizes `edited` deliveries as well as `created` ones, and an edit
    # keeps the comment's id, so identity alone would make an edited comment
    # look like a redelivery of the original and swallow it.
    {topic, payload,
     [
       issue_number: target,
       dedup_key: dedup_key,
       resource: resource,
       resource_version: resource_version(comment),
       resource_source: :webhook,
       actor: actor,
       bypass_contamination: true
     ]}
  end

  # `updated_at` for comments; a review submission has no `updated_at`, and its
  # `submitted_at` is the marker the poller's own cutoff already keys on.
  defp resource_version(%{"updated_at" => updated_at}) when is_binary(updated_at) and updated_at != "", do: updated_at
  defp resource_version(%{"submitted_at" => submitted_at}) when is_binary(submitted_at) and submitted_at != "", do: submitted_at
  defp resource_version(_comment), do: nil

  # Project a delivery's comment onto the shape the poller publishes.
  #
  # The poller never publishes GitHub's raw comment object: `CommentPollBatch`
  # reads comments over GraphQL and `normalize_comments/1` reduces each to
  # exactly these keys. A REST delivery carries roughly twice as many —
  # `node_id`, `url`, `issue_url`, `author_association`, `reactions`,
  # `performed_via_github_app` — and a full `user` object rather than a bare
  # login. Publishing the delivery as-is therefore hands consumers a visibly
  # different comment for the same GitHub event, which is precisely the drift
  # this module exists to prevent.
  #
  # Keys are taken one for one from `CommentPollBatch.normalize_comments/1`,
  # including its `body` and `updated_at` fallbacks. `line` and `path` ride along
  # only when present, matching `ReviewThreads.normalize_thread_comment/2` for
  # review threads while staying absent on issue comments, which is where the
  # poller leaves them. `review_thread_id` is the same: it is present on every
  # thread comment the poller publishes, and the delivery path stamps it on a
  # resolved review-comment delivery, so the published webhook comment matches
  # the poller's shape.
  defp poller_comment_shape(comment) when is_map(comment) do
    base = %{
      "id" => Map.get(comment, "id"),
      "body" => Map.get(comment, "body") || "",
      "created_at" => Map.get(comment, "created_at"),
      "updated_at" => Map.get(comment, "updated_at") || Map.get(comment, "created_at"),
      "html_url" => Map.get(comment, "html_url"),
      "user" => %{"login" => get_in(comment, ["user", "login"])}
    }

    Enum.reduce(["path", "line", "review_thread_id"], base, fn key, acc ->
      case Map.fetch(comment, key) do
        {:ok, value} -> Map.put(acc, key, value)
        :error -> acc
      end
    end)
  end

  defp poller_comment_shape(comment), do: comment

  @doc """
  The poller's comment shape for one delivered comment.

  Public for `Aiur.Events.GithubWebhook.Deposit`, which writes the delivered
  comment into the resource store. A stored comment has to be the same shape as
  a published one for the same reason a published one does: a consumer must not
  be able to tell which producer paid for it.
  """
  @spec comment_shape(term()) :: term()
  def comment_shape(comment), do: poller_comment_shape(comment)

  @doc """
  The poller's review shape for one delivered review.

  Same contract as `comment_shape/1`, for the one topic the poller publishes
  unprojected: only the `state` casing differs between the two producers.
  """
  @spec review_shape(term()) :: term()
  def review_shape(review), do: upcase_review_state(review)

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
  # For `head_committed_at` failing open is correct by construction: a push
  # delivery *is* the review or comment that just happened, so it cannot be a
  # judgement about an older head and there is nothing for the staleness half of
  # the gate to suppress.
  #
  # `review_decision` is a genuine divergence, and a wider one than "PR-attached
  # issue comments" — it applies to every comment topic this module publishes.
  # `reviewDecision` is GraphQL-only, so no delivery can carry it: on an APPROVED
  # pull request the poller's batch path publishes `"APPROVED"` and suppresses
  # rework, while the webhook publishes nil and routes the ticket to rework for
  # the same GitHub event. Pinned by the `review_decision` case in
  # `github_webhook_equivalence_test.exs`.
  #
  # This is not closable inside the normalizer, which is pure: it needs a GraphQL
  # fetch in the delivery path, which lands on the W-1 receiver's request path
  # and interacts with W-4's ordering work. Reported on the PR rather than
  # silently absorbed. Reading through `Map.get/2` rather than hardcoding nil
  # means the fix is a matter of enriching the map before it reaches here.
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

  # The poller reads reviews from `GET /pulls/N/reviews`, which reports `state`
  # in upper case; a `pull_request_review` delivery reports the same states in
  # lower case. `actionable_review?/1` already folds case so the *filter* agrees,
  # but the published review carried the delivery's own casing, so a consumer
  # matching `"CHANGES_REQUESTED"` on the event would see it only on the polling
  # path. Nothing reads it off the event today; this keeps it that way by
  # accident rather than by luck.
  #
  # Upper case is the shape to converge on because it is the poller's, and this
  # is a no-op when a delivery already agrees.
  defp upcase_review_state(%{"state" => state} = review) when is_binary(state),
    do: Map.put(review, "state", String.upcase(state))

  defp upcase_review_state(review), do: review

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
