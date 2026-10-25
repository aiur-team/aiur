defmodule VoiceConverse.TranscriptIndex.Transcripts do
  @moduledoc false

  alias VoiceConverse.TranscriptStore

  @id_regex ~r/\Avc_[A-Za-z0-9_-]{22}\.ndjson\z/

  def all(root) do
    with {:ok, conversations, _errors} <- all_with_errors(root), do: {:ok, conversations}
  end

  def all_with_errors(root) do
    with {:ok, scans, errors} <- scans_with_errors(root) do
      {:ok, Enum.map(scans, &public_conversation/1), errors}
    end
  end

  # Boot reconciliation needs the provider ids and final record time as well as
  # the public index fields. Keep those values from the same streaming scan so
  # a large transcript is never read again for cleanup or crash closing.
  def scans_with_errors(root) do
    case File.ls(root) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&Regex.match?(@id_regex, &1))
        |> Enum.map(&String.trim_trailing(&1, ".ndjson"))
        |> Enum.reduce({[], []}, fn id, {conversations, errors} ->
          case scan(root, id) do
            {:ok, item} -> {[item | conversations], errors}
            {:error, reason} -> {conversations, [{id, reason} | errors]}
          end
        end)
        |> then(fn {conversations, errors} -> {:ok, Enum.reverse(conversations), Enum.reverse(errors)} end)

      {:error, :enoent} ->
        {:ok, [], []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def conversation(root, conversation_id) do
    with {:ok, scan} <- scan(root, conversation_id) do
      {:ok, public_conversation(scan)}
    end
  end

  def scan(root, conversation_id) do
    with {:ok, path} <- TranscriptStore.path(root, conversation_id),
         {:ok, fd} <- File.open(path, [:read]) do
      try do
        fd
        |> IO.stream(:line)
        |> Enum.reduce_while({:ok, empty_scan()}, fn line, {:ok, scan} ->
          case decode_complete_line(line) do
            {:ok, %{} = record} -> scan_record(scan, record)
            _ -> {:cont, {:ok, scan}}
          end
        end)
        |> then(fn
          {:ok, %{started: nil}} -> {:error, :missing_session_started}
          {:ok, scan} -> {:ok, conversation_from_scan(conversation_id, scan)}
          error -> error
        end)
      after
        File.close(fd)
      end
    end
  rescue
    error in File.Error -> {:error, error.reason}
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
    with {:ok, %{provider_ids: ids}} <- scan(root, conversation_id), do: ids
  end

  def last_record_at(root, conversation_id, fallback) do
    with {:ok, %{last_at: at}} <- scan(root, conversation_id), do: {:ok, at || fallback}
  end

  def public_conversation(scan), do: Map.drop(scan, [:provider_ids, :cleanup_provider_ids, :last_at])

  defp empty_scan,
    do: %{
      started: nil,
      ended: nil,
      turn_count: 0,
      drafts: %{},
      provider_ids: [],
      cleanup_provider_ids: [],
      last_at: nil
    }

  defp scan_record(%{started: nil} = scan, %{"type" => "session_started"} = record),
    do: {:cont, {:ok, %{scan | started: record, last_at: record["at"]}}}

  defp scan_record(%{started: nil}, _record), do: {:halt, {:error, :missing_session_started}}

  defp scan_record(scan, record) do
    scan = %{scan | last_at: record["at"] || scan.last_at}

    scan =
      case record do
        %{"type" => "session_ended"} ->
          %{scan | ended: record}

        %{"type" => "user_turn"} ->
          %{scan | turn_count: scan.turn_count + 1}

        %{"type" => "draft", "draft_id" => id, "status" => status} when is_binary(status) ->
          %{scan | drafts: Map.put(scan.drafts, id, status)}

        %{"type" => "provider_conversation", "id" => id} when is_binary(id) and id != "" ->
          %{scan | provider_ids: Enum.uniq([id | scan.provider_ids])}

        %{"type" => "cleanup_enqueued", "provider_id" => id} when is_binary(id) and id != "" ->
          %{scan | cleanup_provider_ids: Enum.uniq([id | scan.cleanup_provider_ids])}

        _ ->
          scan
      end

    {:cont, {:ok, scan}}
  end

  defp conversation_from_scan(conversation_id, scan) do
    ended = scan.ended
    started = scan.started

    %{
      conversation_id: conversation_id,
      target: started["target"],
      role_id: started["role_id"],
      started_at: started["at"],
      ended_at: ended && ended["at"],
      end_reason: ended && ended["reason"],
      turn_count: scan.turn_count,
      draft_counts: scan.drafts |> Map.values() |> Enum.frequencies(),
      duration_s: ended && duration(ended, started),
      provider_ids: Enum.reverse(scan.provider_ids),
      cleanup_provider_ids: Enum.reverse(scan.cleanup_provider_ids),
      last_at: scan.last_at
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
end
