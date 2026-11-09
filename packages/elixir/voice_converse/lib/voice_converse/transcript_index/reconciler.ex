defmodule VoiceConverse.TranscriptIndex.Reconciler do
  @moduledoc false

  require Logger

  alias VoiceConverse.{ProviderCleanup, TranscriptStore}
  alias VoiceConverse.TranscriptIndex.{IndexFile, Transcripts}

  def reconcile(root, opts) do
    enqueue = Keyword.get(opts, :enqueue, &ProviderCleanup.enqueue/2)

    with {:ok, conversations, scan_errors} <- Transcripts.scans_with_errors(root) do
      {count, reconciliation_errors, closed} =
        Enum.reduce(conversations, {0, [], []}, fn conversation, {count, errors, closed} ->
          {result, new_errors} = reconcile_conversation(root, conversation, enqueue)

          errors = new_errors ++ maybe_error(conversation.conversation_id, result, errors)

          case result do
            {:closed, closed_conversation} -> {count + 1, errors, [closed_conversation | closed]}
            _ -> {count, errors, closed}
          end
        end)

      errors = scan_errors ++ Enum.reverse(reconciliation_errors)
      Enum.each(errors, &Logger.warning("voice transcript reconciliation failed: #{inspect(&1)}"))
      record_closed_conversations(root, closed)
      conversations = update_closed_conversations(conversations, closed)

      case rebuild_index_if_needed(root, conversations) do
        :ok -> {:ok, %{reconciled: count, errors: errors}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp reconcile_conversation(root, %{end_reason: nil} = conversation, enqueue),
    do: close_crashed(root, conversation, enqueue)

  # A process can die after durably writing session_ended but before recording
  # cleanup handoff. Re-enqueue closed transcripts until their durable markers
  # exist; ProviderCleanup also de-duplicates an already-pending provider id.
  defp reconcile_conversation(root, conversation, enqueue) do
    {enqueued, errors} = enqueue_cleanup(conversation, enqueue)

    cond do
      errors != [] ->
        {{:error, :cleanup_enqueue_failed}, errors}

      enqueued == [] ->
        {:ok, []}

      true ->
        with :ok <- append_cleanup_marks(root, conversation.conversation_id, enqueued) do
          {:ok, []}
        end
    end
  end

  defp close_crashed(root, conversation, enqueue) do
    {enqueued, errors} = enqueue_cleanup(conversation, enqueue)

    result =
      if errors == [] do
        with ended_at <- conversation.last_at || conversation.started_at,
             {:ok, started_at, _} <- DateTime.from_iso8601(conversation.started_at),
             {:ok, ended_at_time, _} <- DateTime.from_iso8601(ended_at),
             :ok <-
               append_crash_close(root, conversation.conversation_id, enqueued, ended_at, started_at, ended_at_time) do
          {:closed, close_conversation(conversation, ended_at, started_at, ended_at_time)}
        end
      else
        {:error, :cleanup_enqueue_failed}
      end

    {result, errors}
  end

  defp close_conversation(conversation, ended_at, started_at, ended_at_time) do
    %{
      conversation
      | ended_at: ended_at,
        end_reason: "daemon_restart",
        duration_s: max(DateTime.diff(ended_at_time, started_at), 0)
    }
  end

  defp record_closed_conversations(root, conversations) do
    case IndexFile.read(root) do
      {:ok, _} ->
        if IndexFile.exists?(root) do
          Enum.each(conversations, fn conversation ->
            case IndexFile.append(root, "closed", Transcripts.public_conversation(conversation)) do
              :ok -> :ok
              {:error, reason} -> Logger.warning("voice transcript index close update failed: #{inspect(reason)}")
            end
          end)
        end

      _ ->
        :ok
    end
  end

  defp update_closed_conversations(conversations, closed) do
    by_id = Map.new(closed, &{&1.conversation_id, &1})
    Enum.map(conversations, &Map.get(by_id, &1.conversation_id, &1))
  end

  defp enqueue_cleanup(conversation, enqueue) do
    conversation.provider_ids
    |> Kernel.--(conversation.cleanup_provider_ids)
    |> Enum.reduce({[], []}, fn provider_id, {enqueued, errors} ->
      case enqueue.(provider_id, conversation.conversation_id) do
        :ok -> {[provider_id | enqueued], errors}
        {:error, reason} -> {enqueued, [reason | errors]}
        other -> {enqueued, [other | errors]}
      end
    end)
    |> then(fn {enqueued, errors} -> {Enum.reverse(enqueued), Enum.reverse(errors)} end)
  end

  defp append_cleanup_marks(root, conversation_id, provider_ids) do
    with_reopened(root, conversation_id, &append_cleanup_marks_to_store(&1, provider_ids))
  end

  defp append_crash_close(root, conversation_id, provider_ids, ended_at, started_at, ended_at_time) do
    with_reopened(root, conversation_id, fn store ->
      with :ok <- append_cleanup_marks_to_store(store, provider_ids),
           :ok <- TranscriptStore.append(store, session_ended(ended_at, started_at, ended_at_time), record_index: false) do
        :ok
      end
    end)
  end

  defp append_cleanup_marks_to_store(store, provider_ids) do
    Enum.reduce_while(provider_ids, :ok, fn provider_id, :ok ->
      case TranscriptStore.append(store, %{type: "cleanup_enqueued", provider_id: provider_id}) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp with_reopened(root, conversation_id, fun) do
    with {:ok, store} <- TranscriptStore.reopen(root, conversation_id) do
      try do
        fun.(store)
      after
        TranscriptStore.close(store)
      end
    end
  end

  defp session_ended(ended_at, started_at, ended_at_time) do
    %{
      type: "session_ended",
      reason: "daemon_restart",
      at: ended_at,
      duration_s: max(DateTime.diff(ended_at_time, started_at), 0)
    }
  end

  defp maybe_error(_conversation_id, :ok, errors), do: errors
  defp maybe_error(_conversation_id, {:closed, _conversation}, errors), do: errors
  defp maybe_error(conversation_id, {:error, reason}, errors), do: [{conversation_id, reason} | errors]

  defp rebuild_index_if_needed(root, conversations) do
    case IndexFile.read(root) do
      {:ok, _} ->
        if IndexFile.exists?(root) do
          :ok
        else
          IndexFile.rebuild(root, Enum.map(conversations, &Transcripts.public_conversation/1))
        end

      {:error, reason} ->
        Logger.warning("voice transcript index is being rebuilt: #{inspect(reason)}")
        IndexFile.rebuild(root, Enum.map(conversations, &Transcripts.public_conversation/1))
    end
  end
end
