defmodule Aiur.GitHub.ReviewThreads.ResolutionPolicy do
  @moduledoc """
  Pure review-thread resolution policy.

  This module verifies a fetched review-thread body before and after a resolve
  mutation. It checks latest bot reply preconditions and the CODEOWNERS
  boundary for the latest non-agent reviewer comment without performing any
  transport calls.
  """

  alias Aiur.Codeowners
  alias Aiur.GitHub.Config
  alias Aiur.GitHub.ReviewThreads

  @spec verify_review_thread_resolution_ready(map(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def verify_review_thread_resolution_ready(thread_body, thread_id, terminal_reply_body, daemon_account, opts) do
    verify_review_thread_resolution_latest_reply(
      thread_body,
      thread_id,
      terminal_reply_body,
      daemon_account,
      nil,
      nil,
      opts
    )
  end

  @spec verify_review_thread_resolution_still_latest(map(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def verify_review_thread_resolution_still_latest(thread_body, thread_id, terminal_reply_body, daemon_account, opts) do
    case verify_review_thread_resolution_latest_reply(
           thread_body,
           thread_id,
           terminal_reply_body,
           daemon_account,
           nil,
           nil,
           opts,
           :after_resolve
         ) do
      {:ok, _verification} = ok -> ok
      {:error, reason} -> {:error, {:post_resolution_verification_failed, reason}}
    end
  end

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
        daemon_account,
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

      get_in(latest, ["author", "login"]) != daemon_account ->
        {:error,
         resolution_precondition_failed(
           thread_id,
           resolution_reason(phase, :latest_comment_author_mismatch),
           %{
             expected: daemon_account,
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

      true ->
        verify_review_thread_authority(
          thread,
          latest,
          thread_id,
          agent_classification_opts(daemon_account, opts)
        )
    end
  end

  defp verify_review_thread_authority(thread, latest, thread_id, opts) do
    case review_thread_authority(thread, opts) do
      {:ok, true} ->
        {:ok,
         %{
           "review_thread_id" => thread_id,
           "latest_comment" => ReviewThreads.normalize_verified_thread_comment(latest)
         }}

      {:ok, false} ->
        {:error,
         {:review_thread_resolution_not_authorized,
          %{
            review_thread_id: thread_id,
            path: Map.get(thread, "path"),
            required_boundary: "Only resolve review threads whose latest non-agent reviewer comment is authoritative for the thread path according to CODEOWNERS."
          }}}

      {:error, reason} ->
        {:error,
         {:review_thread_resolution_ownership_unavailable,
          %{
            review_thread_id: thread_id,
            path: Map.get(thread, "path"),
            reason: reason
          }}}
    end
  end

  @spec resolution_reason(atom(), atom()) :: atom()
  def resolution_reason(:before_resolve, reason), do: reason
  def resolution_reason(:after_resolve, :latest_comment_missing), do: :post_resolve_latest_comment_missing

  def resolution_reason(:after_resolve, :latest_comment_author_mismatch),
    do: :post_resolve_latest_comment_author_mismatch

  def resolution_reason(:after_resolve, :latest_comment_body_mismatch),
    do: :post_resolve_latest_comment_body_mismatch

  @spec resolution_precondition_failed(String.t(), atom(), map()) :: term()
  def resolution_precondition_failed(thread_id, reason, detail) do
    {:review_thread_resolution_precondition_failed,
     detail
     |> Map.put(:review_thread_id, thread_id)
     |> Map.put(:reason, reason)}
  end

  @spec review_thread_authoritative_comment?(map(), keyword()) :: boolean()
  def review_thread_authoritative_comment?(thread, opts) when is_map(thread) do
    review_thread_authority(thread, opts) == {:ok, true}
  end

  defp review_thread_authority(thread, opts) do
    reviewer_comment =
      thread
      |> ReviewThreads.thread_comments()
      |> Enum.reverse()
      |> Enum.find(fn comment ->
        author = get_in(comment, ["author", "login"])
        not agent_login?(author, opts)
      end)

    if reviewer_comment do
      context =
        thread
        |> normalize_thread_for_comment_context()
        |> ReviewThreads.thread_ownership_context(opts)

      authoritative_reviewer_comment(reviewer_comment, context)
    else
      {:ok, false}
    end
  end

  defp authoritative_reviewer_comment(_reviewer_comment, {:error, reason}), do: {:error, reason}

  defp authoritative_reviewer_comment(reviewer_comment, context) do
    authoritative =
      reviewer_comment
      |> get_in(["author", "login"])
      |> Codeowners.authoritative?(context)

    {:ok, authoritative == true}
  end

  @spec normalize_thread_for_comment_context(map()) :: map()
  def normalize_thread_for_comment_context(thread) do
    %{"path" => Map.get(thread, "path")}
  end

  @doc """
  Adds every login Aiur itself writes under to `:agent_logins`.

  Unlike `Aiur.GitHub.HumanReviewGate`, this path never reaches
  `Aiur.GitHub.BotIdentity.codeowners_classification_opts/1`, so the union has
  to happen here. It matters because `review_thread_authority/2` treats the
  last comment that is *not* in this list as the reviewer's: with one login
  listed, a comment Aiur wrote under the other would be classified as a
  reviewer's and checked for CODEOWNERS authority it never had.

  `daemon_account` is the login already resolved for the authorship check;
  `Aiur.GitHub.Config.bot_account/0` supplies the agent side. They collapse to
  one entry on a single-identity install.
  """
  @spec agent_classification_opts(String.t(), keyword()) :: keyword()
  def agent_classification_opts(daemon_account, opts) do
    aiur_logins =
      [daemon_account, Keyword.get_lazy(opts, :bot_account, &configured_bot_account/0)]
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq_by(&String.downcase/1)

    Keyword.update(opts, :agent_logins, aiur_logins, &(aiur_logins ++ List.wrap(&1)))
  end

  # This module is otherwise pure, and a config read can raise (settings
  # unavailable) or exit (a `WorkflowStore` call timing out). Degrading to "no
  # agent-side login" reproduces the pre-split classification rather than
  # failing a resolution check on a transient config read — the same posture
  # `Aiur.GitHub.CredentialRegistry` takes for the same two failure modes.
  defp configured_bot_account do
    Config.bot_account()
  rescue
    _unavailable -> nil
  catch
    :exit, _reason -> nil
  end

  @spec agent_login?(term(), keyword()) :: boolean()
  def agent_login?(login, opts) when is_binary(login) do
    opts
    |> Keyword.get(:agent_logins, [])
    |> List.wrap()
    |> Enum.member?(login)
  end

  def agent_login?(_login, _opts), do: false
end
