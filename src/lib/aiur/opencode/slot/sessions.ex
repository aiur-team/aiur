defmodule Aiur.Opencode.Slot.Sessions do
  @moduledoc """
  Session ensure and replay for a slot.
  """

  alias Aiur.Opencode.{SessionWriter, SessionWriterRegistry}

  @replay_timeout_ms 10_000

  @doc "Ensure a session exists for `identifier` against `base_url`."
  @spec ensure(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def ensure(identifier, base_url) do
    case SessionWriterRegistry.ensure(identifier, base_url) do
      {:ok, %{session_id: session_id, writer_pid: writer_pid}} ->
        case SessionWriter.await_replay(writer_pid, @replay_timeout_ms) do
          :ok -> {:ok, session_id}
          {:error, reason} -> {:error, reason}
        end

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Ensure a session and await its replay span, returning structured results.

  Returns:
  - `{:ok, session_id}` on success
  - `{:replay_failed, reason}` when replay times out or fails
  - `{:writer_failed, err}` when the registry fails
  """
  @spec ensure_with_replay_span(String.t(), String.t(), integer()) ::
          {:ok, String.t()} | {:replay_failed, term()} | {:writer_failed, term()}
  def ensure_with_replay_span(identifier, base_url, slot_index) do
    case SessionWriterRegistry.ensure(identifier, base_url) do
      {:ok, %{session_id: session_id, writer_pid: writer_pid}} ->
        replay_span =
          Aiur.Perf.span_begin(:session_writer_await_replay,
            slot: slot_index,
            identifier: identifier,
            session_id: session_id
          )

        case SessionWriter.await_replay(writer_pid, @replay_timeout_ms) do
          :ok ->
            Aiur.Perf.span_end(replay_span,
              slot: slot_index,
              identifier: identifier,
              session_id: session_id
            )

            {:ok, session_id}

          {:error, reason} ->
            # Replay timed out or the writer disappeared. Surface as a
            # plain Slot.select error so AttachPool's warm Task can call
            # broadcast_event({:attach_failed, ...}) instead of the slot
            # crashing with MatchError and taking the warm Task with it
            # (which is what wedged 4 of 5 agents in ⏳ on 2026-05-22).
            Aiur.Perf.span_end(replay_span,
              result: :failed,
              slot: slot_index,
              identifier: identifier,
              session_id: session_id,
              reason: reason
            )

            {:replay_failed, reason}
        end

      {:error, _} = err ->
        {:writer_failed, err}
    end
  end
end
