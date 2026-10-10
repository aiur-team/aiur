defmodule Aiur.GitHub.HumanReviewGate do
  @moduledoc """
  Human-review readiness checks for GitHub issues.

  This module blocks a transition to human review while the canonical open
  pull request has unaddressed review-thread comments, conflicts with its base,
  or overlaps files changed upstream at the state-write boundary. Subsequent observer
  checks verify review threads only, so base movement during review does not
  withdraw an accepted handoff. It composes pull request discovery, bot identity
  resolution, review-thread classification and base compatibility without mutating GitHub state.
  """

  alias Aiur.Config
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
        with {:ok, agent_login} <-
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

  defp verify_base_ancestry(context, %{"head" => %{"sha" => head_sha}, "number" => pr_number}, true)
       when is_binary(head_sha) and head_sha != "" do
    base = Config.base_branch(context.opts)

    case compare(context, base, head_sha) do
      {:ok, %{"status" => status}} when status in ["ahead", "identical"] ->
        :ok

      {:ok, %{"status" => status} = comparison} when status in ["behind", "diverged"] ->
        verify_stale_base(context, pr_number, base, head_sha, comparison)

      {:ok, _body} ->
        {:error, :review_base_ancestry_unavailable}

      {:error, _reason} = error ->
        error
    end
  end

  defp verify_base_ancestry(_context, _pr, true), do: {:error, :review_base_ancestry_unavailable}

  defp compare(context, base, head) do
    comparison = "#{URI.encode(base, &URI.char_unreserved?/1)}...#{URI.encode(head, &URI.char_unreserved?/1)}"
    url = "#{Transport.base_url()}/repos/#{repo_full_name()}/compare/#{comparison}?per_page=1"
    # Branch movement cannot reuse a previous compatibility verdict.
    Transport.fetch_json_map(context.request_fun, context.token, url, caller: "human_review_base_ancestry")
  end

  defp verify_stale_base(context, pr_number, base, head, comparison) do
    with {:ok, base_sha} <- comparison_base(comparison),
         {:ok, pr_files} <- changed_paths(comparison),
         {:ok, upstream} <- compare(context, head, base_sha),
         {:ok, upstream_files} <- upstream_paths(upstream),
         {:ok, mergeable?} <- current_mergeability(context, pr_number, base, head) do
      if mergeable? and MapSet.disjoint?(pr_files, upstream_files) do
        :ok
      else
        {:error, {:stale_review_base, %{pr_number: pr_number, base_branch: base, head_sha: head}}}
      end
    end
  end

  defp comparison_base(%{"base_commit" => %{"sha" => sha}}) when is_binary(sha) and sha != "", do: {:ok, sha}
  defp comparison_base(_comparison), do: {:error, :review_base_ancestry_unavailable}

  defp upstream_paths(%{"status" => status} = comparison) when status in ["ahead", "diverged"], do: changed_paths(comparison)
  defp upstream_paths(_comparison), do: {:error, :review_base_ancestry_unavailable}

  defp changed_paths(%{"files" => files}) when is_list(files) and length(files) < 300 do
    Enum.reduce_while(files, {:ok, MapSet.new()}, &add_changed_path/2)
  end

  defp changed_paths(_comparison), do: {:error, :review_base_ancestry_unavailable}

  defp add_changed_path(%{"filename" => filename} = file, {:ok, paths}) when is_binary(filename) and filename != "" do
    case {Map.get(file, "previous_filename"), Map.get(file, "status")} do
      {nil, status} when status != "renamed" -> {:cont, {:ok, MapSet.put(paths, filename)}}
      {previous, _status} when is_binary(previous) and previous != "" -> {:cont, {:ok, paths |> MapSet.put(filename) |> MapSet.put(previous)}}
      _invalid -> {:halt, {:error, :review_base_ancestry_unavailable}}
    end
  end

  defp add_changed_path(_file, _paths), do: {:halt, {:error, :review_base_ancestry_unavailable}}

  defp current_mergeability(context, pr_number, base, head) do
    query = """
    query AiurHumanReviewMergeability($owner: String!, $name: String!, $number: Int!) {
      repository(owner: $owner, name: $name) {
        pullRequest(number: $number) { headRefOid baseRefName mergeable }
      }
    }
    """

    {:ok, {owner, name}} = Transport.parse_repo()
    variables = %{"owner" => owner, "name" => name, "number" => pr_number}

    case Transport.github_graphql(context.request_fun, context.token, query, variables, caller: "human_review_base_ancestry") do
      {:ok, %{"data" => %{"repository" => %{"pullRequest" => %{"headRefOid" => ^head, "baseRefName" => ^base, "mergeable" => status}}}}}
      when status in ["MERGEABLE", "UNKNOWN"] ->
        # The pinned REST comparisons establish disjoint paths; UNKNOWN supplies no conflict signal.
        {:ok, true}

      {:ok, %{"data" => %{"repository" => %{"pullRequest" => %{"headRefOid" => ^head, "baseRefName" => ^base, "mergeable" => "CONFLICTING"}}}}} ->
        {:ok, false}

      {:ok, _body} ->
        {:error, :review_base_ancestry_unavailable}

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

  defp approved?(context, pr_number) do
    approved_pull_request?(pr_number, request_fun: context.request_fun, token: context.token) == {:ok, true}
  end

  @doc "Returns whether at least one standing review approves and none requests changes."
  @spec approved_pull_request?(String.t() | integer(), keyword()) :: {:ok, boolean()} | {:error, term()}
  def approved_pull_request?(pr_number, opts \\ []) do
    key = ResourceStore.key_for_repo(:pull_request_reviews, repo_full_name(), pr_number)

    # A strict conditional read revalidates the standing verdict with GitHub.
    fetcher = fn fetch_opts ->
      PullRequests.fetch_pull_request_reviews_conditional(pr_number, Keyword.merge(opts, fetch_opts))
    end

    case ResourceFetch.need(key, fetcher, freshness: ResourceFetch.decision(), reason: "merge decision: approval state") do
      {:ok, reviews, _meta} when is_list(reviews) -> {:ok, approved_decision?(standing_verdicts(reviews))}
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_pull_request_reviews}
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
