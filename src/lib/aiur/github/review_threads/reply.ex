defmodule Aiur.GitHub.ReviewThreads.Reply do
  @moduledoc """
  Review-thread reply mutation support.

  This module posts a reply to a GitHub pull request review thread and verifies
  that the bot-authored reply is the latest thread comment. Verification retries
  are isolated from mutation retries so a successful mutation is never posted
  twice while waiting for GitHub's read path to catch up.
  """

  require Logger
  alias Aiur.GitHub.{BotIdentity, Errors, ReviewThreads, Transport, WriteThrough}

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

  @reconcile_skew_seconds 5

  @spec do_reply_to_review_thread(
          function(),
          String.t(),
          String.t(),
          String.t(),
          pos_integer(),
          keyword(),
          pos_integer()
        ) ::
          {:ok, map()} | {:error, term()}
  def do_reply_to_review_thread(request_fun, token, thread_id, body, max_attempts, opts, attempt) do
    # Taken once for the whole reply so a retry's reconcile still sees an
    # earlier attempt's applied post.
    started_at = Keyword.get_lazy(opts, :reply_started_at, &DateTime.utc_now/0)
    opts = Keyword.put(opts, :reply_started_at, started_at)

    case add_review_thread_reply(request_fun, token, thread_id, body) do
      {:ok, mutation_body} ->
        Logger.info("GitHub review thread reply mutation response: #{inspect(mutation_body)}")

        # The mutation selects the reply's `databaseId`, which is the same id
        # the `pull_request_review_comment` delivery carries — so depositing it
        # here is what makes Aiur's own reply arrive in the store before its
        # webhook does, and stops that webhook waking anyone for it.
        WriteThrough.pr_review_comment(replied_comment(mutation_body))

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

        case reconcile_unknown_reply(reason, request_fun, token, thread_id, body, opts, started_at) do
          :retry -> retry_review_thread_reply_mutation(reason, request_fun, token, thread_id, body, max_attempts, opts, attempt)
          other -> other
        end
    end
  end

  defp retry_review_thread_reply_mutation(reason, request_fun, token, thread_id, body, max_attempts, opts, attempt) do
    if Errors.retryable_github_error?(reason) and attempt < max_attempts do
      sleep_review_thread_retry(opts, attempt)
      do_reply_to_review_thread(request_fun, token, thread_id, body, max_attempts, opts, attempt + 1)
    else
      {:error, reason}
    end
  end

  # A post whose outcome is unknown (deadline, timeout after send) may have been
  # applied. Read the thread before retrying; never post blindly (github-b-03).
  defp reconcile_unknown_reply(reason, request_fun, token, thread_id, body, opts, started_at) do
    with :unknown <- Errors.outcome({:error, reason}),
         {:ok, daemon_account} <- BotIdentity.daemon_account(opts, request_fun, token),
         {:ok, thread_body} <- ReviewThreads.fetch_review_thread(request_fun, token, thread_id) do
      applied =
        thread_body
        |> ReviewThreads.review_thread_from_body()
        |> ReviewThreads.thread_comments()
        |> Enum.find(&applied_reply?(&1, daemon_account, body, started_at))

      if applied do
        {:ok,
         %{
           verified: true,
           reconciled: true,
           review_thread_id: thread_id,
           verification: %{
             "review_thread_id" => thread_id,
             "latest_comment" => ReviewThreads.normalize_verified_thread_comment(applied)
           }
         }}
      else
        :retry
      end
    else
      # Definite failure or held: today's retry behaviour.
      outcome when outcome in [:held, :failed] -> :retry
      {:error, _read_failure} -> {:error, reason}
    end
  end

  defp applied_reply?(comment, daemon_account, body, started_at) do
    with true <- get_in(comment, ["author", "login"]) == daemon_account,
         true <- comment["body"] == body,
         {:ok, created_at, _offset} <- DateTime.from_iso8601(to_string(comment["createdAt"])) do
      # createdAt has second precision and GitHub's clock may skew: truncate and
      # allow a margin. An identical body from the bot in that window is the
      # duplicate we are avoiding.
      floor = started_at |> DateTime.truncate(:second) |> DateTime.add(-@reconcile_skew_seconds)
      DateTime.compare(created_at, floor) != :lt
    else
      _ -> false
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

  # Matched rather than dug out with `get_in/2`, which raises on an unexpected
  # intermediate shape — a mutation that already succeeded must never be
  # reported as failed because its response did not look the way we guessed.
  defp replied_comment(%{"data" => %{"addPullRequestReviewThreadReply" => %{"comment" => %{} = comment}}}),
    do: comment

  defp replied_comment(_mutation_body), do: nil

  @spec add_review_thread_reply(function(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def add_review_thread_reply(request_fun, token, thread_id, body) do
    Transport.github_graphql(
      request_fun,
      token,
      @reply_review_thread_mutation,
      %{"threadId" => thread_id, "body" => body},
      caller: :review_thread_reply
    )
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

  @spec verify_latest_review_thread_comment(
          map(),
          String.t(),
          String.t(),
          function(),
          String.t(),
          keyword()
        ) ::
          {:ok, map()} | {:error, term()}
  def verify_latest_review_thread_comment(thread_body, thread_id, body, request_fun, token, opts) do
    latest =
      thread_body
      |> ReviewThreads.review_thread_from_body()
      |> ReviewThreads.thread_comments()
      |> List.last()

    # `token` is the credential that wrote the reply being verified, so the
    # expected author is the login that credential writes as. Under GitHub App
    # auth that is the App bot, not the account agents publish under.
    with {:ok, daemon_account} <- BotIdentity.daemon_account(opts, request_fun, token) do
      cond do
        is_nil(latest) ->
          {:error, :review_thread_latest_comment_missing}

        get_in(latest, ["author", "login"]) != daemon_account ->
          latest_comment_author_mismatch(daemon_account, latest)

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
  # The transient `{:github, ...}` verdicts route through the shared classifier
  # in `Aiur.GitHub.Errors` so the transient/permanent list lives in exactly one
  # place (#2427). Thread-specific read-path races below are retryable on top of
  # that.
  def retryable_review_thread_verification_error?({:github, _kind, _detail} = reason),
    do: Errors.retryable_github_error?(reason)

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

  @spec normalize_review_thread_id(term()) ::
          {:ok, String.t()} | {:error, :missing_review_thread_id}
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
