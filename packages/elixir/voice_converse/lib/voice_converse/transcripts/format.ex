defmodule VoiceConverse.Transcripts.Format do
  @moduledoc false

  @spec list([map()]) :: String.t()
  def list([]), do: "No voice conversations recorded."

  def list(records) do
    header = "ID  TARGET  STARTED (LOCAL)  DURATION  END REASON  TURNS  DRAFTS (sent/proposed/discarded/stale)"
    Enum.join([header | Enum.map(records, &row/1)], "\n")
  end

  @spec show([map()], map()) :: String.t()
  def show(records, meta) do
    lines =
      Enum.map(records, fn record ->
        "[#{time(record["at"])}] #{record_text(record)}" |> String.replace("\r", "\\r") |> String.replace("\n", "\\n")
      end)

    lines =
      if meta.skipped_lines == [],
        do: lines,
        else: lines ++ ["(skipped invalid records at lines #{Enum.join(meta.skipped_lines, ", ")})"]

    Enum.join(if(meta.torn_tail, do: lines ++ ["(last record incomplete)"], else: lines), "\n")
  end

  defp row(item) do
    drafts = Enum.map_join(~w(sent proposed discarded stale), "/", &to_string(Map.get(item.draft_counts, &1, 0)))

    Enum.join(
      [
        item.conversation_id,
        target(item.target),
        local_time(item.started_at),
        duration(item.duration_s),
        item.end_reason || "unknown",
        item.turn_count,
        drafts
      ],
      "  "
    )
  end

  defp target(%{"id" => id}), do: id
  defp target(nil), do: "unknown"
  defp target(value) when is_binary(value), do: value
  defp target(value), do: Jason.encode!(value)

  defp duration(nil), do: "unknown"
  defp duration(seconds), do: "#{seconds}s"
  defp time(value) when is_binary(value), do: String.slice(value, 11, 8)
  defp time(_), do: "unknown"

  defp local_time(value) do
    with {:ok, dt, _} <- DateTime.from_iso8601(value) do
      dt
      |> DateTime.to_naive()
      |> NaiveDateTime.to_erl()
      |> :calendar.universal_time_to_local_time()
      |> NaiveDateTime.from_erl!()
      |> NaiveDateTime.to_string()
    else
      _ -> "unknown"
    end
  end

  defp record_text(%{"type" => "user_turn"} = r), do: "you: #{r["text"]}"
  defp record_text(%{"type" => "assistant_turn"} = r), do: "assistant: #{r["text"]}"
  defp record_text(%{"type" => "context"} = r), do: "context(#{r["source"]}, observed #{age(r)}): #{r["text"]}"
  defp record_text(%{"type" => "tool_call"} = r), do: "tool #{r["name"]} → #{Jason.encode!(r["params"])}"
  defp record_text(%{"type" => "tool_result"} = r), do: "tool #{r["name"]} → #{r["summary"]}"
  defp record_text(%{"type" => "draft"} = r), do: "draft #{r["draft_id"]} #{r["status"]}: #{r["text"]}"

  defp record_text(%{"type" => "delivery"} = r),
    do:
      "delivery #{r["draft_id"]} #{r["status"]}: #{r["text"] || Jason.encode!(Map.drop(r, ~w(v type at draft_id status)))}"

  defp record_text(r), do: "#{r["type"]}: #{Jason.encode!(Map.drop(r, ~w(v type at)))}"

  defp age(r) do
    with {:ok, at, _} <- DateTime.from_iso8601(r["at"] || ""),
         {:ok, observed, _} <- DateTime.from_iso8601(r["observed_at"] || "") do
      "#{max(DateTime.diff(at, observed), 0)}s before record"
    else
      _ -> "unknown"
    end
  end
end
