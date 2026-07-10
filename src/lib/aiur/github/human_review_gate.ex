defmodule Aiur.GitHub.HumanReviewGate do
  @moduledoc """
  Human-review readiness checks for GitHub issues.

  This module blocks a transition to human review while the canonical open
  `aiur/<issue>` pull request has unaddressed review-thread comments. It
  composes pull request discovery, bot identity resolution, and review-thread
  classification without mutating GitHub state.
  """

  alias Aiur.GitHub.{BotIdentity, PullRequests, ReviewThreads, StatePolicy, Transport}

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
    case PullRequests.fetch_open_pull_request_for_branch(context.issue_number,
           request_fun: context.request_fun,
           token: context.token
         ) do
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
        {:error,
         {:unverified_review_threads,
          %{
            issue_number: context.issue_number,
            pr_number: pr_number,
            review_thread_ids: Enum.map(comments, &Map.get(&1, "review_thread_id")) |> Enum.reject(&is_nil/1),
            comment_ids: Enum.map(comments, &Map.get(&1, "id")) |> Enum.reject(&is_nil/1),
            count: length(comments)
          }}}

      {:error, _reason} = error ->
        error
    end
  end
end
