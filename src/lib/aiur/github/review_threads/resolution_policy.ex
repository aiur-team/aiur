defmodule Aiur.GitHub.ReviewThreads.ResolutionPolicy do
  @moduledoc """
  Pure review-thread resolution policy.

  This module verifies a fetched review-thread body before and after a resolve
  mutation. It checks latest bot reply preconditions and the CODEOWNERS
  boundary for the latest non-agent reviewer comment without performing any
  transport calls.
  """

  alias Aiur.Codeowners
  alias Aiur.GitHub.ReviewThreads

  @spec verify_review_thread_resolution_ready(map(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def verify_review_thread_resolution_ready(thread_body, thread_id, terminal_reply_body, bot_account, opts) do
    verify_review_thread_resolution_latest_reply(
      thread_body,
      thread_id,
      terminal_reply_body,
      bot_account,
      nil,
      nil,
      opts
    )
  end

  @spec verify_review_thread_resolution_still_latest(map(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def verify_review_thread_resolution_still_latest(thread_body, thread_id, terminal_reply_body, bot_account, opts) do
    case verify_review_thread_resolution_latest_reply(
           thread_body,
           thread_id,
           terminal_reply_body,
           bot_account,
           nil,
           nil,
           opts,
           :after_resolve
         ) do
      {:ok, _verification} = ok -> ok
      {:error, reason} -> {:error, {:post_resolution_verification_failed, reason}}
    end
  end

  @doc false
  @spec verify_review_thread_resolution_latest_reply(
          map(),
          String.t(),
          String.t(),
          String.t(),
          term(),
          term(),
          keyword(),
          atom()
        ) :: {:ok, map()} | {:error, term()}
  def verify_review_thread_resolution_latest_reply(
        thread_body,
        thread_id,
        terminal_reply_body,
        bot_account,
        _request_fun,
        _token,
        opts,
        phase \\ :before_resolve
      ) do
    thread = ReviewThreads.review_thread_from_body(thread_body)
    latest = thread |> ReviewThreads.thread_comments() |> List.last()

    cond do
      phase == :before_resolve and Map.get(thread, "isResolved") == true ->
        {:error,
         resolution_precondition_failed(thread_id, :already_resolved, %{
           review_thread_id: thread_id
         })}

      is_nil(latest) ->
        {:error,
         resolution_precondition_failed(thread_id, resolution_reason(phase, :latest_comment_missing), %{
           review_thread_id: thread_id
         })}

      get_in(latest, ["author", "login"]) != bot_account ->
        {:error,
         resolution_precondition_failed(
           thread_id,
           resolution_reason(phase, :latest_comment_author_mismatch),
           %{
             expected: bot_account,
             actual: get_in(latest, ["author", "login"]),
             latest_comment: ReviewThreads.normalize_verified_thread_comment(latest)
           }
         )}

      Map.get(latest, "body") != terminal_reply_body ->
        {:error,
         resolution_precondition_failed(
           thread_id,
           resolution_reason(phase, :latest_comment_body_mismatch),
           %{
             expected: terminal_reply_body,
             actual: Map.get(latest, "body"),
             latest_comment: ReviewThreads.normalize_verified_thread_comment(latest)
           }
         )}

      review_thread_authoritative_comment?(thread, agent_classification_opts(bot_account, opts)) ->
        {:ok,
         %{
           "review_thread_id" => thread_id,
           "latest_comment" => ReviewThreads.normalize_verified_thread_comment(latest)
         }}

      true ->
        {:error,
         {:review_thread_resolution_not_authorized,
          %{
            review_thread_id: thread_id,
            path: Map.get(thread, "path"),
            required_boundary: "Only resolve review threads whose latest non-agent reviewer comment is authoritative for the thread path according to CODEOWNERS."
          }}}
    end
  end

  @doc false
  @spec resolution_reason(atom(), atom()) :: atom()
  def resolution_reason(:before_resolve, reason), do: reason
  def resolution_reason(:after_resolve, :latest_comment_missing), do: :post_resolve_latest_comment_missing

  def resolution_reason(:after_resolve, :latest_comment_author_mismatch),
    do: :post_resolve_latest_comment_author_mismatch

  def resolution_reason(:after_resolve, :latest_comment_body_mismatch),
    do: :post_resolve_latest_comment_body_mismatch

  @doc false
  @spec resolution_precondition_failed(String.t(), atom(), map()) :: term()
  def resolution_precondition_failed(thread_id, reason, detail) do
    {:review_thread_resolution_precondition_failed,
     detail
     |> Map.put(:review_thread_id, thread_id)
     |> Map.put(:reason, reason)}
  end

  @spec review_thread_authoritative_comment?(map(), keyword()) :: boolean()
  def review_thread_authoritative_comment?(thread, opts) when is_map(thread) do
    context =
      thread
      |> normalize_thread_for_comment_context()
      |> ReviewThreads.thread_ownership_context(opts)

    thread
    |> ReviewThreads.thread_comments()
    |> Enum.reverse()
    |> Enum.find(fn comment ->
      author = get_in(comment, ["author", "login"])
      not agent_login?(author, opts)
    end)
    |> case do
      nil ->
        false

      reviewer_comment ->
        reviewer_comment
        |> get_in(["author", "login"])
        |> Codeowners.authoritative?(context)
    end
  end

  @doc false
  @spec normalize_thread_for_comment_context(map()) :: map()
  def normalize_thread_for_comment_context(thread) do
    %{"path" => Map.get(thread, "path")}
  end

  @doc false
  @spec agent_classification_opts(String.t(), keyword()) :: keyword()
  def agent_classification_opts(bot_account, opts) do
    Keyword.update(opts, :agent_logins, [bot_account], &[bot_account | List.wrap(&1)])
  end

  @doc false
  @spec agent_login?(term(), keyword()) :: boolean()
  def agent_login?(login, opts) when is_binary(login) do
    opts
    |> Keyword.get(:agent_logins, [])
    |> List.wrap()
    |> Enum.member?(login)
  end

  def agent_login?(_login, _opts), do: false
end
