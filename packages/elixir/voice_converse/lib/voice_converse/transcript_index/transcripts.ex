defmodule VoiceConverse.TranscriptIndex.Transcripts do
  @moduledoc false

  alias VoiceConverse.TranscriptStore

  @id_regex ~r/\Avc_[A-Za-z0-9_-]{22}\.ndjson\z/

  def all(root) do
    case File.ls(root) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&Regex.match?(@id_regex, &1))
        |> Enum.map(&String.trim_trailing(&1, ".ndjson"))
        |> Enum.reduce_while({:ok, []}, fn id, {:ok, conversations} ->
          case conversation(root, id) do
            {:ok, item} -> {:cont, {:ok, [item | conversations]}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
        |> then(fn
          {:ok, conversations} -> {:ok, Enum.reverse(conversations)}
          error -> error
        end)

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def conversation(root, conversation_id) do
    with {:ok, records, _meta} <- TranscriptStore.read(root, conversation_id),
         {:ok, started} <- session_started(records) do
      {:ok, conversation_from_records(conversation_id, started, records)}
    end
  end

  def records_after(root, conversation_id, after_seq, limit) do
    with {:ok, path} <- TranscriptStore.path(root, conversation_id),
         true <- File.exists?(path) || {:error, :not_found} do
      {records, has_more?} =
        path
        |> File.stream!([], :line)
        |> Stream.with_index(1)
        |> Enum.reduce_while({[], false}, fn {line, seq}, {records, _} ->
          case decode_complete_line(line) do
            {:ok, %{}} when seq > after_seq and length(records) == limit ->
              {:halt, {records, true}}

            {:ok, %{} = record} when seq > after_seq ->
              {:cont, {[%{seq: seq, record: record} | records], false}}

            _ ->
              {:cont, {records, false}}
          end
        end)

      records = Enum.reverse(records)
      {:ok, records, if(has_more?, do: List.last(records).seq, else: nil)}
    end
  rescue
    error in File.Error -> {:error, error.reason}
  end

  def provider_ids(root, conversation_id) do
    with {:ok, records, _meta} <- TranscriptStore.read(root, conversation_id) do
      records
      |> Enum.filter(&(&1["type"] == "provider_conversation"))
      |> Enum.map(& &1["id"])
      |> Enum.filter(&(is_binary(&1) and &1 != ""))
      |> Enum.uniq()
    else
      _ -> []
    end
  end

  def last_record_at(root, conversation_id, fallback) do
    with {:ok, records, _meta} <- TranscriptStore.read(root, conversation_id) do
      at = Enum.find_value(Enum.reverse(records), fallback, fn record -> record["at"] end)
      {:ok, at}
    end
  end

  defp session_started([%{"type" => "session_started"} = started | _]), do: {:ok, started}
  defp session_started(_), do: {:error, :missing_session_started}

  defp conversation_from_records(conversation_id, started, records) do
    ended = Enum.find(Enum.reverse(records), &(&1["type"] == "session_ended"))

    %{
      conversation_id: conversation_id,
      target: started["target"],
      role_id: started["role_id"],
      started_at: started["at"],
      ended_at: ended && ended["at"],
      end_reason: ended && ended["reason"],
      turn_count: Enum.count(records, &(&1["type"] == "user_turn")),
      draft_counts: draft_counts(records),
      duration_s: ended && duration(ended, started)
    }
  end

  defp duration(ended, started) do
    case ended["duration_s"] do
      seconds when is_integer(seconds) and seconds >= 0 -> seconds
      _ -> duration_between(ended["at"], started["at"])
    end
  end

  def duration_between(ended_at, started_at) do
    with {:ok, ended_at, _} <- DateTime.from_iso8601(ended_at),
         {:ok, started_at, _} <- DateTime.from_iso8601(started_at) do
      max(DateTime.diff(ended_at, started_at), 0)
    else
      _ -> 0
    end
  end

  defp decode_complete_line(line) do
    if String.ends_with?(line, "\n"), do: Jason.decode(String.trim_trailing(line, "\n")), else: :torn_tail
  end

  defp draft_counts(records) do
    records
    |> Enum.reduce(%{}, fn
      %{"type" => "draft", "draft_id" => id, "status" => status}, drafts when is_binary(status) ->
        Map.put(drafts, id, status)

      _, drafts ->
        drafts
    end)
    |> Map.values()
    |> Enum.frequencies()
  end
end
