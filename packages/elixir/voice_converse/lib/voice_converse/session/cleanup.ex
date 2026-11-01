defmodule VoiceConverse.Session.Cleanup do
  @moduledoc false

  alias VoiceConverse.ProviderCleanup

  def enqueue(state) do
    if is_nil(state.config.cleanup_root) and state.config.transcript == :none and not state.config.provider_cleanup do
      {:ok, state}
    else
      cleanup = Module.concat(state.config.name, ProviderCleanup)

      Enum.reduce_while(state.provider_ids, {:ok, state}, fn provider_id, {:ok, state} ->
        with :ok <- ProviderCleanup.enqueue(cleanup, provider_id, state.id),
             {:ok, state} <- persist_marker(state, provider_id) do
          {:cont, {:ok, state}}
        else
          _ -> {:halt, {:error, state}}
        end
      end)
    end
  end

  defp persist_marker(%{config: %{transcript: :none}} = state, _provider_id), do: {:ok, state}

  defp persist_marker(state, provider_id) do
    record = %{type: "cleanup_enqueued", provider_id: provider_id, at: DateTime.to_iso8601(state.clock.())}

    case VoiceConverse.TranscriptStore.append(state.store, record) do
      :ok -> {:ok, state}
      {:error, _reason} -> {:ok, state}
    end
  end
end
