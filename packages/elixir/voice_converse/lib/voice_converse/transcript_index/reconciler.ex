defmodule VoiceConverse.TranscriptIndex.Reconciler do
  @moduledoc false

  require Logger

  alias VoiceConverse.{ProviderCleanup, TranscriptStore}
  alias VoiceConverse.TranscriptIndex.{IndexFile, Transcripts}

  def reconcile(root, opts) do
    enqueue = Keyword.get(opts, :enqueue, &ProviderCleanup.enqueue/2)
    warn_if_index_is_torn(root)

    with {:ok, conversations} <- Transcripts.all(root) do
      {count, errors} =
        Enum.reduce(conversations, {0, []}, fn conversation, {count, errors} ->
          if conversation.end_reason do
            {count, errors}
          else
            {result, new_errors} = close_crashed(root, conversation, enqueue)
            {count + if(result == :ok, do: 1, else: 0), new_errors ++ maybe_error(result, errors)}
          end
        end)

      Enum.each(errors, &Logger.warning("voice transcript reconciliation failed: #{inspect(&1)}"))

      case IndexFile.rebuild(root) do
        :ok -> {:ok, %{reconciled: count, errors: Enum.reverse(errors)}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp close_crashed(root, conversation, enqueue) do
    result =
      with {:ok, ended_at} <- Transcripts.last_record_at(root, conversation.conversation_id, conversation.started_at),
           {:ok, started_at, _} <- DateTime.from_iso8601(conversation.started_at),
           {:ok, ended_at_time, _} <- DateTime.from_iso8601(ended_at),
           {:ok, store} <- TranscriptStore.reopen(root, conversation.conversation_id),
           :ok <- TranscriptStore.append(store, session_ended(ended_at, started_at, ended_at_time)) do
        TranscriptStore.close(store)
      end

    errors =
      Enum.reduce(Transcripts.provider_ids(root, conversation.conversation_id), [], fn provider_id, errors ->
        case enqueue.(provider_id, conversation.conversation_id) do
          :ok -> errors
          {:error, reason} -> [reason | errors]
          other -> [other | errors]
        end
      end)

    {result, errors}
  end

  defp session_ended(ended_at, started_at, ended_at_time) do
    %{
      type: "session_ended",
      reason: "daemon_restart",
      at: ended_at,
      duration_s: max(DateTime.diff(ended_at_time, started_at), 0)
    }
  end

  defp maybe_error(:ok, errors), do: errors
  defp maybe_error({:error, reason}, errors), do: [reason | errors]

  defp warn_if_index_is_torn(root) do
    case IndexFile.read(root) do
      {:error, reason} -> Logger.warning("voice transcript index is being rebuilt: #{inspect(reason)}")
      _ -> :ok
    end
  end
end
