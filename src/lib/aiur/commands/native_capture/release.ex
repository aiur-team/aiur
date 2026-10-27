defmodule Aiur.Commands.NativeCapture.Release do
  @moduledoc "Releases held native requests without closing their Commands."

  require Logger
  alias Aiur.AppServer.Messages
  alias Aiur.Commands.NativeCapture
  alias Aiur.DecisionStore

  @spec release(map(), map(), atom()) :: map()
  def release(session, state, reason) do
    if map_size(Map.get(state, :held_native_questions, %{})) == 0 do
      state
    else
      writer = fn frame -> state.backend.send_frame(session.port, frame) end
      release_all(Map.put(state, :native_release_store, Map.get(session, :store, DecisionStore)), reason, writer)
    end
  end

  @spec release_all(map(), atom(), (map() -> :ok | {:error, term()})) :: map()
  def release_all(state, reason, writer) do
    Enum.each(Map.get(state, :held_native_questions, %{}), fn {_ref, info} ->
      released_reason = write_release(state, info, reason, writer)
      data = %{native_ref: info.native_ref, reason: released_reason, at: DateTime.utc_now()}
      record(state, info, data, Map.get(state, :native_release_store, DecisionStore))
      Messages.emit_message(Map.get(state, :on_message, &Messages.default_on_message/1), :native_question_resolved, Map.put(data, :decision_id, info.decision_id), %{})
    end)

    Map.put(state, :held_native_questions, %{})
  end

  defp write_release(_state, _info, :session_gone, _writer), do: :session_gone

  defp write_release(state, info, reason, writer) do
    text = NativeCapture.release_text(info.decision_id)
    answers = Map.new(info.question_ids, &{&1, %{"answers" => [text]}})

    case writer.(%{"id" => info.request_id, "result" => %{"answers" => answers}}) do
      :ok ->
        reason

      {:error, error} ->
        warn(state, info, :write_failed, error)
        :session_gone
    end
  end

  defp record(state, info, data, store) do
    Task.start(fn ->
      case record_fact(info.decision_id, data, store) do
        {:ok, _result} -> :ok
        {:error, error} -> warn(state, info, :record_failed, error)
      end
    end)
  end

  defp warn(state, info, phase, error) do
    issue = Map.get(state, :issue, %{})

    Logger.warning(
      "native_release phase=#{phase} decision_id=#{info.decision_id} issue_id=#{Map.get(issue, :id)} " <>
        "issue_identifier=#{Map.get(state, :issue_identifier)} session_id=#{Map.get(info, :thread_id)}-#{Map.get(info, :turn_id)} reason=#{Aiur.Signal.reason_class(error)}"
    )
  end

  defp record_fact(id, data, store) do
    DecisionStore.record_command_fact(id, :native_released, data, server: store)
  catch
    :exit, reason -> {:error, reason}
  end
end
