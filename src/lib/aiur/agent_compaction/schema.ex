defmodule Aiur.AgentCompaction.Schema do
  @moduledoc """
  Data schema and types for thread compaction state tracking.
  """

  @type status :: :pending | :completed | :failed | :unsupported
  @type trigger_type :: :manual | :auto_threshold

  @type t :: %{
    session_id: String.t(),
    backend: String.t(),
    trigger_type: trigger_type(),
    status: status(),
    started_at: DateTime.t() | nil,
    completed_at: DateTime.t() | nil,
    summary_tokens: non_neg_integer() | nil,
    error_reason: String.t() | nil,
    compacted_transcript_ref: String.t() | nil,
    original_transcript_ref: String.t() | nil,
    message_count_at_compaction: non_neg_integer() | nil,
    triggered_by: String.t() | nil,
    triggered_context: String.t() | nil,
    created_at: DateTime.t(),
    updated_at: DateTime.t()
  }

  @doc """
  Validate a compaction state map.
  """
  @spec validate(map()) :: {:ok, t()} | {:error, String.t()}
  def validate(state) when is_map(state) do
    with :ok <- validate_session_id(state),
         :ok <- validate_backend(state),
         :ok <- validate_trigger_type(state),
         :ok <- validate_status(state),
         :ok <- validate_timestamps(state) do
      {:ok, state}
    end
  end

  defp validate_session_id(%{session_id: id}) when is_binary(id) and id != "", do: :ok
  defp validate_session_id(_), do: {:error, "session_id must be a non-empty string"}

  defp validate_backend(%{backend: backend}) when is_binary(backend) and backend != "", do: :ok
  defp validate_backend(_), do: {:error, "backend must be a non-empty string"}

  defp validate_trigger_type(%{trigger_type: type}) when type in [:manual, :auto_threshold], do: :ok
  defp validate_trigger_type(_), do: {:error, "trigger_type must be :manual or :auto_threshold"}

  defp validate_status(%{status: status}) when status in [:pending, :completed, :failed, :unsupported], do: :ok
  defp validate_status(_), do: {:error, "status must be :pending, :completed, :failed, or :unsupported"}

  defp validate_timestamps(%{started_at: started, completed_at: completed}) do
    cond do
      started && completed && DateTime.compare(started, completed) == :gt ->
        {:error, "completed_at cannot be before started_at"}
      true ->
        :ok
    end
  end

  @doc """
  Create a new pending compaction state.
  """
  @spec new(session_id :: String.t(), backend :: String.t(), trigger :: trigger_type()) :: t()
  def new(session_id, backend, trigger_type) do
    now = DateTime.utc_now()
    %{
      session_id: session_id,
      backend: backend,
      trigger_type: trigger_type,
      status: :pending,
      started_at: now,
      completed_at: nil,
      summary_tokens: nil,
      error_reason: nil,
      compacted_transcript_ref: nil,
      original_transcript_ref: nil,
      message_count_at_compaction: nil,
      triggered_by: nil,
      triggered_context: nil,
      created_at: now,
      updated_at: now
    }
  end

  @doc """
  Mark a compaction as completed with summary details.
  """
  @spec mark_completed(t(), String.t(), String.t(), non_neg_integer()) :: t()
  def mark_completed(state, compacted_ref, original_ref, tokens) do
    %{state |
      status: :completed,
      completed_at: DateTime.utc_now(),
      compacted_transcript_ref: compacted_ref,
      original_transcript_ref: original_ref,
      summary_tokens: tokens,
      updated_at: DateTime.utc_now()
    }
  end

  @doc """
  Mark a compaction as failed with an error reason.
  """
  @spec mark_failed(t(), String.t()) :: t()
  def mark_failed(state, reason) do
    %{state |
      status: :failed,
      error_reason: reason,
      completed_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    }
  end

  @doc """
  Check if a session has unchanged compaction state (no new messages since last attempt).
  """
  @spec unchanged_since_last_compaction?(t(), non_neg_integer()) :: boolean()
  def unchanged_since_last_compaction?(%{message_count_at_compaction: last_count}, current_count)
      when is_integer(last_count) and is_integer(current_count) do
    current_count == last_count
  end
  def unchanged_since_last_compaction?(_, _), do: false
end
