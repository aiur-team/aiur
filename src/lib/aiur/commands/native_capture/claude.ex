defmodule Aiur.Commands.NativeCapture.Claude do
  @moduledoc "Version-gated Claude native questions using the shared Command hold lifecycle."
  alias Aiur.AppServer.{Messages, NativeReplies}
  alias Aiur.Claude.CodingAgent
  alias Aiur.Codex.UserInputAnswers
  alias Aiur.Commands.NativeCapture.Request
  alias Aiur.Config

  @spec handle(map(), map(), term(), map(), String.t()) :: {:continue, map()} | {:error, term()}
  def handle(session, state, id, params, _raw) do
    if enabled?(session, state), do: capture(session, state, id, params), else: unavailable(session, state, id, params)
  end

  defp enabled?(session, state) do
    Config.decisions_native_capture?(:claude) and
      get_in(session, [:native_question_capability, :native_question]) == :deferred and
      is_nil(Map.get(state, :pause_request_id)) and
      not Aiur.PauseContainment.paused?(Map.get(session, :containment))
  end

  defp capture(session, state, id, params) do
    case Request.capture(session.port, id, params, context(session, state), :claude) do
      {:held, ref, info} ->
        Messages.emit_message(state.on_message, :native_question_held, Map.take(info, [:decision_id, :native_ref, :since]), session.metadata)
        state = Map.update(state, :held_native_questions, %{ref => info}, &Map.put(&1, ref, info))
        {:continue, NativeReplies.deliver(session, state)}

      :approved ->
        {:continue, state}

      {:error, reason} ->
        {:error, reason}

      _policy_or_invalid ->
        unavailable(session, state, id, params)
    end
  end

  defp context(session, state) do
    session_ref = "#{session.thread_id}-#{state.current_turn_id}"

    Map.merge(Map.take(session, [:store, :workspace]), %{
      tool_call_thread_id: session.thread_id,
      turn_id: state.current_turn_id,
      ticket: state.issue,
      session_ref: session_ref,
      source: %{session_id: session_ref},
      send_response: &CodingAgent.send_frame/2
    })
  end

  defp unavailable(session, state, id, params) do
    frame =
      case UserInputAnswers.unavailable_answers(params) do
        {:ok, answers} -> %{"id" => id, "result" => %{"answers" => answers}}
        :error -> %{"id" => id, "error" => %{"code" => -32_602, "message" => "Invalid native question parameters"}}
      end

    case CodingAgent.send_frame(session.port, frame) do
      :ok -> {:continue, state}
      {:error, reason} -> {:error, reason}
    end
  end
end
