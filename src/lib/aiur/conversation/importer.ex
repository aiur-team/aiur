defmodule Aiur.Conversation.Importer do
  @moduledoc "Streams pre-journal workspace records, falling back to this launch's IssueLog."
  alias Aiur.CodingAgent
  alias Aiur.Conversation.Entry
  alias Aiur.Protocol.MapAccess

  @type plan :: {:workspace | :issue_log, Path.t()} | :none

  @spec plan(map()) :: plan()
  def plan(hint) do
    workspace = hint[:workspace]
    path = if is_binary(workspace), do: Path.join(workspace, "logs/agent.ndjson")
    if safe_file?(path), do: {:workspace, path}, else: fallback(hint)
  end

  @spec fallback(map()) :: plan()
  def fallback(%{identifier: identifier}) when not is_nil(identifier) do
    path = Aiur.IssueLog.transcript_path(identifier)
    if safe_file?(path), do: {:issue_log, path}, else: :none
  end

  def fallback(_hint), do: :none

  @doc "One result per source line, including skipped-line counters, for bounded writer steps."
  @spec stream(plan(), String.t()) :: Enumerable.t()
  def stream(:none, _backend), do: []

  def stream({kind, path}, backend) do
    # Snapshot the boundary: the source may continue receiving live records.
    case safe_stat(path) do
      {:ok, %File.Stat{type: :regular} = stat} ->
        Stream.resource(
          fn -> open_snapshot(path, stat) end,
          fn
            nil -> {:halt, nil}
            {:error, _reason} -> {[{:skipped, 1}], nil}
            {io, remaining, index} -> read_line(io, remaining, index, kind, backend)
          end,
          fn
            {io, _, _} -> File.close(io)
            _ -> :ok
          end
        )

      _ ->
        [{:skipped, 1}]
    end
  end

  defp open_snapshot(path, expected) do
    with true <- safe_file?(path),
         {:ok, io} <- File.open(path, [:read, :binary]) do
      case :file.read_file_info(io) do
        {:ok, record} ->
          verify_opened(io, File.Stat.from_record(record), expected)

        {:error, reason} ->
          File.close(io)
          {:error, reason}
      end
    else
      _ -> {:error, :source_unreadable}
    end
  end

  defp verify_opened(io, actual, expected) do
    if Map.take(actual, [:type, :inode, :major_device, :minor_device]) == Map.take(expected, [:type, :inode, :major_device, :minor_device]) do
      {io, expected.size, 1}
    else
      File.close(io)
      {:error, :source_replaced}
    end
  end

  defp read_line(io, 0, index, _kind, _backend), do: {:halt, {io, 0, index}}

  defp read_line(io, remaining, index, kind, backend) do
    case IO.binread(io, :line) do
      :eof -> {:halt, {io, 0, index}}
      {:error, _reason} -> {[{:skipped, 1}], {io, 0, index}}
      line when byte_size(line) <= remaining -> {[with_line(decode(line, kind, backend), index)], {io, remaining - byte_size(line), index + 1}}
      _ -> {:halt, {io, 0, index}}
    end
  end

  @spec safe_file?(Path.t() | nil) :: boolean()
  def safe_file?(path), do: match?({:ok, %File.Stat{type: :regular}}, safe_stat(path))

  defp safe_stat(nil), do: {:error, :enoent}

  defp safe_stat(path) do
    components = path |> Path.expand() |> Path.split() |> Enum.scan(&Path.join(&2, &1))

    if Enum.any?(components, &match?({:ok, %File.Stat{type: :symlink}}, File.lstat(&1))),
      do: {:error, :symlink},
      else: File.lstat(path)
  end

  defp with_line({:entry, entry}, index), do: {:entry, %{entry | meta: Map.put(entry.meta, :import_line, index)}}
  defp with_line(result, _index), do: result

  defp decode(line, kind, backend) do
    case Jason.decode(line) do
      {:ok, record} when is_map(record) -> extract(record, kind, backend)
      _ -> {:skipped, 1}
    end
  rescue
    _error -> {:skipped, 1}
  end

  defp extract(record, :issue_log, _backend) do
    case Entry.from_transcript_event(record) do
      {:ok, entry} -> {:entry, %{entry | body_truncated: entry.body_truncated or truncated_issue_body?(record["body"] || ""), meta: Map.put(entry.meta, :import_source, "issue_log")}}
      :skip -> :skip
    end
  end

  defp extract(record, :workspace, backend) do
    result =
      case record["transcript_event"] do
        %{"role" => _} = event -> {:ok, event}
        _ -> CodingAgent.transcript_module(backend).extract(record, record["turn_id"])
      end

    with {:ok, event} <- result,
         payload = MapAccess.get(event, :payload) || %{},
         item = record |> MapAccess.get(:payload) |> MapAccess.get(:params) |> MapAccess.get(:item),
         payload = Map.put(payload, :provider_item_id, MapAccess.get(item, :id) || MapAccess.get(payload, :provider_item_id)),
         {:ok, entry} <- Entry.from_transcript_event(Map.put(event, :payload, payload)) do
      {:entry, %{entry | meta: Map.put(entry.meta, :import_source, "workspace")}}
    else
      :skip -> :skip
    end
  end

  defp truncated_issue_body?(body), do: String.length(body) == 1000 or (String.length(body) == 1001 and String.ends_with?(body, "…"))
end
