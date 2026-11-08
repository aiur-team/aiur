defmodule VoiceConverse.Session.ClientInput do
  @moduledoc false

  def handle_cast({:audio, audio}, state, _event) when is_binary(audio),
    do: {:noreply, VoiceConverse.Session.Runtime.enqueue_audio(self(), state, audio, 8)}

  def handle_cast({:client_text, _} = message, %{interrupted_turn: pending} = state, _) when not is_nil(pending),
    do: {:noreply, update_in(state.timing_deferred, &[{:"$gen_cast", message} | &1])}

  def handle_cast({:client_text, text}, state, event) do
    if send_text(state, text) == :ok,
      do: event.(%VoiceConverse.Events.UserTranscript{text: text, final?: true}, state),
      else: {:noreply, state}
  end

  def handle_cast({:playback_state, status}, state, _) when status in ["playing", "stopped"],
    do: {:noreply, Map.put(state, :playback_state, status)}

  def handle_cast(_, state, _), do: {:noreply, state}

  defp send_text(%{provider_ref: nil}, _text), do: {:error, :not_ready}

  defp send_text(state, text) when is_binary(text) and byte_size(text) in 1..16_384 do
    state.provider.send_user_text(state.provider_ref, text)
  rescue
    _ -> {:error, :provider_error}
  catch
    :exit, _ -> {:error, :provider_error}
  end

  defp send_text(_state, _text), do: {:error, :invalid_payload}
end
