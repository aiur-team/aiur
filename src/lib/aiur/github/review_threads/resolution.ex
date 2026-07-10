defmodule Aiur.GitHub.ReviewThreads.Resolution do
  @moduledoc """
  Review-thread resolution mutation support.

  This module owns the guarded resolve/unresolve flow for GitHub pull request
  review threads. It preserves the fetch and pre-verify, resolve mutation,
  post-verify, and compensating unresolve sequence used to avoid resolving a
  thread after a reviewer has added newer feedback.
  """

  require Logger
  alias Aiur.GitHub.{BotIdentity, ReviewThreads, Transport}
  alias Aiur.GitHub.ReviewThreads.{Reply, ResolutionPolicy}

  @resolve_review_thread_mutation """
  mutation AiurResolveReviewThread($threadId: ID!) {
    resolveReviewThread(input: {threadId: $threadId}) {
      thread {
        id
        isResolved
      }
    }
  }
  """

  @unresolve_review_thread_mutation """
  mutation AiurUnresolveReviewThread($threadId: ID!) {
    unresolveReviewThread(input: {threadId: $threadId}) {
      thread {
        id
        isResolved
      }
    }
  }
  """

  @spec resolve_review_thread(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def resolve_review_thread(review_thread_id, opts \\ []) do
    with {:ok, thread_id} <- Reply.normalize_review_thread_id(review_thread_id),
         {:ok, terminal_reply_body} <-
           normalize_review_thread_terminal_reply_body(Keyword.get(opts, :terminal_reply_body)),
         {:ok, token} <- Transport.require_token(opts) do
      request_fun = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)
      do_resolve_review_thread(request_fun, token, thread_id, terminal_reply_body, opts)
    end
  end

  @spec do_resolve_review_thread(function(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def do_resolve_review_thread(request_fun, token, thread_id, terminal_reply_body, opts) do
    with {:ok, verification} <-
           verify_review_thread_resolution_ready(
             request_fun,
             token,
             thread_id,
             terminal_reply_body,
             opts
           ),
         {:ok, body} <- resolve_review_thread_mutation(request_fun, token, thread_id) do
      Logger.info("GitHub review thread resolve mutation response: #{inspect(body)}")

      case verify_resolved_review_thread(body, thread_id, verification) do
        {:ok, result} ->
          verify_review_thread_after_resolution(
            result,
            request_fun,
            token,
            thread_id,
            terminal_reply_body,
            opts
          )

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @spec verify_review_thread_after_resolution(map(), function(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def verify_review_thread_after_resolution(result, request_fun, token, thread_id, terminal_reply_body, opts) do
    case verify_review_thread_resolution_still_latest(
           request_fun,
           token,
           thread_id,
           terminal_reply_body,
           opts
         ) do
      {:ok, post_resolution_verification} ->
        {:ok, Map.put(result, :post_resolution_verification, post_resolution_verification)}

      {:error, {:post_resolution_verification_failed, reason}} ->
        unresolve_review_thread_after_post_resolution_failure(request_fun, token, thread_id, reason)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec resolve_review_thread_mutation(function(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def resolve_review_thread_mutation(request_fun, token, thread_id) do
    case Transport.github_graphql(request_fun, token, @resolve_review_thread_mutation, %{"threadId" => thread_id}) do
      {:error, {:github_graphql_errors, errors}} ->
        {:error, classify_review_thread_resolution_errors(thread_id, errors)}

      result ->
        result
    end
  end

  @spec unresolve_review_thread_mutation(function(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def unresolve_review_thread_mutation(request_fun, token, thread_id) do
    case Transport.github_graphql(request_fun, token, @unresolve_review_thread_mutation, %{"threadId" => thread_id}) do
      {:error, {:github_graphql_errors, errors}} ->
        {:error, classify_review_thread_resolution_errors(thread_id, errors)}

      result ->
        result
    end
  end

  @spec unresolve_review_thread_after_post_resolution_failure(function(), String.t(), String.t(), term()) ::
          {:error, term()}
  def unresolve_review_thread_after_post_resolution_failure(request_fun, token, thread_id, reason) do
    case unresolve_review_thread_mutation(request_fun, token, thread_id) do
      {:ok, body} ->
        Logger.info("GitHub review thread unresolve mutation response: #{inspect(body)}")

        case verify_unresolved_review_thread(body, thread_id) do
          {:ok, unresolve_verification} ->
            {:error, add_unresolve_verification(reason, unresolve_verification)}

          {:error, unresolve_reason} ->
            {:error, add_unresolve_failure(reason, unresolve_reason)}
        end

      {:error, unresolve_reason} ->
        {:error, add_unresolve_failure(reason, unresolve_reason)}
    end
  end

  @spec verify_resolved_review_thread(map(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def verify_resolved_review_thread(body, thread_id, verification) when is_map(body) do
    thread = get_in(body, ["data", "resolveReviewThread", "thread"]) || %{}

    if Map.get(thread, "isResolved") == true do
      {:ok,
       %{
         resolved: true,
         review_thread_id: Map.get(thread, "id") || thread_id,
         verification: verification,
         mutation_response: body
       }}
    else
      {:error,
       {:review_thread_not_resolved,
        %{
          review_thread_id: thread_id,
          mutation_response: body
        }}}
    end
  end

  @spec verify_unresolved_review_thread(map(), String.t()) :: {:ok, map()} | {:error, term()}
  def verify_unresolved_review_thread(body, thread_id) when is_map(body) do
    thread = get_in(body, ["data", "unresolveReviewThread", "thread"]) || %{}

    if Map.get(thread, "isResolved") == false do
      {:ok,
       %{
         review_thread_id: Map.get(thread, "id") || thread_id,
         mutation_response: body
       }}
    else
      {:error,
       {:review_thread_unresolve_failed,
        %{
          review_thread_id: thread_id,
          mutation_response: body
        }}}
    end
  end

  @spec classify_review_thread_resolution_errors(String.t(), [map()]) :: term()
  def classify_review_thread_resolution_errors(thread_id, errors) when is_list(errors) do
    if Enum.any?(errors, &review_thread_resolution_permission_error?/1) do
      {:review_thread_resolution_not_permitted,
       %{
         review_thread_id: thread_id,
         errors: errors,
         required_permission:
           "Use a GitHub token that can write pull requests for this repository, such as a fine-grained token with Pull requests: Read and write or a classic token with repo/public_repo access."
       }}
    else
      {:github_graphql_errors, errors}
    end
  end

  @spec review_thread_resolution_permission_error?(term()) :: boolean()
  def review_thread_resolution_permission_error?(error) when is_map(error) do
    typed_permission_error?(Map.get(error, "type")) or
      typed_permission_error?(get_in(error, ["extensions", "code"])) or
      known_pat_permission_message?(Map.get(error, "message"))
  end

  def review_thread_resolution_permission_error?(_error), do: false
  @spec typed_permission_error?(term()) :: boolean()
  def typed_permission_error?(value) when is_binary(value),
    do: value in ["FORBIDDEN", "INSUFFICIENT_SCOPES"]

  def typed_permission_error?(_value), do: false
  @spec known_pat_permission_message?(term()) :: boolean()
  def known_pat_permission_message?(message) when is_binary(message),
    do: String.downcase(message) == "resource not accessible by personal access token"

  def known_pat_permission_message?(_message), do: false
  @spec add_unresolve_verification(term(), map()) :: term()
  def add_unresolve_verification({type, detail}, verification) when is_map(detail) do
    {type, Map.put(detail, :unresolved_after_post_resolve_mismatch, verification)}
  end

  def add_unresolve_verification(reason, verification) do
    {reason, %{unresolved_after_post_resolve_mismatch: verification}}
  end

  @spec add_unresolve_failure(term(), term()) :: term()
  def add_unresolve_failure({type, detail}, unresolve_reason) when is_map(detail) do
    {type, Map.put(detail, :unresolve_error, unresolve_reason)}
  end

  def add_unresolve_failure(reason, unresolve_reason) do
    {reason, %{unresolve_error: unresolve_reason}}
  end

  @spec normalize_review_thread_terminal_reply_body(term()) ::
          {:ok, String.t()} | {:error, :missing_review_thread_terminal_reply_body}
  def normalize_review_thread_terminal_reply_body(body) when is_binary(body) do
    case String.trim(body) do
      "" -> {:error, :missing_review_thread_terminal_reply_body}
      _trimmed -> {:ok, body}
    end
  end

  def normalize_review_thread_terminal_reply_body(_body),
    do: {:error, :missing_review_thread_terminal_reply_body}

  @spec verify_review_thread_resolution_ready(function(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def verify_review_thread_resolution_ready(request_fun, token, thread_id, terminal_reply_body, opts) do
    case ReviewThreads.fetch_review_thread(request_fun, token, thread_id) do
      {:ok, thread_body} ->
        Logger.info("GitHub review thread resolution verification response: #{inspect(thread_body)}")

        with {:ok, bot_account} <- BotIdentity.bot_account(opts, request_fun, token) do
          ResolutionPolicy.verify_review_thread_resolution_ready(
            thread_body,
            thread_id,
            terminal_reply_body,
            bot_account,
            opts
          )
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec verify_review_thread_resolution_still_latest(function(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def verify_review_thread_resolution_still_latest(request_fun, token, thread_id, terminal_reply_body, opts) do
    case ReviewThreads.fetch_review_thread(request_fun, token, thread_id) do
      {:ok, thread_body} ->
        Logger.info("GitHub review thread post-resolution verification response: #{inspect(thread_body)}")

        with {:ok, bot_account} <- BotIdentity.bot_account(opts, request_fun, token) do
          ResolutionPolicy.verify_review_thread_resolution_still_latest(
            thread_body,
            thread_id,
            terminal_reply_body,
            bot_account,
            opts
          )
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end
