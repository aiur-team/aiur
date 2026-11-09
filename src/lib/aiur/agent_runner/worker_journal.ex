defmodule Aiur.AgentRunner.WorkerJournal do
  @moduledoc false

  alias Aiur.Conversation.{Ingest, Ref}
  alias Aiur.Issue
  alias Aiur.Protocol.MapAccess

  @spec observe(Issue.t(), term(), String.t(), keyword(), map()) :: :ok
  def observe(issue, {:ok, event}, backend, opts, message) do
    unless Keyword.get(opts, :live_conversation_authority) == :display_tailer do
      item = message |> MapAccess.get(:payload) |> MapAccess.get(:params) |> MapAccess.get(:item)
      payload = Map.put(event[:payload] || %{}, :provider_item_id, MapAccess.get(item, :id))
      append(issue, Map.put(event, :payload, payload), backend, opts)
    end

    :ok
  end

  def observe(_issue, _event, _backend, _opts, _message), do: :ok

  @spec append(Issue.t(), map(), String.t(), keyword()) :: :ok
  def append(issue, event, backend, opts) do
    with_ref(issue, opts, fn ref ->
      source = %{
        harness: backend,
        role: :worker,
        provider_session_id: opts[:session_id],
        aiur_attempt_id: opts[:attempt_id] || opts[:telemetry_attempt_id],
        transcript_source: %{kind: opts[:journal_source_kind] || :aiur_ingest, locator_hash: nil},
        start_reason: if(opts[:resumed], do: :resume, else: :spawn),
        import_hint: %{workspace: opts[:journal_workspace], backend: backend, identifier: Issue.tracker_identity(issue)}
      }

      Ingest.append(ref, source, [event])
    end)
  end

  @spec finish(Issue.t(), term(), keyword()) :: :ok
  def finish(issue, result, opts) do
    reason = if match?({:error, _}, result), do: :crashed, else: :stopped
    with_ref(issue, opts, &Ingest.end_session(&1, opts[:session_id], reason))
  end

  defp with_ref(issue, opts, fun) do
    unless opts[:conversation_journal] == :disabled do
      case Ref.worker(Issue.tracker_identity(issue)) do
        {:ok, ref} -> fun.(ref)
        {:error, :unjoinable} -> Ingest.count_dropped("worker:unjoinable", 1)
      end
    end

    :ok
  rescue
    _error -> :ok
  catch
    :exit, _reason -> :ok
  end
end
