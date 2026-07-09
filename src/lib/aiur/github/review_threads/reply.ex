defmodule Aiur.GitHub.ReviewThreads.Reply do
  @moduledoc """
  Review-thread reply mutation support.

  This module posts a reply to a GitHub pull request review thread and verifies
  that the bot-authored reply is the latest thread comment. Verification retries
  are isolated from mutation retries so a successful mutation is never posted
  twice while waiting for GitHub's read path to catch up.
  """

  require Logger
  alias Aiur.GitHub.{BotIdentity, Errors, ReviewThreads, Transport}

  @reply_review_thread_mutation """
  mutation AiurReplyReviewThread($threadId: ID!, $body: String!) {
    addPullRequestReviewThreadReply(input: {pullRequestReviewThreadId: $threadId, body: $body}) {
      comment {
        id
        databaseId
        body
        createdAt
        updatedAt
        url
        author {
          login
        }
      }
    }
  }
  """

  @spec reply_to_review_thread(String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def reply_to_review_thread(review_thread_id, body, opts \\ []) do
    with {:ok, thread_id} <- normalize_review_thread_id(review_thread_id),
         {:ok, body} <- normalize_review_thread_reply_body(body),
         {:ok, token} <- Transport.require_token(opts) do
      request_fun = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)
      attempts = normalize_positive_integer(Keyword.get(opts, :attempts), 3)

      do_reply_to_review_thread(request_fun, token, thread_id, body, attempts, opts, 1)
    end
  end

  @spec do_reply_to_review_thread(function(), String.t(), String.t(), String.t(), pos_integer(), keyword(), pos_integer()) ::
          {:ok, map()} | {:error, term()}
  def do_reply_to_review_thread(request_fun, token, thread_id, body, max_attempts, opts, attempt) do
    case add_review_thread_reply(request_fun, token, thread_id, body) do
      {:ok, mutation_body} ->
        Logger.info("GitHub review thread reply mutation response: #{inspect(mutation_body)}")

        build_review_thread_retry_context(
          request_fun,
          token,
          thread_id,
          body,
          max_attempts,
          opts,
          mutation_body
        )
        |> verify_after_review_thread_reply(attempt)

      {:error, reason} ->
        Logger.warning("GitHub review thread reply mutation failed: #{inspect(reason)}")

        if Errors.retryable_github_error?(reason) and attempt < max_attempts do
          sleep_review_thread_retry(opts, attempt)

          do_reply_to_review_thread(
            request_fun,
            token,
            thread_id,
            body,
            max_attempts,
            opts,
            attempt + 1
          )
        else
          {:error, reason}
        end
    end
  end

  @spec retry_review_thread_reply(map(), pos_integer(), term()) :: {:ok, map()} | {:error, term()}
  def retry_review_thread_reply(context, attempt, reason) do
    if retryable_review_thread_verification_error?(reason) and attempt < context.max_attempts do
      sleep_review_thread_retry(context.opts, attempt)

      verify_after_review_thread_reply(context, attempt + 1)
    else
      {:error,
       {:review_thread_reply_not_verified,
        %{
          review_thread_id: context.thread_id,
          attempts: attempt,
          reason: reason,
          mutation_response: context.mutation_body
        }}}
    end
  end

  @spec verify_after_review_thread_reply(map(), pos_integer()) :: {:ok, map()} | {:error, term()}
  def verify_after_review_thread_reply(context, attempt) do
    case verify_review_thread_reply(
           context.request_fun,
           context.token,
           context.thread_id,
           context.body,
           context.opts
         ) do
      {:ok, verification} ->
        {:ok,
         %{
           verified: true,
           review_thread_id: context.thread_id,
           attempt: attempt,
           mutation_response: context.mutation_body,
           verification: verification
         }}

      {:error, reason} ->
        retry_review_thread_reply(context, attempt, reason)
    end
  end

  @spec build_review_thread_retry_context(
          function(),
          String.t(),
          String.t(),
          String.t(),
          pos_integer(),
          keyword(),
          map()
        ) :: map()
  def build_review_thread_retry_context(
        request_fun,
        token,
        thread_id,
        body,
        max_attempts,
        opts,
        mutation_body
      ) do
    %{
      request_fun: request_fun,
      token: token,
      thread_id: thread_id,
      body: body,
      max_attempts: max_attempts,
      opts: opts,
      mutation_body: mutation_body
    }
  end

  @spec add_review_thread_reply(function(), String.t(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def add_review_thread_reply(request_fun, token, thread_id, body) do
    Transport.github_graphql(request_fun, token, @reply_review_thread_mutation, %{
      "threadId" => thread_id,
      "body" => body
    })
  end

  @spec verify_review_thread_reply(function(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def verify_review_thread_reply(request_fun, token, thread_id, body, opts) do
    case ReviewThreads.fetch_review_thread(request_fun, token, thread_id) do
      {:ok, thread_body} ->
        Logger.info("GitHub review thread reply verification response: #{inspect(thread_body)}")

        verify_latest_review_thread_comment(
          thread_body,
          thread_id,
          body,
          request_fun,
          token,
          opts
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec verify_latest_review_thread_comment(map(), String.t(), String.t(), function(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def verify_latest_review_thread_comment(thread_body, thread_id, body, request_fun, token, opts) do
    latest =
      thread_body
      |> ReviewThreads.review_thread_from_body()
      |> ReviewThreads.thread_comments()
      |> List.last()

    with {:ok, bot_account} <- BotIdentity.bot_account(opts, request_fun, token) do
      cond do
        is_nil(latest) ->
          {:error, :review_thread_latest_comment_missing}

        get_in(latest, ["author", "login"]) != bot_account ->
          latest_comment_author_mismatch(bot_account, latest)

        Map.get(latest, "body") != body ->
          latest_comment_body_mismatch(body, latest)

        true ->
          {:ok,
           %{
             "review_thread_id" => thread_id,
             "latest_comment" => ReviewThreads.normalize_verified_thread_comment(latest)
           }}
      end
    end
  end

  @spec latest_comment_author_mismatch(String.t(), map()) :: {:error, term()}
  def latest_comment_author_mismatch(bot_account, latest) do
    detail = %{
      expected: bot_account,
      actual: get_in(latest, ["author", "login"])
    }

    {:error, {:review_thread_latest_comment_author_mismatch, detail}}
  end

  @spec latest_comment_body_mismatch(String.t(), map()) :: {:error, term()}
  def latest_comment_body_mismatch(body, latest) do
    detail = %{
      expected: body,
      actual: Map.get(latest, "body")
    }

    {:error, {:review_thread_latest_comment_body_mismatch, detail}}
  end

  @spec retryable_review_thread_verification_error?(term()) :: boolean()
  def retryable_review_thread_verification_error?({:github, kind, _detail})
      when kind in [:dns, :timeout, :tls, :transport, :rate_limited],
      do: true

  def retryable_review_thread_verification_error?({:review_thread_latest_comment_author_mismatch, _}),
    do: true

  def retryable_review_thread_verification_error?({:review_thread_latest_comment_body_mismatch, _}),
    do: true

  def retryable_review_thread_verification_error?(:review_thread_latest_comment_missing),
    do: true

  def retryable_review_thread_verification_error?(_reason), do: false
  @spec sleep_review_thread_retry(keyword(), pos_integer()) :: term()
  def sleep_review_thread_retry(opts, attempt) do
    delay_ms = normalize_non_negative_integer(Keyword.get(opts, :retry_delay_ms), 250) * attempt
    sleep_fun = Keyword.get(opts, :sleep_fun, &Process.sleep/1)
    sleep_fun.(delay_ms)
  end

  @spec normalize_review_thread_id(term()) :: {:ok, String.t()} | {:error, :missing_review_thread_id}
  def normalize_review_thread_id(id) when is_binary(id) do
    case String.trim(id) do
      "" -> {:error, :missing_review_thread_id}
      trimmed -> {:ok, trimmed}
    end
  end

  def normalize_review_thread_id(_id), do: {:error, :missing_review_thread_id}

  @spec normalize_review_thread_reply_body(term()) ::
          {:ok, String.t()} | {:error, :missing_review_thread_reply_body}
  def normalize_review_thread_reply_body(body) when is_binary(body) do
    case String.trim(body) do
      "" -> {:error, :missing_review_thread_reply_body}
      _trimmed -> {:ok, body}
    end
  end

  def normalize_review_thread_reply_body(_body), do: {:error, :missing_review_thread_reply_body}
  @spec normalize_positive_integer(term(), pos_integer()) :: pos_integer()
  def normalize_positive_integer(value, _default) when is_integer(value) and value > 0, do: value
  def normalize_positive_integer(_value, default), do: default
  @spec normalize_non_negative_integer(term(), non_neg_integer()) :: non_neg_integer()
  def normalize_non_negative_integer(value, _default) when is_integer(value) and value >= 0,
    do: value

  def normalize_non_negative_integer(_value, default), do: default
end
