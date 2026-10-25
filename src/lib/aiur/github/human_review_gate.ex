defmodule Aiur.GitHub.HumanReviewGate do
  @moduledoc """
  Human-review readiness checks for GitHub issues.

  This gate checks the canonical PR's Local tests evidence and review threads.
  For human review, it also rejects base conflicts; mergeable PRs may wait
  through base movement because the merge queue tests them against current base.
  """

  alias Aiur.Config
  alias Aiur.GitHub.HumanReviewEvidence

  alias Aiur.GitHub.{
    BotIdentity,
    PullRequests,
    ResourceFetch,
    ResourceStore,
    ReviewThreads,
    StatePolicy,
    Transport
  }

  @approval_fields "headRefOid reviewDecision mergeQueueEntry { id } reviews(states: APPROVED, last: 1) { nodes { commit { oid } } }"

  @spec verify_human_review_ready(String.t() | integer(), keyword()) :: :ok | {:error, term()}
  def verify_human_review_ready(issue_number, opts \\ []) do
    with {:ok, token} <- Transport.require_token(opts) do
      request_fun = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)

      context = %{
        issue_number: to_string(issue_number),
        request_fun: request_fun,
        token: token,
        opts: opts
      }

      verify_issue_review_threads_clear(context)
    end
  end

  @doc false
  @spec pull_request_mergeability(integer(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def pull_request_mergeability(pr_number, opts \\ []) do
    query =
      "query AiurPullRequestMergeability($owner: String!, $name: String!, $number: Int!) { repository(owner: $owner, name: $name) { pullRequest(number: $number) { mergeable } } }"

    with {:ok, token} <- Transport.require_token(opts),
         {:ok, {owner, name}} <- Transport.parse_repo(),
         {:ok, %{"data" => %{"repository" => %{"pullRequest" => %{"mergeable" => mergeability}}}}} <-
           Transport.github_graphql(
             Keyword.get(opts, :request_fun, &Transport.default_request_fun/1),
             token,
             query,
             %{"owner" => owner, "name" => name, "number" => pr_number},
             caller: "orphan_claim_mergeability"
           ),
         true <- mergeability in ["MERGEABLE", "CONFLICTING", "UNKNOWN"] do
      {:ok, mergeability}
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_mergeability_observation}
    end
  end

  @doc false
  @spec pull_request_approved_at_head?(integer(), keyword()) ::
          {:ok, boolean()} | {:error, term()}
  def pull_request_approved_at_head?(pr_number, opts \\ []) do
    with {:ok, {head, approved}} <- pull_request_approval(pr_number, opts),
         do: {:ok, approved == head}
  end

  @doc "The PR head and the commit its standing approval names (`nil` unless `reviewDecision` is APPROVED)."
  @spec pull_request_approval(integer(), keyword()) ::
          {:ok, {String.t(), String.t() | nil}} | {:error, term()}
  def pull_request_approval(pr_number, opts \\ []) do
    query =
      "query AiurPullRequestApprovalAtHead($owner: String!, $name: String!, $number: Int!) { repository(owner: $owner, name: $name) { pullRequest(number: $number) { headRefOid reviewDecision reviews(states: APPROVED, last: 1) { nodes { commit { oid } } } } } }"

    with {:ok, token} <- Transport.require_token(opts),
         {:ok, {owner, name}} <- Transport.parse_repo(),
         {:ok, body} <-
           Transport.github_graphql(Keyword.get(opts, :request_fun, &Transport.default_request_fun/1), token, query, %{"owner" => owner, "name" => name, "number" => pr_number},
             caller: Keyword.get(opts, :caller, "orphan_claim_approval_state")
           ),
         %{"headRefOid" => head, "reviewDecision" => decision, "reviews" => %{"nodes" => nodes}} = pr
         when is_binary(head) and decision in [nil, "APPROVED", "CHANGES_REQUESTED", "REVIEW_REQUIRED"] and is_list(nodes) <-
           get_in(body, ["data", "repository", "pullRequest"]) do
      {:ok, {head, approved_commit(pr)}}
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_pull_request_approval}
    end
  end

  @doc false
  @spec optimistic_approval_status(integer(), keyword()) :: {:ok, map()} | {:error, term()}
  def optimistic_approval_status(pr_number, opts \\ []) do
    query =
      "query AiurPullRequestApprovalAtHead($owner: String!, $name: String!, $number: Int!) { repository(owner: $owner, name: $name) { pullRequest(number: $number) { headRefOid mergeable reviewDecision reviews(states: APPROVED, last: 1) { nodes { commit { oid } } } } } }"

    with {:ok, token} <- Transport.require_token(opts),
         {:ok, {owner, name}} <- Transport.parse_repo(),
         {:ok, body} <-
           Transport.github_graphql(
             Keyword.get(opts, :request_fun, &Transport.default_request_fun/1),
             token,
             query,
             %{"owner" => owner, "name" => name, "number" => pr_number},
             caller: Keyword.get(opts, :caller, "optimistic_guard_approval")
           ),
         %{"data" => %{"repository" => %{"pullRequest" => pr}}} <- body,
         %{"headRefOid" => head, "mergeable" => mergeable, "reviewDecision" => decision, "reviews" => %{"nodes" => nodes}} = pr,
         true <-
           is_binary(head) and mergeable in ["MERGEABLE", "CONFLICTING", "UNKNOWN"] and
             decision in [nil, "APPROVED", "CHANGES_REQUESTED", "REVIEW_REQUIRED"] and is_list(nodes) do
      approved_head = approved_commit(pr)

      {:ok,
       %{
         head_sha: head,
         approved_head_sha: approved_head,
         approved?: decision == "APPROVED" and approved_head == head,
         mergeable?: mergeable == "MERGEABLE"
       }}
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_pull_request_approval}
    end
  end

  @doc false
  @spec verify_human_review_review_threads_clear(map(), String.t()) :: :ok | {:error, term()}
  def verify_human_review_review_threads_clear(context, state_name) do
    if StatePolicy.human_review_target_state?(state_name) do
      verify_issue_ready(context, true)
    else
      :ok
    end
  end

  @doc false
  @spec verify_issue_review_threads_clear(map()) :: :ok | {:error, term()}
  def verify_issue_review_threads_clear(context), do: verify_issue_ready(context, false)

  defp verify_issue_ready(context, check_base?) do
    case open_pull_request(context) do
      {:ok, %{"number" => pr_number} = pr} when is_integer(pr_number) ->
        with :ok <- HumanReviewEvidence.verify(context, pr),
             {:ok, agent_login} <-
               BotIdentity.bot_account(context.opts, context.request_fun, context.token),
             :ok <- verify_pr_review_threads_clear(context, pr_number, agent_login) do
          verify_base_ancestry(context, pr, check_base?)
        end

      {:ok, nil} ->
        :ok

      {:ok, _pr} ->
        :ok

      {:error, _reason} = error ->
        error
    end
  end

  defp verify_base_ancestry(_context, _pr, false), do: :ok

  defp verify_base_ancestry(
         context,
         %{"head" => %{"sha" => head_sha}, "number" => pr_number},
         true
       )
       when is_binary(head_sha) and head_sha != "" do
    base = Config.base_branch(context.opts)

    case compare(context, base, head_sha) do
      {:ok, %{"status" => status}} when status in ["ahead", "identical"] ->
        :ok

      {:ok, %{"status" => status}} when status in ["behind", "diverged"] ->
        verify_stale_base(context, pr_number, base, head_sha)

      {:ok, _body} ->
        {:error, :review_base_ancestry_unavailable}

      {:error, _reason} = error ->
        error
    end
  end

  defp verify_base_ancestry(_context, _pr, true), do: {:error, :review_base_ancestry_unavailable}

  defp compare(context, base, head, per_page \\ 1) do
    comparison =
      "#{URI.encode(base, &URI.char_unreserved?/1)}...#{URI.encode(head, &URI.char_unreserved?/1)}"

    url =
      "#{Transport.base_url()}/repos/#{repo_full_name()}/compare/#{comparison}?per_page=#{per_page}"

    # Branch movement cannot reuse a previous compatibility verdict.
    Transport.fetch_json_map(context.request_fun, context.token, url, caller: "human_review_base_ancestry")
  end

  defp verify_stale_base(context, pr_number, base, head) do
    stale =
      {:error, {:stale_review_base, %{pr_number: pr_number, base_branch: base, head_sha: head}}}

    case current_mergeability(context, pr_number, base, head) do
      result -> stale_base_result(result, context, base, head, stale)
    end
  end

  defp stale_base_result({:ok, :conflicting}, _context, _base, _head, stale), do: stale

  # An approved head in the merge queue, or armed to enter it, is tested merged with the base before it lands (#4204).
  defp stale_base_result({:ok, verdict}, _context, _base, _head, _stale)
       when verdict in [:merge_queue, :approved_head], do: :ok

  # A later push invalidates the old approval, but the changed head can still
  # be handed to a human for review without forcing a base merge.
  defp stale_base_result({:ok, {:mergeable, _approved_head}}, _context, _base, _head, _stale),
    do: :ok

  # A mergeable PR can wait for review/CI while the merge queue tests it on the
  # current base. Path overlap alone must not manufacture a rework turn.
  defp stale_base_result({:ok, :mergeable}, _context, _base, _head, _stale), do: :ok

  defp stale_base_result({:error, _reason} = error, _context, _base, _head, _stale), do: error

  defp current_mergeability(context, pr_number, base, head) do
    query = """
    query AiurHumanReviewMergeability($owner: String!, $name: String!, $number: Int!) {
      repository(owner: $owner, name: $name) {
        pullRequest(number: $number) { baseRefName mergeable autoMergeRequest { enabledAt } #{@approval_fields} }
      }
    }
    """

    {:ok, {owner, name}} = Transport.parse_repo()
    variables = %{"owner" => owner, "name" => name, "number" => pr_number}

    case Transport.github_graphql(context.request_fun, context.token, query, variables, caller: "human_review_base_ancestry") do
      {:ok,
       %{
         "data" => %{
           "repository" => %{
             "pullRequest" => %{
               "headRefOid" => ^head,
               "baseRefName" => ^base,
               "mergeable" => "CONFLICTING"
             }
           }
         }
       }} ->
        {:ok, :conflicting}

      {:ok,
       %{
         "data" => %{
           "repository" => %{
             "pullRequest" => %{"headRefOid" => ^head, "baseRefName" => ^base, "mergeable" => status} = pr
           }
         }
       }}
      when status in ["MERGEABLE", "UNKNOWN"] ->
        # UNKNOWN supplies no conflict signal. The merge queue tests the pinned
        # head on current base, so path overlap does not require an agent push.
        mergeability_for_approval(pr)

      {:ok, _body} ->
        {:error, :review_base_ancestry_unavailable}

      {:error, _reason} = error ->
        error
    end
  end

  defp mergeability_for_approval(pr) do
    landing? =
      approved_at_head?(pr) and (is_map(pr["mergeQueueEntry"]) or is_map(pr["autoMergeRequest"]))

    approved_head = approved_commit(pr)

    approval_mergeability(pr, landing?, approved_head)
  end

  defp approval_mergeability(_pr, true, _approved_head), do: {:ok, :merge_queue}

  # A human-approved exact head in the queue can be handed off without a base
  # refresh; the caller rejects actual conflicts before consulting this result.
  defp approval_mergeability(pr, false, approved_head),
    do: approval_mergeability(pr, approved_head)

  defp approval_mergeability(pr, approved_head) do
    if approved_at_head?(pr),
      do: {:ok, :approved_head},
      else: previous_approval_mergeability(pr, approved_head)
  end

  defp previous_approval_mergeability(%{"headRefOid" => head}, approved_head)
       when is_binary(approved_head) and approved_head != head,
       do: {:ok, {:mergeable, approved_head}}

  defp previous_approval_mergeability(_pr, _approved_head), do: {:ok, :mergeable}

  @doc false
  @spec verify_pr_review_threads_clear(map(), integer(), String.t()) :: :ok | {:error, term()}
  def verify_pr_review_threads_clear(context, pr_number, agent_login) do
    case ReviewThreads.fetch_unaddressed_pr_review_thread_comments(pr_number,
           request_fun: context.request_fun,
           token: context.token,
           agent_logins: [agent_login | Keyword.get(context.opts, :agent_logins, [])]
         ) do
      {:ok, []} ->
        :ok

      {:ok, comments} ->
        # An approved pull request is a human's judgement on the whole change,
        # and it outranks a thread nobody clicked "resolve" on. Reverting it to
        # rework deadlocks the ticket: the rework turn has nothing to fix, and
        # its liveness push dismisses the very approval that would release it
        # (#1756). Only read the reviews on this path, so an already-clean PR
        # still costs no extra request.
        if approved?(context, pr_number) do
          :ok
        else
          {:error,
           {:unverified_review_threads,
            %{
              issue_number: context.issue_number,
              pr_number: pr_number,
              review_thread_ids: Enum.map(comments, &Map.get(&1, "review_thread_id")) |> Enum.reject(&is_nil/1),
              comment_ids: Enum.map(comments, &Map.get(&1, "id")) |> Enum.reject(&is_nil/1),
              count: length(comments)
            }}}
        end

      {:error, _reason} = error ->
        error
    end
  end

  # R10: this is a **merge decision**. Both reads below declare
  # `ResourceFetch.decision()`, which is the strict tolerance — the store is not
  # consulted for the answer and upstream is contacted every time. They go
  # through `ResourceFetch` anyway rather than around it, because a decision path
  # with its own private fetch is exactly how a cache ends up bypassed by
  # accident later: the declaration has to live where the decision is made. The
  # answer is still deposited, so a tolerant view rides on the spend the decision
  # had to make.
  defp open_pull_request(context) do
    key = ResourceStore.key_for_repo(:branch_pull_request, repo_full_name(), context.issue_number)

    # Unconditional, and it stays that way here (#2126): this is a paginated
    # *search* of open pull requests by head branch, not a read of one resource,
    # so a validator for it would belong to the query rather than to the pull
    # request the answer names. It costs one request per gate check, and the
    # fetcher deliberately does not consume the `etag:` `ResourceFetch` offers —
    # that validator describes the stored `:branch_pull_request` body, and this
    # search cannot answer with it. The deposit still makes the key worth
    # holding: `Aiur.Events.GithubWebhook.Deposit` files the same PR body here
    # under the ticket number, so a *conditional* reader of this key could
    # revalidate with `If-None-Match` for free, and a strict read that returns
    # the identical body keeps the held validator rather than knocking it out.
    #
    # The per-cycle `Client.fetch_open_pull_request_for_branch` lookup runs the
    # same search conditionally under its own `:branch_pull_request_listing` key
    # (#2298): a page-1 validator for `GET /pulls?state=open` must not share this
    # key, because a webhook or gate deposit here would overwrite it with a
    # PR-body-derived validator the listing can never match. #2126 stands for
    # this key; the listing's validator lives on the query it belongs to.
    fetcher = fn _opts ->
      case PullRequests.fetch_open_pull_request_for_branch(context.issue_number,
             request_fun: context.request_fun,
             token: context.token
           ) do
        {:ok, pr} -> {:ok, pr}
        {:error, _reason} = error -> error
      end
    end

    case ResourceFetch.need(key, fetcher,
           freshness: ResourceFetch.decision(),
           reason: "merge decision: review threads"
         ) do
      {:ok, pr, _meta} -> {:ok, pr}
      {:error, _reason} = error -> error
    end
  end

  defp approved?(context, pr_number) do
    approved_pull_request?(pr_number, request_fun: context.request_fun, token: context.token) ==
      {:ok, true}
  end

  @doc "Returns whether at least one standing review approves and none requests changes."
  @spec approved_pull_request?(String.t() | integer(), keyword()) ::
          {:ok, boolean()} | {:error, term()}
  def approved_pull_request?(pr_number, opts \\ []) do
    key = ResourceStore.key_for_repo(:pull_request_reviews, repo_full_name(), pr_number)

    # A strict conditional read revalidates the standing verdict with GitHub.
    fetcher = fn fetch_opts ->
      PullRequests.fetch_pull_request_reviews_conditional(
        pr_number,
        Keyword.merge(opts, fetch_opts)
      )
    end

    case ResourceFetch.need(key, fetcher,
           freshness: ResourceFetch.decision(),
           reason: "merge decision: approval state"
         ) do
      {:ok, reviews, _meta} when is_list(reviews) ->
        {:ok, approved_decision?(standing_verdicts(reviews))}

      {:error, _reason} = error ->
        error

      _other ->
        {:error, :invalid_pull_request_reviews}
    end
  end

  @doc "Returns whether the pull request is approved and sitting in the merge queue, where its branch cannot be pushed."
  @spec approved_and_queued?(integer(), keyword()) :: {:ok, boolean()} | {:error, term()}
  def approved_and_queued?(pr_number, opts \\ []) do
    query = """
    query AiurQueuedApproval($owner: String!, $name: String!, $number: Int!) {
      repository(owner: $owner, name: $name) {
        pullRequest(number: $number) { #{@approval_fields} }
      }
    }
    """

    with {:ok, token} <- Transport.require_token(opts),
         {:ok, {owner, name}} <- Transport.parse_repo() do
      request_fun = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)
      variables = %{"owner" => owner, "name" => name, "number" => pr_number}

      case Transport.github_graphql(request_fun, token, query, variables, caller: "rework_gate_merge_queue") do
        {:ok, %{"data" => %{"repository" => %{"pullRequest" => %{"mergeQueueEntry" => entry} = pr}}}} ->
          {:ok, approved_at_head?(pr) and is_map(entry)}

        {:ok, _body} ->
          {:error, :invalid_pull_request}

        {:error, _reason} = error ->
          error
      end
    end
  end

  # `reviewDecision` stays APPROVED after a later push unless the ruleset dismisses stale approvals, so the approval must name the current head.
  defp approved_at_head?(%{
         "reviewDecision" => "APPROVED",
         "headRefOid" => head,
         "reviews" => %{"nodes" => [%{"commit" => %{"oid" => head}}]}
       })
       when is_binary(head), do: true

  defp approved_at_head?(_pull_request), do: false

  defp approved_commit(%{
         "reviewDecision" => "APPROVED",
         "reviews" => %{"nodes" => [%{"commit" => %{"oid" => oid}}]}
       })
       when is_binary(oid) and oid != "", do: oid

  defp approved_commit(_pull_request), do: nil

  # An unresolvable repository identity means no store key, which `ResourceFetch`
  # already treats as the storeless path — the read still happens, exactly as it
  # did before.
  defp repo_full_name do
    case Transport.parse_repo() do
      {:ok, {owner, repo}} -> "#{owner}/#{repo}"
      _other -> nil
    end
  end

  defp standing_verdicts(reviews) do
    reviews
    |> Enum.filter(
      &(get_in(&1, ["user", "login"]) != nil and
          Map.get(&1, "state") in ~w(APPROVED CHANGES_REQUESTED DISMISSED))
    )
    |> Enum.group_by(&get_in(&1, ["user", "login"]))
    |> Enum.map(fn {_login, reviewer_reviews} ->
      reviewer_reviews
      |> Enum.max_by(&(Map.get(&1, "submitted_at") || ""), fn -> %{} end)
      |> Map.get("state")
    end)
  end

  defp approved_decision?(verdicts) do
    "APPROVED" in verdicts and "CHANGES_REQUESTED" not in verdicts
  end
end
