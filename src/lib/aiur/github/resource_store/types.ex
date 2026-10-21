defmodule Aiur.GitHub.ResourceStore.Types do
  @moduledoc """
  Internal types operations for `Aiur.GitHub.ResourceStore`.
  """

  require Logger

  # The closed set of resource identities. Declared here rather than left to
  # whichever module happens to be loaded first, because `decode_key/1` resolves
  # a checkpointed type with `String.to_existing_atom/1` and would otherwise
  # drop entries for a type whose only mention lives in a not-yet-loaded module.
  @resource_types [
    # Individual events — the identity both pipes agree on, used to decide
    # whether this exact comment/review has already been processed.
    :issue_comment,
    :pr_review_comment,
    :pr_review,
    # Whole resources — the identity a reader asks for and a mutation returns.
    :issue,
    :issue_labels,
    :pr_review_thread,
    :pr_review_threads,
    :ci_contexts,
    :commit_ci_check_runs,
    :commit_ci_status,
    :landing_merge_group_runs,
    :ci_failure_digest,
    :main_watch,
    :flake_issues,
    :issue_comments,
    :issue_timeline,
    :pr_issue_comments,
    # The two repo-wide comment streams. `Aiur.GitHub.Listeners.CommandScan.Scan` used to
    # keep their validators under its own call-site names, so its cached state
    # was private to that one caller and died with the orchestrator's memory. The
    # streams are a property of the repository, not of the scan, so they are
    # named here and shared like everything else.
    :repo_issue_comment_stream,
    :repo_review_comment_stream,
    :pull_request,
    :pull_request_reviews,
    :labelled_pull_requests,
    # The open pull request belonging to a ticket's head branch. Keyed by the
    # ticket number rather than the PR number, because that is the only identity
    # the caller holds before the lookup answers.
    :branch_pull_request,
    # Build Order graph edges (#2313). One entry per edge, keyed by the two
    # issue numbers it connects (`"parent:sub"` / `"blocked:blocker"`). The body
    # carries the edge facts plus `present`, the last operation observed: a
    # webhook `sub_issue_added`/`blocked_by_added` deposits `present: true` and
    # the matching `*_removed` deposits a tombstone. Both types are written by
    # `Aiur.Events.GithubWebhook.Deposit` (and the rare GraphQL reconciliation),
    # and they are the Build Order catalog's event-sourced membership and
    # dependency inputs.
    :sub_issue,
    :issue_dependency,
    # The set of issues an issue is currently blocked by, answered by
    # `GET /repos/:o/:r/issues/:n/dependencies/blocked_by` and read through
    # `Aiur.GitHub.DependenciesApi.dependency_get/3`. Keyed by the blocked
    # issue's number. Written by the endpoint's own 200 (the full list, with the
    # response ETag), and fed from free sources: `dependency_mutate`'s own write
    # and the `issue_dependencies` webhook delivery both merge the single edge
    # they carried into the held list (#2326).
    :issue_blocked_by,
    # The review thread a comment belongs to, keyed by the comment's `databaseId`
    # and holding the thread's GraphQL node id. Fed by `Aiur.GitHub.CommentPollBatch`,
    # which parses `reviewThreads { comments { databaseId } }` on every cycle; a
    # `pull_request_review_comment` webhook delivery consults it before paying for
    # a GraphQL node lookup (#2326). A comment's thread is immutable, so the
    # mapping never goes stale.
    :pr_review_comment_thread,
    # Conditional validator for the page-one listing, separate from the PR-body key.
    :branch_pull_request_listing,
    :branch_pull_request_listing_all
  ]

  # The identities where a body's *order* decides correctness: a whole mutable
  # resource that arrives from more than one pipe, where a late delivery can roll
  # state back. These are the ones a version-less deposit quietly disarms, so
  # they are the ones the store says something about. An endpoint list carries no
  # marker of its own and is not ordered against anything.
  #
  # `:branch_pull_request` is written by both the webhook deposit and
  # `Aiur.GitHub.ResourceFetch` (the human-review gate's strict read stores its
  # fetch), so a late delivery can roll the held PR back — the same reason
  # `:pull_request` is here. `:issue_blocked_by` is written by the webhook edge
  # deposit, the dependency mutation and the full `blocked_by` fetch, and a late
  # `blocked_by_added` arriving after a `blocked_by_removed` would roll the held
  # list back to claiming an edge the removal already dropped — so it is ordered
  # too, and the merge writes carry the delivery's own marker. `:check_run` was
  # removed from the store entirely when its deposit was ceased (#2126); a CI
  # verdict is never cached.
  #
  # `:sub_issue` and `:issue_dependency` are here because an edge's *order*
  # decides its state: a `*_added` then `*_removed` arriving out of order
  # inverts the edge, exactly like a whole resource rolling back. The deposit
  # versions every edge with its delivery's arrival time so the store's
  # stale-delivery guard refuses a late add or remove (#2313).
  #
  # `:pr_review_thread` is deliberately *not* order-sensitive at the entry
  # level: its webhook transition marker carries its own ordering clock
  # (`Deposit.accept_thread_transition/6` compares the incoming transition's
  # `updated_at` against the held marker's `"updated_at"` field), and the
  # comment pipe writes the same key's processed-mark version. Both writers
  # legitimately store bodies with no entry-level `data_version`, so warning
  # about the version-less deposit would be noise about a guard that no longer
  # lives here.
  @order_sensitive_types [
    :issue,
    :issue_labels,
    :pull_request,
    :branch_pull_request,
    :sub_issue,
    :issue_dependency,
    :issue_blocked_by
  ]

  @type key :: Aiur.GitHub.ResourceStore.key()
  @type resource_type :: Aiur.GitHub.ResourceStore.resource_type()

  @spec resource_types() :: [atom()]
  def resource_types, do: @resource_types
  @spec order_sensitive_types() :: [atom()]
  def order_sensitive_types, do: @order_sensitive_types
  @spec key(resource_type(), String.t(), String.t(), term()) :: key() | nil
  def key(resource_type, owner, repo, id) when is_atom(resource_type) and is_binary(owner) and is_binary(repo) do
    if resource_type in @resource_types do
      case normalize_id(id) do
        nil -> nil
        normalized -> {resource_type, String.downcase(owner), String.downcase(repo), normalized}
      end
    else
      Logger.error(
        "GitHub.ResourceStore refused unknown resource type #{inspect(resource_type)}; " <>
          "add it to Aiur.GitHub.ResourceStore's @resource_types or entries for it will not survive a restart"
      )

      nil
    end
  end

  def key(_resource_type, _owner, _repo, _id), do: nil

  @spec key_for_repo(resource_type(), String.t() | nil, term()) :: key() | nil
  def key_for_repo(resource_type, full_name, id) when is_binary(full_name) do
    case String.split(full_name, "/") do
      [owner, repo] when owner != "" and repo != "" -> key(resource_type, owner, repo, id)
      _other -> nil
    end
  end

  def key_for_repo(_resource_type, _full_name, _id), do: nil
  @spec normalize_id(term()) :: String.t() | nil
  def normalize_id(id) when is_integer(id), do: Integer.to_string(id)
  def normalize_id(id) when is_binary(id) and id != "", do: id
  def normalize_id(_id), do: nil
end
