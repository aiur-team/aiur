defmodule Aiur.Opencode.SessionWriter.TranscriptWrite do
  @moduledoc """
  SQLite message and part writes for `Aiur.Opencode.SessionWriter`.

  The `*_in_txn` functions run on a connection the caller already holds;
  they never open a transaction of their own.
  """

  alias Aiur.Opencode.{Db, Protocol, SessionWriter}
  alias Aiur.Opencode.SessionWriter.Parts

  @type tagged_part :: {String.t(), String.t(), map()}

  # Dispatch based on whether the event has a turn_id. Returns
  # `{:ok, message_id, parts_written, new_state}` or `{:error, reason}`.
  # parts_written is a list of `{message_id, part_id, part_data}` for the
  # caller to feed into fire_part_updates/2.
  @spec write_transcript_event(SessionWriter.t(), map()) ::
          {:ok, String.t(), [tagged_part()], SessionWriter.t()} | {:error, term()}
  def write_transcript_event(state, %{turn_id: tid} = event) when is_binary(tid) do
    case Map.fetch(state.turns, tid) do
      {:ok, turn} -> append_to_open_turn(state, turn, tid, event)
      :error -> open_turn(state, event)
    end
  end

  def write_transcript_event(state, event) do
    case write_standalone(state, event) do
      {:ok, message_id, parts} -> {:ok, message_id, parts, state}
      {:error, reason} -> {:error, reason}
    end
  end

  defp append_to_open_turn(state, %{message_id: message_id} = turn, tid, event) do
    parts = Parts.build_body_parts(event.role, event.body, event)

    write_result =
      Db.with_conn(fn conn ->
        Parts.insert_part_list(conn, state.session_id, message_id, parts)
      end)

    case write_result do
      :ok ->
        new_turn = %{turn | last_event_at_ms: System.os_time(:millisecond)}

        {:ok, message_id, Parts.tag_parts(message_id, parts), %{state | turns: Map.put(state.turns, tid, new_turn)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Open a new turn-grouped assistant message: insert the message row,
  # the step-start part, and the first body parts in a single transaction.
  # Record the open turn in state.turns.
  defp open_turn(state, %{turn_id: tid, role: role, body: body} = event) do
    message_id = Db.msg_id()
    now_ms = System.os_time(:millisecond)
    step_start_id = Db.prt_id()
    body_parts = Parts.build_body_parts(role, body, event)
    all_parts = [{step_start_id, Protocol.step_start_part_data()} | body_parts]

    write_result =
      Db.with_transaction(fn conn ->
        with :ok <-
               Db.insert_message(
                 conn,
                 state.session_id,
                 message_id,
                 Parts.build_message_data(state, role)
               ) do
          Parts.insert_part_list(conn, state.session_id, message_id, all_parts)
        end
      end)

    case write_result do
      :ok ->
        turn = %{message_id: message_id, started_at_ms: now_ms, last_event_at_ms: now_ms}

        {:ok, message_id, Parts.tag_parts(message_id, all_parts), %{state | turns: Map.put(state.turns, tid, turn)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Standalone message: message + step-start + body + step-finish in one
  # transaction. Used for turn_id=nil events and alerts.
  @spec write_standalone(SessionWriter.t(), map()) :: {:ok, String.t(), [tagged_part()]} | {:error, term()}
  def write_standalone(state, event) do
    Db.with_conn(fn conn -> write_standalone_in_txn(conn, state, event) end)
  end

  @spec write_standalone_in_txn(term(), SessionWriter.t(), map()) :: {:ok, String.t(), [tagged_part()]} | {:error, term()}
  def write_standalone_in_txn(conn, state, %{role: role, body: body} = event)
      when role in [:assistant, :command, :system, :alert, :reasoning, :tool] do
    message_id = Db.msg_id()
    finish = if role in [:command, :tool], do: "tool-calls", else: "stop"

    step_start_id = Db.prt_id()
    body_parts = Parts.build_body_parts(role, body, event)
    step_finish_id = Db.prt_id()

    all_parts =
      [{step_start_id, Protocol.step_start_part_data()}] ++
        body_parts ++
        [{step_finish_id, Protocol.step_finish_part_data(reason: finish)}]

    with :ok <-
           Db.insert_message(
             conn,
             state.session_id,
             message_id,
             Parts.build_message_data(state, role)
           ),
         :ok <- Parts.insert_part_list(conn, state.session_id, message_id, all_parts) do
      {:ok, message_id, Parts.tag_parts(message_id, all_parts)}
    end
  end

  def write_standalone_in_txn(_conn, _state, _event), do: {:error, :unsupported_role}

  # System-role standalone message — used for cross-ticket event ticker
  # rows (R2 of the chat-pane follow-ups plan). Bypasses
  # `assistant_message_data`'s `mode: build` / `agent: build` fields so
  # opencode-attach renders the row without the `▣ Build · issue-N`
  # chrome that wraps codex turn messages.
  @spec write_system_standalone(SessionWriter.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def write_system_standalone(state, body) when is_binary(body) do
    Db.with_conn(fn conn -> write_system_standalone_in_txn(conn, state, body) end)
  end

  defp write_system_standalone_in_txn(conn, state, body) do
    message_id = Db.msg_id()
    step_start_id = Db.prt_id()
    text_part_id = Db.prt_id()
    step_finish_id = Db.prt_id()

    all_parts = [
      {step_start_id, Protocol.step_start_part_data()},
      {text_part_id, Protocol.text_part_data(body)},
      {step_finish_id, Protocol.step_finish_part_data(reason: "stop")}
    ]

    with :ok <-
           Db.insert_message(
             conn,
             state.session_id,
             message_id,
             Protocol.system_message_data(%{
               identifier: state.identifier,
               parent_id: state.root_msg_id || Db.msg_id()
             })
           ),
         :ok <- Parts.insert_part_list(conn, state.session_id, message_id, all_parts) do
      {:ok, message_id}
    end
  end

  # Remote-origin user message — a genuine user-role row with a single
  # text part, the same shape opencode writes for locally-typed input.
  # No step-start/step-finish parts: those wrap assistant turns, not user
  # messages.
  @spec write_user_message(SessionWriter.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def write_user_message(state, body) when is_binary(body) do
    Db.with_conn(fn conn -> write_user_message_in_txn(conn, state, body) end)
  end

  defp write_user_message_in_txn(conn, state, body) do
    message_id = Db.msg_id()
    text_part_id = Db.prt_id()

    with :ok <-
           Db.insert_message(
             conn,
             state.session_id,
             message_id,
             Protocol.user_message_data(state.identifier)
           ),
         :ok <-
           Parts.insert_part_list(conn, state.session_id, message_id, [
             {text_part_id, Protocol.text_part_data(body)}
           ]) do
      {:ok, message_id}
    end
  end
end
