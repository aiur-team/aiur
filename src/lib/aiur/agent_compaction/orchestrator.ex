defmodule Aiur.AgentCompaction.Orchestrator do
  @moduledoc """
  Orchestrator logic for compaction trigger evaluation at agent handoff.

  Evaluates configured Codex support and sends the native request over the
  still-live app-server port at terminal handoff.
  """

  require Logger

  alias Aiur.AgentCompaction.{CodexClient, Config, Schema}

  @doc """
  Evaluate whether compaction should trigger for a session at handoff.

  Returns one of:
  - `{:ok, :skipped, reason}` - compaction not applicable
  - `{:ok, :unsupported, reason}` - backend or config doesn't support compaction
  - `{:ok, :completed, state}` - compaction request completed
  - `{:error, reason}` - blocker or error
  """
  @spec evaluate_trigger(
          session :: map(),
          backend :: String.t(),
          current_message_count :: non_neg_integer()
        ) :: {:ok, :skipped | :unsupported | :completed, Schema.t() | String.t()} | {:error, String.t()}
  def evaluate_trigger(session, backend, current_message_count) do
    cond do
      !backend_supported?(backend) ->
        {:ok, :unsupported, "unsupported backend: #{backend}"}

      !Config.enabled?() ->
        {:ok, :skipped, "compaction disabled in config"}

      session_has_compacted?(session) ->
        {:ok, :skipped, "this Codex session has already been compacted"}

      session_unchanged?(session, current_message_count) ->
        {:ok, :skipped, "no new messages since last compaction"}

      true ->
        trigger_compaction(session, backend, current_message_count)
    end
  end

  @doc false
  @spec supported_backend?(String.t()) :: boolean()
  def supported_backend?(backend), do: backend == "codex" and "codex" in Config.backends()

  @doc false
  def already_compacted?(%{compacted_at: compacted_at}) when not is_nil(compacted_at), do: true
  def already_compacted?(_session), do: false

  @doc false
  def already_attempted_for_thread?(%{"thread_id" => thread_id, "status" => status}, thread_id)
      when status in ["pending", "completed", "failed", "unsupported"],
      do: true

  def already_attempted_for_thread?(_, _thread_id), do: false

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
        ) :: {:ok, :completed, Schema.t()} | {:error, String.t()}
  def trigger_compaction(session, backend, current_message_count, opts \\ []) do
    session_id = Map.get(session, :id) || "unknown"
    state = Schema.new(session_id, backend, :manual)
    state = %{state | message_count_at_compaction: current_message_count}

    # Compact synchronously before the runner tears down the app-server port.
    case submit_compaction_request(session, state, opts) do
      {:ok, completion} ->
        Logger.info("Compaction completed for session session_id=#{session_id} backend=#{backend} turn_count=#{current_message_count}")
        {:ok, :completed, %{state | status: :completed, compacted_transcript_ref: completion.turn_id, original_transcript_ref: Map.get(session, :thread_id)}}

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

  defp backend_supported?(backend), do: supported_backend?(backend)

  defp session_has_compacted?(session), do: already_compacted?(session)

  defp submit_compaction_request(%{port: port, thread_id: thread_id}, _state, opts) when is_port(port) and is_binary(thread_id) do
    CodexClient.request_compact(port, thread_id, Keyword.merge([timeout_ms: Config.timeout_ms()], opts))
  end

  defp submit_compaction_request(_session, _state, _opts), do: {:error, "live Codex session is unavailable"}
end
