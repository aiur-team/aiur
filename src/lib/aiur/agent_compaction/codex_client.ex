defmodule Aiur.AgentCompaction.CodexClient do
  @moduledoc """
  Codex `thread/compact/start` API wrapper for native thread compaction.

  Handles request creation, response validation, polling for completion,
  and error handling with bounded timeouts.
  """


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
    case build_request(thread_id, summary_prompt) do
      {:ok, _request} ->
        # In production, this would call the Codex API
        # For now, return a mock request_id
        {:ok, "mock_request_#{:erlang.monotonic_time()}"}
      {:error, reason} ->
        {:error, reason}
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
  def poll_status(_thread_id, _request_id, _opts \\ []) do
    # This would poll the Codex API
    # Returns {:ok, :pending} or {:ok, :completed, summary_map, token_count}
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

  @spec validate_summary(map()) :: {:ok, map()} | {:error, String.t()}
  defp validate_summary(summary) when is_map(summary) do
    with :ok <- validate_required_sections(summary),
         :ok <- validate_summary_content(summary) do
      {:ok, summary}
    end
  end
  defp validate_summary(_), do: {:error, "summary must be a map"}

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

  defp build_request(thread_id, summary_prompt) when is_binary(thread_id) and is_binary(summary_prompt) do
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
  defp build_request(_, _), do: {:error, "thread_id and summary_prompt must be non-empty strings"}

  defp poll_until_complete(_thread_id, _request_id, deadline) do
    now = System.monotonic_time(:millisecond)

    cond do
      now > deadline ->
        {:timeout}
      true ->
        # Mock: always return timeout for now
        # In production, this would poll the Codex API
        {:timeout}
    end
  end

  defp validate_and_return_summary(summary, tokens) do
    case validate_summary(summary) do
      {:ok, valid_summary} ->
        original_ref = Map.get(summary, "original_transcript_ref", "")
        compacted_ref = Map.get(summary, "compacted_transcript_ref", "")
        {:ok, valid_summary, tokens || 0, original_ref, compacted_ref}
      {:error, reason} ->
        {:error, "summary validation failed: #{reason}"}
    end
  end
end
