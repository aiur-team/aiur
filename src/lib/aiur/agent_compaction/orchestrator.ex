defmodule Aiur.AgentCompaction.Orchestrator do
  @moduledoc """
  Orchestrator logic for compaction trigger evaluation at agent handoff.

  Integrates with the handoff flow to evaluate whether compaction should fire,
  manage state transitions, and prevent repeat compaction on unchanged sessions.
  """

  require Logger

  alias Aiur.AgentCompaction.{CodexClient, Config, Schema}

  @doc """
  Evaluate whether compaction should trigger for a session at handoff.

  Returns one of:
  - `{:ok, :skipped, reason}` - compaction not applicable
  - `{:ok, :unsupported, reason}` - backend or config doesn't support compaction
  - `{:ok, :pending, state}` - compaction request submitted
  - `{:error, reason}` - blocker or error
  """
  @spec evaluate_trigger(
          session :: map(),
          backend :: String.t(),
          current_message_count :: non_neg_integer()
        ) :: {:ok, :skipped | :unsupported | :pending, Schema.t() | String.t()} | {:error, String.t()}
  def evaluate_trigger(session, backend, current_message_count) do
    cond do
      !Config.enabled?() ->
        {:ok, :unsupported, "compaction disabled in config"}

      !backend_supported?(backend) ->
        {:ok, :unsupported, "unsupported backend: #{backend}"}

      session_unchanged?(session, current_message_count) ->
        {:ok, :skipped, "no new messages since last compaction"}

      true ->
        trigger_compaction(session, backend, current_message_count)
    end
  end

  @doc """
  Evaluate threshold-based triggers for auto-compaction.

  Returns true if all thresholds are met (AND logic).
  """
  @spec threshold_met?(
          tokens :: non_neg_integer(),
          message_count :: non_neg_integer(),
          elapsed_minutes :: non_neg_integer()
        ) :: boolean()
  def threshold_met?(tokens, message_count, elapsed_minutes) do
    token_threshold = Config.token_threshold()
    message_threshold = Config.message_count_threshold()
    time_threshold = Config.elapsed_time_minutes()

    tokens >= token_threshold and
      message_count >= message_threshold and
      elapsed_minutes >= time_threshold
  end

  @doc """
  Check if a session has unchanged state (no new messages since last compaction).
  """
  @spec session_unchanged?(map(), non_neg_integer()) :: boolean()
  def session_unchanged?(session, current_count) do
    case Map.get(session, :last_compaction_state) do
      %{message_count_at_compaction: last_count} when is_integer(last_count) ->
        Schema.unchanged_since_last_compaction?(%{message_count_at_compaction: last_count}, current_count)

      _ ->
        false
    end
  end

  @doc """
  Trigger a compaction request for a session.
  """
  @spec trigger_compaction(
          session :: map(),
          backend :: String.t(),
          current_message_count :: non_neg_integer()
        ) :: {:ok, :pending, Schema.t()} | {:error, String.t()}
  def trigger_compaction(session, backend, current_message_count) do
    session_id = Map.get(session, :id) || "unknown"
    state = Schema.new(session_id, backend, :auto_threshold)
    state = %{state | message_count_at_compaction: current_message_count}

    # Submit async request to Codex
    case submit_compaction_request(session, state) do
      {:ok, _request_id} ->
        Logger.info("Compaction triggered for session session_id=#{session_id} backend=#{backend} message_count=#{current_message_count}")
        {:ok, :pending, %{state | status: :pending}}

      {:error, reason} ->
        Logger.error("Compaction request failed session_id=#{session_id} error=#{inspect(reason)}")
        {:error, "failed to submit compaction request: #{reason}"}
    end
  end

  @doc """
  Prevent duplicate in-flight compaction requests for the same session.
  """
  @spec deduplicate_request?(
          session_id :: String.t(),
          pending_requests :: map()
        ) :: boolean()
  def deduplicate_request?(session_id, pending_requests) do
    # Return true if a compaction is already pending for this session
    Map.has_key?(pending_requests, session_id)
  end

  defp backend_supported?(backend) do
    supported = Config.backends()
    Enum.member?(supported, backend)
  end

  defp submit_compaction_request(session, _state) do
    # Build summary prompt from session context
    summary_prompt = build_summary_prompt(session)
    thread_id = Map.get(session, :thread_id, "unknown")

    # Submit to Codex API
    CodexClient.request_compact(thread_id, summary_prompt, timeout_ms: Config.timeout_ms())
  end

  defp build_summary_prompt(_session) do
    """
    Summarize this thread for a code review handoff.

    Required sections:
    1. Task Constraints: The task objectives and scope from the start
    2. Decisions Made: Key implementation decisions and rationale
    3. Revision History: Code changes, refactors, or major rework cycles
    4. Validation Evidence: Test results, checks that passed or failed
    5. Remaining Review Work: What the reviewer needs to focus on

    Focus on information a human reviewer needs, not intermediate steps.
    """
  end
end
