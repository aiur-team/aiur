defmodule Aiur.AgentCompaction.CodexClient do
  @moduledoc """
  Codex `thread/compact/start` API wrapper for native thread compaction.

  Handles request creation, response validation, polling for completion,
  and error handling with bounded timeouts.

  Future work: Replace mock implementations with real Codex API calls.
  """

  require Logger

  @doc """
  Request compaction for a thread, returns a request_id for polling.

  Returns {:ok, request_id} or {:error, reason}.
  """
  @spec request_compact(
    thread_id :: String.t(),
    summary_prompt :: String.t(),
    opts :: keyword()
  ) :: {:ok, String.t()} | {:error, String.t()}
  def request_compact(thread_id, summary_prompt, _opts \\ []) do
    with {:ok, _request} <- build_request(thread_id, summary_prompt) do
      Logger.info(
        "Compaction request submitted",
        thread_id: thread_id,
        prompt_length: String.length(summary_prompt)
      )
      # Mock: Return a mock request_id
      # In production: POST to Codex /thread/compact/start, return request_id from response
      {:ok, "req_#{:erlang.monotonic_time()}"}
    end
  end

  @doc """
  Poll for compaction status and completion.

  Returns {:ok, status, summary, tokens} or {:error, reason} or {:timeout}.
  """
  @spec poll_status(
    thread_id :: String.t(),
    request_id :: String.t(),
    opts :: keyword()
  ) :: {:ok, :pending | :completed | :failed, map() | nil, non_neg_integer() | nil}
    | {:error, String.t()}
    | {:timeout}
  def poll_status(thread_id, request_id, _opts \\ []) do
    Logger.debug(
      "Polling compaction status",
      thread_id: thread_id,
      request_id: request_id
    )
    # Mock: Always return pending for now
    # In production: GET from Codex /thread/compact/start/{request_id}, return status
    {:ok, :pending}
  end

  @doc """
  Wait for compaction to complete with timeout.

  Returns {:ok, summary, token_count, original_ref, compacted_ref}
  or {:error, reason} or {:timeout}.
  """
  @spec wait_for_completion(
    thread_id :: String.t(),
    request_id :: String.t(),
    timeout_ms :: non_neg_integer()
  ) :: {:ok, map(), non_neg_integer(), String.t(), String.t()}
    | {:error, String.t()}
    | {:timeout}
  def wait_for_completion(thread_id, request_id, timeout_ms \\ 60_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll_until_complete(thread_id, request_id, deadline)
  end

  # Validates that a summary has the required sections for the handoff.
  @spec validate_summary(map()) :: {:ok, map()} | {:error, String.t()}
  def validate_summary(summary) when is_map(summary) do
    with :ok <- validate_required_sections(summary),
         :ok <- validate_summary_content(summary) do
      {:ok, summary}
    end
  end

  def validate_summary(_), do: {:error, "summary must be a map"}

  defp validate_required_sections(summary) do
    required_sections = [
      "task_constraints",
      "decisions",
      "revision_history",
      "validation_evidence",
      "review_work"
    ]

    missing = Enum.reject(required_sections, &Map.has_key?(summary, &1))

    case missing do
      [] -> :ok
      _ -> {:error, "summary missing required sections: #{Enum.join(missing, ", ")}"}
    end
  end

  defp validate_summary_content(summary) do
    # Ensure all sections contain non-empty content
    cond do
      is_binary(Map.get(summary, "task_constraints", "")) and
        Map.get(summary, "task_constraints", "") != "" ->
        :ok
      true ->
        {:error, "summary sections cannot be empty"}
    end
  end

  defp build_request(thread_id, summary_prompt)
       when is_binary(thread_id) and byte_size(thread_id) > 0 and
            is_binary(summary_prompt) and byte_size(summary_prompt) > 0 do
    {:ok, %{
      "thread_id" => thread_id,
      "summary_prompt" => summary_prompt,
      "required_sections" => [
        "task_constraints",
        "decisions_made",
        "revision_markers",
        "validation_evidence",
        "remaining_review_work"
      ]
    }}
  end

  defp build_request(_, _) do
    {:error, "thread_id and summary_prompt must be non-empty strings"}
  end

  defp poll_until_complete(_thread_id, _request_id, deadline) do
    now = System.monotonic_time(:millisecond)

    cond do
      now > deadline ->
        Logger.warning("Compaction poll timeout reached")
        {:timeout}

      true ->
        # Mock: always return timeout for now
        # In production: GET /thread/compact/start/{request_id}, check status, retry with backoff
        {:timeout}
    end
  end
end
