defmodule Aiur.Codex.DynamicTool.ReviewThreads do
  @moduledoc """
  Dynamic tool handler for `aiur_reply_review_thread` and `aiur_resolve_review_thread`.
  """

  @behaviour Aiur.Codex.DynamicTool.Handler

  alias Aiur.Codex.DynamicTool.Args
  alias Aiur.Codex.DynamicTool.Errors
  alias Aiur.Codex.DynamicTool.Response
  alias Aiur.GitHub.Client, as: GitHubClient

  @reply_review_thread_description """
  Post a reply to an exact GitHub pull request review thread, then re-fetch
  that thread and verify the latest comment is the agent's reply. Returns
  success only after the read-after-write postcondition passes. This does not
  resolve the thread; use aiur_resolve_review_thread only after a terminal
  "done, no further change" reply has been verified.
  """
  @reply_review_thread_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["review_thread_id", "body"],
    "properties" => %{
      "review_thread_id" => %{
        "type" => "string",
        "description" => "GitHub PullRequestReviewThread node id, e.g. PRRT_kwD..."
      },
      "body" => %{
        "type" => "string",
        "description" => "Concise reply to post on the review thread."
      }
    }
  }
  @resolve_review_thread_description """
  Resolve an exact GitHub pull request review thread after the agent has posted
  and verified a terminal reply. The exact terminal reply body is required so
  Aiur can re-fetch the thread and confirm that reply is still latest before
  resolving. If GitHub rejects resolution because the token lacks permission,
  the tool returns an explicit not-permitted failure; the verified reply remains
  the durable done signal.
  """
  @resolve_review_thread_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["review_thread_id", "terminal_reply_body"],
    "properties" => %{
      "review_thread_id" => %{
        "type" => "string",
        "description" => "GitHub PullRequestReviewThread node id, e.g. PRRT_kwD..."
      },
      "terminal_reply_body" => %{
        "type" => "string",
        "description" =>
          "Exact body of the already-verified terminal agent reply " <>
            "that should be latest before resolving."
      }
    }
  }

  @impl true
  @spec tools() :: [String.t()]
  def tools, do: ["aiur_reply_review_thread", "aiur_resolve_review_thread"]

  @impl true
  @spec specs() :: [map()]
  def specs do
    [
      %{
        "name" => "aiur_reply_review_thread",
        "description" => @reply_review_thread_description,
        "inputSchema" => @reply_review_thread_input_schema
      },
      %{
        "name" => "aiur_resolve_review_thread",
        "description" => @resolve_review_thread_description,
        "inputSchema" => @resolve_review_thread_input_schema
      }
    ]
  end

  @impl true
  @spec execute(String.t(), term(), keyword()) :: map()
  def execute("aiur_reply_review_thread", arguments, opts) do
    review_thread_replier =
      Keyword.get(opts, :review_thread_replier, &GitHubClient.reply_to_review_thread/3)

    origin_transaction = Keyword.get(opts, :agent_comment_origin_transaction, &run_without_lock/1)
    operation_id = origin_operation_id(opts)

    with {:ok, review_thread_id, body} <- normalize_reply_review_thread_arguments(arguments),
         :ok <- begin_reply_origin(operation_id, opts),
         {:ok, response} <-
           origin_transaction.(fn ->
             reply_and_record(review_thread_replier, review_thread_id, body, operation_id, opts)
           end) do
      Response.build(true, Response.encode_payload(response))
    else
      {:error, reason} ->
        Response.failure(Errors.payload(reason))
    end
  end

  def execute("aiur_resolve_review_thread", arguments, opts) do
    review_thread_resolver =
      Keyword.get(opts, :review_thread_resolver, &GitHubClient.resolve_review_thread/2)

    with {:ok, review_thread_id, terminal_reply_body} <-
           normalize_resolve_review_thread_arguments(arguments),
         {:ok, response} <-
           review_thread_resolver.(review_thread_id, terminal_reply_body: terminal_reply_body) do
      Response.build(true, Response.encode_payload(response))
    else
      {:error, reason} ->
        Response.failure(Errors.payload(reason))
    end
  end

  @spec normalize_reply_review_thread_arguments(term()) ::
          {:ok, String.t(), String.t()} | {:error, atom()}
  def normalize_reply_review_thread_arguments(arguments) when is_map(arguments) do
    with {:ok, review_thread_id} <-
           Args.string(arguments, "review_thread_id", :missing_review_thread_id),
         {:ok, body} <-
           Args.string(arguments, "body", :missing_review_thread_body) do
      {:ok, review_thread_id, body}
    end
  end

  def normalize_reply_review_thread_arguments(_arguments),
    do: {:error, :invalid_review_thread_reply_arguments}

  @spec normalize_resolve_review_thread_arguments(term()) ::
          {:ok, String.t(), String.t()} | {:error, atom()}
  def normalize_resolve_review_thread_arguments(arguments) when is_map(arguments) do
    with {:ok, review_thread_id} <-
           Args.string(arguments, "review_thread_id", :missing_review_thread_id),
         {:ok, terminal_reply_body} <-
           Args.string(
             arguments,
             "terminal_reply_body",
             :missing_review_thread_terminal_reply_body
           ) do
      {:ok, review_thread_id, terminal_reply_body}
    end
  end

  def normalize_resolve_review_thread_arguments(_arguments),
    do: {:error, :invalid_review_thread_resolution_arguments}

  defp record_verified_reply_origin(response, operation_id, opts) do
    if origin_recorder_configured?(opts) do
      with {:ok, published_comment} <- published_comment(response) do
        record_reply_origin(published_comment, operation_id, opts)
      end
    else
      :ok
    end
  end

  defp reply_and_record(review_thread_replier, review_thread_id, body, operation_id, opts) do
    case review_thread_replier.(review_thread_id, body, []) do
      {:ok, response} ->
        with :ok <- record_verified_reply_origin(response, operation_id, opts), do: {:ok, response}

      {:error, reason} ->
        case record_failed_reply_origin(reason, operation_id, opts) do
          :ok -> {:error, reason}
          {:error, _origin_reason} = error -> error
        end
    end
  end

  defp run_without_lock(fun), do: fun.()

  defp published_comment(response) when is_map(response) do
    comment = Map.get(response, :published_comment) || Map.get(response, "published_comment")

    if is_map(comment), do: {:ok, comment}, else: {:error, :published_comment_missing}
  end

  defp published_comment(_response), do: {:error, :published_comment_missing}

  defp record_failed_reply_origin({:review_thread_reply_not_verified, details}, operation_id, opts)
       when is_map(details) do
    case Map.get(details, :published_comment) || Map.get(details, "published_comment") do
      %{} = comment -> record_reply_origin(comment, operation_id, opts)
      _ -> :ok
    end
  end

  # A transport failure after request dispatch is ambiguous: GitHub can have
  # committed the reply even though the client did not receive its identity.
  # Preserve durable intent for bounded reconciliation rather than allowing a
  # later poller to classify that reply as trusted external feedback.
  defp record_failed_reply_origin(_reason, _operation_id, _opts), do: :ok

  defp record_reply_origin(comment, operation_id, opts) when is_map(comment) do
    case Keyword.get(opts, :agent_comment_origin_complete) do
      complete when is_function(complete, 2) ->
        case complete.(operation_id, comment) do
          :ok -> :ok
          {:error, reason} -> {:error, {:agent_comment_origin_not_recorded, reason}}
          other -> {:error, {:agent_comment_origin_not_recorded, other}}
        end

      _no_ticket_bound_completer ->
        record_reply_origin_with_recorder(comment, opts)
    end
  end

  defp record_reply_origin(_comment, _operation_id, _opts),
    do: {:error, {:agent_comment_origin_not_recorded, :published_comment_missing}}

  defp record_reply_origin_with_recorder(comment, opts) do
    case Keyword.get(opts, :agent_comment_origin_recorder) do
      recorder when is_function(recorder, 1) ->
        case recorder.(comment) do
          :ok -> :ok
          {:error, reason} -> {:error, {:agent_comment_origin_not_recorded, reason}}
          other -> {:error, {:agent_comment_origin_not_recorded, other}}
        end

      _no_ticket_bound_recorder ->
        :ok
    end
  end

  defp begin_reply_origin(operation_id, opts) do
    case Keyword.get(opts, :agent_comment_origin_begin) do
      begin_origin when is_function(begin_origin, 1) -> begin_origin.(operation_id)
      _no_ticket_bound_begin -> :ok
    end
  end

  defp origin_operation_id(opts) do
    case Keyword.get(opts, :agent_comment_origin_operation_id) do
      id when is_binary(id) and id != "" -> id
      id when is_integer(id) -> Integer.to_string(id)
      _other -> "review-thread-#{System.unique_integer([:positive])}"
    end
  end

  defp origin_recorder_configured?(opts) do
    is_function(Keyword.get(opts, :agent_comment_origin_complete), 2) or
      is_function(Keyword.get(opts, :agent_comment_origin_recorder), 1)
  end
end
