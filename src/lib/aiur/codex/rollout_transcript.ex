defmodule Aiur.Codex.RolloutTranscript do
  @moduledoc """
  Extracts supported Codex TUI rollout records from the version-pinned JSONL layout.

  The reader accepts 0.171.x, the first version captured by the TUI rollout
  spike. Unknown records and item kinds are skipped so newer layouts never
  produce guessed transcript content.
  """

  alias Aiur.AgentEvents

  @tested_version ~r/\A0\.171\.\d+\z/

  @spec version_status(term()) :: :tested | :untested | :absent
  def version_status(%{"type" => "session_meta", "payload" => %{"cli_version" => version}}) when is_binary(version),
    do: if(Regex.match?(@tested_version, version), do: :tested, else: :untested)

  def version_status(%{"type" => "session_meta"}), do: :absent
  def version_status(_), do: :absent

  @spec layout_status(term()) :: :supported | :unsupported
  def layout_status(%{"type" => "session_meta"} = record), do: if(version_status(record) == :tested, do: :supported, else: :unsupported)
  def layout_status(_record), do: :unsupported

  @spec extract_file([map()], String.t() | nil) :: {:ok, [AgentEvents.transcript_event()]} | {:error, :unsupported}
  def extract_file(records, fallback_turn_id \\ nil)

  def extract_file([first | rest], fallback_turn_id) do
    if layout_status(first) == :supported do
      {:ok, Enum.flat_map(rest, &extract(&1, fallback_turn_id))}
    else
      {:error, :unsupported}
    end
  end

  def extract_file([], _fallback_turn_id), do: {:error, :unsupported}

  @spec extract(map(), String.t() | nil) :: [AgentEvents.transcript_event()]
  def extract(record, fallback_turn_id \\ nil)

  def extract(%{"type" => "event_msg", "payload" => %{"type" => "item_completed", "item" => item} = payload} = record, fallback)
      when is_map(item) do
    timestamp = timestamp(record)
    turn_id = Map.get(payload, "turn_id") || fallback
    id = non_empty(Map.get(item, "id"))
    extract_item(Map.get(item, "type"), item, timestamp, turn_id, id)
  end

  def extract(_record, _fallback), do: []

  defp extract_item("AgentMessage", item, timestamp, turn_id, id), do: texts(item["content"], :assistant, timestamp, turn_id, id)
  defp extract_item("UserMessage", item, timestamp, turn_id, id), do: texts(item["content"], :user, timestamp, turn_id, id)

  defp extract_item("Reasoning", item, timestamp, turn_id, id) do
    body = joined_text(item["summary_text"]) || joined_text(item["raw_content"])
    event(:reasoning, body, timestamp, turn_id, id)
  end

  defp extract_item("CommandExecution", item, timestamp, turn_id, id) do
    command = command_text(item["command"])
    payload = %{command: command, output: Map.get(item, "aggregated_output", ""), exit_code: Map.get(item, "exit_code"), workdir: Map.get(item, "cwd")}
    event(:command, command, timestamp, turn_id, id, payload)
  end

  defp extract_item("FileChange", item, timestamp, turn_id, id) do
    output = item |> Map.get("changes", []) |> List.wrap() |> Enum.map_join("\n", &change_text/1)
    event(:tool, output, timestamp, turn_id, id, %{tool: "edit", output: output})
  end

  defp extract_item(type, item, timestamp, turn_id, id) when type in ["DynamicToolCall", "McpToolCall"] do
    name = Map.get(item, "tool") || Map.get(item, "name") || type
    body = AgentEvents.tool_call_body(to_string(name), Map.get(item, "arguments", %{}))
    event(:tool, body, timestamp, turn_id, id, %{tool: to_string(name)})
  end

  defp extract_item("ContextCompaction", _item, timestamp, turn_id, id), do: event(:system, "Context compacted", timestamp, turn_id, id, %{session_boundary: "compact"})
  defp extract_item(_type, _item, _timestamp, _turn_id, _id), do: []

  defp texts(value, role, timestamp, turn_id, id) do
    body = joined_text(value)
    event(role, body, timestamp, turn_id, id)
  end

  defp event(role, body, timestamp, turn_id, id, payload \\ nil)
  defp event(_role, nil, _timestamp, _turn_id, _id, _payload), do: []

  defp event(role, body, timestamp, turn_id, id, payload) when is_binary(body) and body != "" do
    [AgentEvents.transcript_event(role, body, timestamp: timestamp, turn_id: turn_id, msg_id: id, payload: payload)]
  end

  defp joined_text(value) when is_binary(value), do: non_empty(value)

  defp joined_text(value) when is_list(value) do
    value
    |> Enum.map(fn
      %{"text" => text} when is_binary(text) -> text
      text when is_binary(text) -> text
      _ -> ""
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
    |> non_empty()
  end

  defp joined_text(_), do: nil

  defp command_text(value) when is_list(value) do
    value
    |> Enum.filter(&is_binary/1)
    |> Enum.join(" ")
    |> non_empty()
  end

  defp command_text(value), do: joined_text(value)

  defp change_text(%{"diff" => diff}) when is_binary(diff), do: diff
  defp change_text(%{"path" => path, "kind" => kind}), do: "#{kind}: #{path}"
  defp change_text(value) when is_binary(value), do: value
  defp change_text(_), do: ""

  defp timestamp(%{"timestamp" => value}) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, date, _} -> date
      _ -> DateTime.utc_now()
    end
  end

  defp timestamp(_), do: DateTime.utc_now()
  defp non_empty(value) when is_binary(value) and value != "", do: value
  defp non_empty(_), do: nil
end
