defmodule Aiur.AppServer.NativeReplies do
  @moduledoc false

  alias Aiur.AppServer.Messages
  alias Aiur.Commands.NativeCapture.Codex

  @spec deliver(map(), map()) :: map()
  def deliver(session, state) do
    callback = Map.get(state, :on_native_reply, fn _ -> :none end)

    case callback.(Map.keys(state.held_native_questions)) do
      {:reply, ref, answers, on_success, on_failure} ->
        reply(session, state, ref, answers, on_success, on_failure)

      :none ->
        state
    end
  end

  defp reply(session, state, ref, answers, on_success, on_failure) do
    info = Map.fetch!(state.held_native_questions, ref)

    case Codex.reply(session.port, info.request_id, answers) do
      :ok ->
        Messages.emit_message(state.on_message, :native_question_resolved, %{native_ref: ref, decision_id: info.decision_id, reason: :answered}, session.metadata)
        on_success.(%{provider: :native_reply, native_ref: ref})
        next = %{state | held_native_questions: Map.delete(state.held_native_questions, ref)}
        if map_size(next.held_native_questions) > 0, do: deliver(session, next), else: next

      {:error, reason} ->
        on_failure.(reason)
        state
    end
  end
end
