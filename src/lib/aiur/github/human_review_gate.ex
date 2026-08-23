defmodule Aiur.GitHub.HumanReviewGate do
  @moduledoc """
  Human-review readiness checks for GitHub issues.

  This module blocks a transition to human review while the canonical open
  `aiur/<issue>` pull request has unaddressed review-thread comments. It
  composes pull request discovery, bot identity resolution, and review-thread
  classification without mutating GitHub state.
  """

  alias Aiur.GitHub.{BotIdentity, PullRequests, ResourceFetch, ResourceStore, ReviewThreads, StatePolicy, Transport}

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
  @spec verify_human_review_review_threads_clear(map(), String.t()) :: :ok | {:error, term()}
  def verify_human_review_review_threads_clear(context, state_name) do
    if StatePolicy.human_review_target_state?(state_name) do
      verify_issue_review_threads_clear(context)
    else
      :ok
    end
  end

  @doc false
  @spec verify_issue_review_threads_clear(map()) :: :ok | {:error, term()}
  def verify_issue_review_threads_clear(context) do
    case open_pull_request(context) do
      {:ok, %{"number" => pr_number}} when is_integer(pr_number) ->
        with {:ok, agent_login} <-
               BotIdentity.bot_account(context.opts, context.request_fun, context.token) do
          verify_pr_review_threads_clear(context, pr_number, agent_login)
        end

      {:ok, nil} ->
        :ok

      {:ok, _pr} ->
        :ok

      {:error, _reason} = error ->
        error
    end
  end

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

    case ResourceFetch.need(key, fetcher, freshness: ResourceFetch.decision(), reason: "merge decision: review threads") do
      {:ok, pr, _meta} -> {:ok, pr}
      {:error, _reason} = error -> error
    end
  end

  # Mirrors GitHub's own `reviewDecision`: each reviewer's latest non-COMMENTED
  # submission is their standing verdict, and the pull request is approved only
  # when at least one reviewer approves and none is still requesting changes. An
  # unreadable /reviews response fails closed to the pre-existing error.
  defp approved?(context, pr_number) do
    key = ResourceStore.key_for_repo(:pull_request_reviews, repo_full_name(), pr_number)

    # Conditional, so a strict read of an unchanged review list costs a request
    # GitHub does not bill. The validator comes from the store and the response's
    # goes back to it, which is what makes the next check free too.
    fetcher = fn opts ->
      PullRequests.fetch_pull_request_reviews_conditional(pr_number,
        request_fun: context.request_fun,
        token: context.token,
        etag: Keyword.get(opts, :etag)
      )
    end

    case ResourceFetch.need(key, fetcher, freshness: ResourceFetch.decision(), reason: "merge decision: approval state") do
      {:ok, reviews, _meta} when is_list(reviews) -> approved_decision?(standing_verdicts(reviews))
      _other -> false
    end
  end

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
    |> Enum.filter(&(get_in(&1, ["user", "login"]) != nil and Map.get(&1, "state") in ~w(APPROVED CHANGES_REQUESTED DISMISSED)))
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
