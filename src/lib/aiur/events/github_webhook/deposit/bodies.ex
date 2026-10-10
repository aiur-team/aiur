defmodule Aiur.Events.GithubWebhook.Deposit.Bodies do
  @moduledoc """
  What each delivery type carries.

  Pure: reads a payload and answers the `t:Aiur.Events.GithubWebhook.Deposit.work/0`
  list `Aiur.Events.GithubWebhook.Deposit.deposit/4` hands to the store. The
  shapes, the never-servable rule and the ordering markers are described on
  that module.
  """

  alias Aiur.Events.GithubWebhook.{Deposit, Triples}
  alias Aiur.TicketBranch

  @doc """
  The work one delivery carries: bodies to deposit, identities to drop, and
  snapshot merges. An unhandled event type or a malformed payload answers `[]`.
  """
  @spec bodies(String.t(), map(), keyword()) :: [Deposit.work()]
  def bodies(event_type, payload, opts)

  # An `issue_comment` delivery carries the comment *and* the whole issue it
  # hangs off, so one free delivery populates both.
  def bodies("issue_comment", payload, _opts) do
    comment = Map.get(payload, "comment")
    issue = Map.get(payload, "issue")
    action = Map.get(payload, "action")

    # The issue rides along on its own terms. The action belongs to the
    # *comment*, so it must not reach the issue: deleting a comment would
    # otherwise discard the cached issue body, using a delivery that is carrying
    # a complete and current one.
    comment_deposits(:issue_comment, action, comment) ++ carried_issue_deposits(issue)
  end

  def bodies("pull_request_review_comment", payload, _opts) do
    comment = Map.get(payload, "comment")
    action = Map.get(payload, "action")

    review_thread_invalidation(payload) ++
      comment_deposits(:pr_review_comment, action, comment) ++
      pull_request_deposits(Map.get(payload, "pull_request"))
  end

  def bodies("pull_request_review", payload, _opts) do
    review = Map.get(payload, "review")
    action = Map.get(payload, "action")

    review_deposits(action, review) ++ pull_request_deposits(Map.get(payload, "pull_request"))
  end

  # A `pull_request_review_thread` delivery (resolved/unresolved) carries a full
  # pull request plus the thread, and three kinds of deposit come out of it:
  #
  #   * the PR under `:pull_request` / `:branch_pull_request` (feeds
  #     `Aiur.GitHub.DeliveredPullRequest`, which decides whether the comment
  #     poller pays for its per-PR `review_threads_unaddressed` fallback on this
  #     cycle — the single most common GraphQL spend the audit found, #2326),
  #   * the thread snapshot for the resolved case (`:merge_review_thread`) or
  #     its invalidation for every other action (#2276's poll-snapshot
  #     convergence), and
  #   * the transition marker (`:thread_transition`) that records the
  #     resolve/unresolve generation so a re-raised thread wakes the agent again
  #     without republishing one transition.
  def bodies("pull_request_review_thread", payload, opts) do
    action = Map.get(payload, "action")
    thread = Map.get(payload, "thread")

    snapshot_deposits =
      if action == "resolved" do
        with %{} = pull_request <- Map.get(payload, "pull_request"),
             pr_number when not is_nil(pr_number) <- Map.get(pull_request, "number"),
             %{} = thread <- Map.get(payload, "thread"),
             %{"id" => id} = normalized when is_binary(id) and id != "" <- normalize_review_thread(thread) do
          [{:merge_review_thread, pr_number, normalized}]
        else
          _other -> review_thread_invalidation(payload)
        end
      else
        # `unresolved` above all — the held resolution state is wrong and none
        # of these carry enough to merge. An un-resolved thread left
        # webhook-fresh as `isResolved: true` is filtered out of the unaddressed
        # set, so the reviewer's re-raised objection disappears and the agent
        # proceeds as though it were answered. Drop the snapshot and let the
        # next poll pay for the truth.
        review_thread_invalidation(payload)
      end

    transition_deposits =
      if action in ["resolved", "unresolved"] and is_map(thread) do
        thread_id = Map.get(thread, "node_id")
        updated_at = Map.get(payload, "updated_at") || Map.get(thread, "updated_at")
        generation = updated_at || Keyword.get(opts, :delivery_id)

        [{:thread_transition, thread_id, action, thread, generation, updated_at}]
      else
        []
      end

    pull_request_deposits(Map.get(payload, "pull_request")) ++ snapshot_deposits ++ transition_deposits
  end

  def bodies("check_run", payload, _opts) do
    with %{} = check_run <- Map.get(payload, "check_run"),
         head_sha when is_binary(head_sha) and head_sha != "" <- Map.get(check_run, "head_sha"),
         %{"id" => id} = normalized when not is_nil(id) <- normalize_check_run(check_run) do
      check_run_deposits(check_run, head_sha, normalized)
    else
      _other -> []
    end
  end

  def bodies("pull_request", payload, _opts), do: pull_request_deposits(Map.get(payload, "pull_request"))

  def bodies("issues", payload, _opts), do: issue_deposits(Map.get(payload, "action"), Map.get(payload, "issue"))

  # A `sub_issues` delivery mutates the Build Order graph's membership: an issue
  # becomes (or stops being) a member of a root. There is no fleet event to
  # publish for it — the catalog is event-sourced from the store — so this
  # delivery's job is to deposit the edge, with the edge's `present` flag
  # storing the *operation* at the delivery's arrival version so the
  # stale-delivery guard can refuse a late `added` after a `removed` and
  # vice-versa (#2313). The full sub-issue and parent issue are also deposited
  # as carried issues (`:issue` / `:issue_labels`) for the readers those
  # resources serve (#2326).
  #
  # A `parent_issue_*` action and a `sub_issue_*` action are the same edge from
  # either end, so they deposit the same key.
  def bodies("sub_issues", payload, _opts) do
    action = Map.get(payload, "action")
    edge = sub_issue_edge(payload)

    carried_issue_deposits(Map.get(payload, "sub_issue")) ++
      carried_issue_deposits(Map.get(payload, "parent_issue")) ++
      if is_map(edge) do
        if removed_action?(action), do: [edge_deposit(:sub_issue, edge, false)], else: [edge_deposit(:sub_issue, edge, true)]
      else
        []
      end
  end

  # An `issue_dependencies` delivery mutates the graph's dependency edges. Like
  # `sub_issues` there is no fleet event: the deposit is the whole point. The
  # two directions of one edge (`blocked_by_added` says A is blocked by B;
  # `blocking_added` says B blocks A) normalize to one canonical key so the two
  # actions cannot create two store entries for the same fact. The carried
  # issue is deposited like any carried issue, and the edge is merged into the
  # `:issue_blocked_by` list the dependency reader serves (#2326).
  def bodies("issue_dependencies", payload, _opts) do
    action = Map.get(payload, "action")
    edge = dependency_edge(payload)
    issue = Map.get(payload, "issue")

    carried_issue_deposits(issue) ++
      blocked_by_edge_deposits(action, issue, Map.get(payload, "blocked_by_issue")) ++
      if is_map(edge) do
        if removed_action?(action), do: [edge_deposit(:issue_dependency, edge, false)], else: [edge_deposit(:issue_dependency, edge, true)]
      else
        []
      end
  end

  def bodies(_event_type, _payload, _opts), do: []

  defp check_run_deposits(check_run, head_sha, normalized) do
    # A malformed `pull_requests` element (not a map) must not raise here: it
    # runs inside `deposit/3`'s `bodies` walk, whose rescue would abort the whole
    # delivery — including `invalidate_read_cache/3`, silently leaving the cache
    # stale. Skip the element and still merge the valid runs.
    check_run
    |> Map.get("pull_requests", [])
    |> Enum.flat_map(fn
      pr when is_map(pr) -> [pr |> get_in(["head", "ref"]) |> TicketBranch.ticket_id()]
      _not_a_map -> []
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.map(&{:merge_check_run, &1, head_sha, normalized})
  end

  defp normalize_review_thread(thread) do
    %{
      "id" => Map.get(thread, "node_id") || Map.get(thread, "id"),
      "isResolved" => true,
      "updatedAt" => Map.get(thread, "updated_at"),
      "path" => Map.get(thread, "path"),
      "line" => Map.get(thread, "line")
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  # Paired with `Aiur.GitHub.CIPollBatch.normalize_check_run/1`; see the note
  # there. The REST `"id"` and the GraphQL `databaseId` are the same number,
  # which is what lets a delivery merge into a polled baseline at all.
  defp normalize_check_run(check_run) do
    %{
      "id" => Map.get(check_run, "id"),
      "name" => Map.get(check_run, "name"),
      "status" => Map.get(check_run, "status"),
      "conclusion" => Map.get(check_run, "conclusion"),
      "started_at" => Map.get(check_run, "started_at"),
      "completed_at" => Map.get(check_run, "completed_at"),
      "updated_at" => Map.get(check_run, "updated_at"),
      "check_suite_id" => get_in(check_run, ["check_suite", "id"]),
      "app" => Map.get(check_run, "app", %{}),
      "output" => Map.get(check_run, "output", %{})
    }
  end

  defp comment_deposits(_type, _action, comment) when not is_map(comment), do: []

  defp comment_deposits(type, "deleted", comment), do: [{:drop, type, Map.get(comment, "id")}]

  defp comment_deposits(type, action, comment) when action in ["created", "edited"] do
    [{type, Map.get(comment, "id"), Triples.comment_shape(comment), version(comment)}]
  end

  # Any other action (a reaction, an unknown future one) is not a statement
  # about the comment body, so it deposits nothing rather than re-writing what
  # is already held.
  defp comment_deposits(_type, _action, _comment), do: []

  defp review_thread_invalidation(payload) do
    case get_in(payload, ["pull_request", "number"]) do
      pr_number when not is_nil(pr_number) -> [{:invalidate_review_threads, pr_number}]
      _other -> []
    end
  end

  defp review_deposits("submitted", review) when is_map(review) do
    [{:pr_review, Map.get(review, "id"), Triples.review_shape(review), version(review)}]
  end

  # An edit or a dismissal changes the review — its body, or its `state` to
  # `DISMISSED` — while `submitted_at` stays exactly where it was, and a REST
  # review carries no `updated_at`. Deposited as "version unknown" rather than
  # under the submission marker, because a changed body filed under an unchanged
  # version tells the next reader something false.
  defp review_deposits(action, review) when is_map(review) and action in ["edited", "dismissed"] do
    [{:pr_review, Map.get(review, "id"), Triples.review_shape(review), nil}]
  end

  defp review_deposits(_action, _review), do: []

  defp issue_deposits(_action, issue) when not is_map(issue), do: []

  # A deleted issue takes its label set with it. Leaving the labels behind would
  # hold a set for a body nothing holds — an entry that contradicts itself.
  defp issue_deposits("deleted", issue) do
    number = Map.get(issue, "number")
    [{:drop, :issue, number}, {:drop, :issue_labels, number}]
  end

  defp issue_deposits(_action, issue), do: carried_issue_deposits(issue)

  defp carried_issue_deposits(issue) when not is_map(issue), do: []

  defp carried_issue_deposits(issue) do
    number = Map.get(issue, "number")
    issue_version = version(issue)

    # GitHub's own `labels` array, which is what both a label mutation response
    # and a conditional re-read of the issue return. The label set rides on the
    # issue's version because it is part of the issue's own state.
    label_deposits =
      case Map.get(issue, "labels") do
        labels when is_list(labels) -> [{:issue_labels, number, labels, issue_version}]
        _other -> []
      end

    [{:issue, number, issue, issue_version}] ++ label_deposits
  end

  # The `issue_dependencies` delivery names one edge, and its `action` tells the
  # direction. `blocked_by_added` makes `issue` blocked by `edge`; that is a fact
  # about the blocked issue's dependency list, so it is written into the
  # `:issue_blocked_by` entry the reader serves (#2326). `blocked_by_removed` is
  # the death of the edge, and the held list stops naming it by being dropped
  # wholesale — the next read pays for the truth rather than trusting a merge
  # against a list that may never have been complete. A delivery about the other
  # direction (`blocking_issue`) has no stored reader, so it deposits nothing
  # about the edge.
  defp blocked_by_edge_deposits("blocked_by_added", issue, edge) when is_map(issue) and is_map(edge) do
    case Map.get(issue, "number") do
      number when is_integer(number) -> [{:issue_blocked_by, number, edge, version(edge)}]
      _other -> []
    end
  end

  defp blocked_by_edge_deposits("blocked_by_removed", issue, _edge) when is_map(issue) do
    case Map.get(issue, "number") do
      number when is_integer(number) -> [{:drop, :issue_blocked_by, number}]
      _other -> []
    end
  end

  defp blocked_by_edge_deposits(_action, _issue, _edge), do: []

  # A pull request is deposited under BOTH keys a consumer can address it by
  # (#2126):
  #
  #   * `:pull_request`, keyed by the PR's own number — the identity a mutation
  #     write-through and the agent-cache bridge use, and the only one a
  #     delivery can honestly claim for itself.
  #   * `:branch_pull_request`, keyed by the TICKET its head branch belongs to —
  #     the exact key `Aiur.GitHub.HumanReviewGate.open_pull_request/1` reads.
  #     The gate reads strictly (R10), so this body is never served for its
  #     answer; holding it is what lets `ResourceStore.etag/1` answer, which is
  #     what permits the read to revalidate with `If-None-Match` instead of
  #     paying full price.
  #
  # A head branch that is not an Aiur ticket branch (`main`, a watched PR's own
  # branch) derives no ticket id, so it is deposited only under its PR number —
  # there is no ticket key for the gate to have read.
  defp pull_request_deposits(pr) when is_map(pr) do
    version = version(pr)
    [{:pull_request, Map.get(pr, "number"), pr, version}] ++ branch_pull_request_deposits(pr, version)
  end

  defp pull_request_deposits(_pr), do: []

  defp branch_pull_request_deposits(pr, version) do
    case TicketBranch.ticket_id(get_in(pr, ["head", "ref"])) do
      nil -> []
      ticket_id -> [{:branch_pull_request, ticket_id, pr, version}]
    end
  end

  # -- Build Order graph edges (#2313) --------------------------------------
  # `sub_issues` and `issue_dependencies` deliveries carry no `updated_at` on
  # either issue — the payload is pure edge facts — so the deposit versions each
  # edge with the delivery's arrival time (threaded as `:at`, falling back to
  # now). That version is what lets `deposit_unless_older/3` refuse a late
  # `added` after a `removed` for the same edge, and a late `removed` after a
  # newer `added`. Without it, out-of-order delivery would silently invert the
  # graph the catalog renders.

  # An `*_removed` action is the mirror of an `*_added`, and both directions
  # (`parent_issue_*`/`sub_issue_*`, `blocked_by_*`/`blocking_*`) describe the
  # same edge, so the edge key is canonical and the operation is stored in the
  # body.
  defp removed_action?(action)
       when action in [
              "parent_issue_removed",
              "sub_issue_removed",
              "blocked_by_removed",
              "blocking_removed"
            ],
       do: true

  defp removed_action?(_action), do: false

  defp sub_issue_edge(payload) do
    with parent when not is_nil(parent) <- positive_number(Map.get(payload, "parent_issue_number")),
         sub when not is_nil(sub) <- positive_number(Map.get(payload, "sub_issue_number")) do
      %{
        "parent_issue_number" => parent,
        "sub_issue_number" => sub,
        "parent_issue_repo" => repo_string(Map.get(payload, "parent_issue_repo")),
        "sub_issue_repo" => repo_string(Map.get(payload, "sub_issue_repo"))
      }
    else
      _other -> nil
    end
  end

  # One edge, two actions. `blocked_by_added` reports A blocked by B;
  # `blocking_added` reports B blocking A. Both store the same canonical
  # `blocked:blocker` key, so the projection reads one entry per fact.
  defp dependency_edge(payload) do
    with blocked when not is_nil(blocked) <- positive_number(Map.get(payload, "blocked_issue_number")),
         blocker when not is_nil(blocker) <- positive_number(Map.get(payload, "blocking_issue_number")) do
      %{
        "blocked_issue_number" => blocked,
        "blocking_issue_number" => blocker,
        "blocked_issue_repo" => repo_string(Map.get(payload, "blocked_issue_repo")),
        "blocking_issue_repo" => repo_string(Map.get(payload, "blocking_issue_repo"))
      }
    else
      _other -> nil
    end
  end

  defp edge_deposit(:sub_issue, edge, present) do
    edge = Map.put(edge, "present", present)
    id = "#{edge["parent_issue_number"]}:#{edge["sub_issue_number"]}"
    {:sub_issue, id, edge, nil}
  end

  defp edge_deposit(:issue_dependency, edge, present) do
    edge = Map.put(edge, "present", present)
    id = "#{edge["blocked_issue_number"]}:#{edge["blocking_issue_number"]}"
    {:issue_dependency, id, edge, nil}
  end

  defp positive_number(value) when is_integer(value) and value > 0, do: value

  defp positive_number(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} when number > 0 -> number
      _other -> nil
    end
  end

  defp positive_number(_value), do: nil

  defp repo_string(value) when is_binary(value) and value != "", do: value
  defp repo_string(_value), do: nil

  # Reviews use submitted_at; issues, PRs and comments use updated_at as their mutation marker.
  defp version(%{"updated_at" => updated_at}) when is_binary(updated_at) and updated_at != "", do: updated_at

  defp version(%{"submitted_at" => submitted_at}) when is_binary(submitted_at) and submitted_at != "",
    do: submitted_at

  defp version(_resource), do: nil
end
