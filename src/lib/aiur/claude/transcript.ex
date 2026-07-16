defmodule Aiur.Claude.Transcript do
  @moduledoc """
  Claude-side counterpart to `Aiur.Codex.Transcript`: extracts
  `Aiur.AgentEvents.transcript_event/3` values from the Claude
  app-server notification stream so the chat pane renders agent text,
  reasoning, shell commands, file edits, and tool output at parity with
  codex.

  Claude app-server emits one `item/created` notification per finalized
  item (`item/progress` carries streaming deltas and is intentionally
  skipped to avoid duplicate partial rows). Each item is flattened to
  `params.item` as `{id, created_at, type, ...fields}`:

    * `text`        — assistant words            → `:assistant`
    * `thinking`    — reasoning block            → `:reasoning`
    * `tool_call`   — `Bash`                      → `:command`
    * `tool_call`   — `Edit`/`Write`/…            → `:tool` (file edit)
    * `tool_call`   — any other tool / skill      → `:tool`
    * `tool_result` — tool output / build log     → `:tool`

  Unlike codex (whose `commandExecution` item carries `aggregatedOutput`
  inline), Claude streams a `tool_call` and its `tool_result` as two
  separate notifications, so a shell command and its output render as
  two adjacent rows rather than one combined part.

  Dispatched via `Aiur.CodingAgent.transcript_module/0`.
  """

  alias Aiur.Protocol.MapAccess

  alias Aiur.AgentEvents

  @edit_tools ~w(Edit Write MultiEdit NotebookEdit)

  @spec extract(map(), String.t() | nil) :: {:ok, AgentEvents.transcript_event()} | :skip
  # The interactive-REPL backend tails the transcript and emits already-extracted
  # events (see `extract_disk_record/2`), wrapping each in `%{transcript_event: ...}`
  # before handing it to the orchestrator's `on_message`. Pass those straight
  # through so the REPL backend shares the codex/JSON-RPC dispatch path.
  def extract(%{transcript_event: %{role: _} = event}, _fallback_turn_id), do: {:ok, event}

  def extract(message, fallback_turn_id) when is_map(message) do
    with "item/created" <- notification_method(message),
         item when is_map(item) <- notification_item(message) do
      turn_id = claude_turn_id(message) || fallback_turn_id
      event_from_item(get(item, :type), item, turn_id, timestamp_for(message))
    else
      _ -> :skip
    end
  end

  def extract(_message, _fallback_turn_id), do: :skip

  @doc """
  Extract transcript events from a single on-disk transcript jsonl record.

  The interactive-REPL backend tails the transcript jsonl rather than the
  JSON-RPC notification stream, so records arrive in the on-disk shape
  (`%{"type" => "assistant"|"user", "message" => %{"content" => [blocks]}}`)
  instead of the flat `item/created` envelope `extract/2` handles. An
  `assistant` record carries a content *array* (text / thinking / tool_use
  blocks), so this returns a list of events, one per renderable block.

  A bare user prompt string (the Executor’s own typed message, which the
  harness writes with `message.content` as a plain string) maps to a
  single `:user` event so replayed history shows messages from both
  surfaces. A `queued_command` `attachment` is a Claude Remote Control
  app message (the only on-disk trace of one) and also maps to a `:user`
  event. Non-conversational records (`bridge-session`, `system`,
  `file-history-snapshot`, `ai-title`, `last-prompt`, `permission-mode`,
  `queue-operation`, `pr-link`) yield `[]`.
  """
  @spec extract_disk_record(map(), String.t() | nil) :: [AgentEvents.transcript_event()]
  def extract_disk_record(record, fallback_turn_id) when is_map(record) do
    case get(record, :type) do
      "assistant" ->
        timestamp = disk_timestamp(record)

        record
        |> disk_content_blocks()
        |> Enum.flat_map(&events_for_block(&1, fallback_turn_id, timestamp))

      "user" ->
        extract_user_record(record, fallback_turn_id)

      "attachment" ->
        extract_attachment_record(record, fallback_turn_id)

      _ ->
        []
    end
  end

  def extract_disk_record(_record, _fallback_turn_id), do: []

  # A user record is either the Executor’s typed prompt (`content` is a
  # bare string -> a `:user` event) or a batch of `tool_result` blocks
  # (`content` is a list -> tool events), never both.
  defp extract_user_record(record, fallback_turn_id) do
    timestamp = disk_timestamp(record)

    case get(get(record, :message) || %{}, :content) do
      text when is_binary(text) and text != "" ->
        [AgentEvents.transcript_event(:user, text, timestamp: timestamp, turn_id: fallback_turn_id)]

      content when is_list(content) ->
        Enum.flat_map(content, &events_for_block(&1, fallback_turn_id, timestamp))

      _ ->
        []
    end
  end

  # A Claude Remote Control app message is persisted only as a
  # `queued_command` attachment — the relay never writes a `type: "user"`
  # record for it — so without this clause RC-origin messages never reach
  # the opencode conversation pane. Slash-commands (`commandMode` other
  # than `"prompt"`) are control input, not chat, so they stay dropped.
  defp extract_attachment_record(record, fallback_turn_id) do
    attachment = get(record, :attachment) || %{}

    with "queued_command" <- get(attachment, :type),
         "prompt" <- get(attachment, :commandMode),
         prompt when is_binary(prompt) and prompt != "" <- get(attachment, :prompt) do
      [
        AgentEvents.transcript_event(:user, prompt,
          timestamp: disk_timestamp(record),
          turn_id: fallback_turn_id,
          payload: %{origin: :remote}
        )
      ]
    else
      _ -> []
    end
  end

  defp events_for_block(block, turn_id, timestamp) do
    case block_to_event(block, turn_id, timestamp) do
      {:ok, event} -> [event]
      :skip -> []
    end
  end

  # On-disk content blocks share field names with the JSON-RPC items, so
  # each block is normalized to the item shape and routed through the same
  # `event_from_item/4` mapping. Only the `tool_use`/`tool_call` type name
  # and the `tool_result` content (string-or-list) differ.
  defp block_to_event(block, turn_id, timestamp) when is_map(block) do
    {type, item} = normalize_block(block)
    event_from_item(type, item, turn_id, timestamp)
  end

  defp block_to_event(_block, _turn_id, _timestamp), do: :skip

  defp item_id(item) do
    case get(item, :id) do
      id when is_binary(id) and id != "" -> id
      _ -> nil
    end
  end

  defp normalize_block(block) do
    case get(block, :type) do
      "tool_use" ->
        {"tool_call", block}

      "tool_result" ->
        {"tool_result", Map.put(block, "content", normalize_tool_result_content(get(block, :content)))}

      other ->
        {other, block}
    end
  end

  defp normalize_tool_result_content(content) when is_binary(content), do: content

  defp normalize_tool_result_content(content) when is_list(content) do
    Enum.map_join(content, "\n", fn
      block when is_map(block) -> stringify(get(block, :text))
      _ -> ""
    end)
  end

  defp normalize_tool_result_content(_content), do: ""

  defp disk_content_blocks(record) do
    with message when is_map(message) <- get(record, :message),
         content when is_list(content) <- get(message, :content) do
      content
    else
      _ -> []
    end
  end

  defp disk_timestamp(record) do
    case get(record, :timestamp) do
      ts when is_binary(ts) ->
        case DateTime.from_iso8601(ts) do
          {:ok, datetime, _offset} -> datetime
          _ -> DateTime.utc_now()
        end

      _ ->
        DateTime.utc_now()
    end
  end

  # ----------------------------------------------------------------- items

  defp event_from_item("text", item, turn_id, timestamp) do
    case get(item, :text) do
      text when is_binary(text) and text != "" ->
        {:ok,
         AgentEvents.transcript_event(:assistant, text,
           timestamp: timestamp,
           turn_id: turn_id,
           msg_id: item_id(item)
         )}

      _ ->
        :skip
    end
  end

  defp event_from_item("thinking", item, turn_id, timestamp) do
    case get(item, :thinking) do
      text when is_binary(text) and text != "" ->
        {:ok, AgentEvents.transcript_event(:reasoning, text, timestamp: timestamp, turn_id: turn_id)}

      _ ->
        :skip
    end
  end

  defp event_from_item("tool_call", item, turn_id, timestamp) do
    name = tool_name(item)
    input = tool_input(item)

    cond do
      name == "Bash" ->
        command = bash_command(input) || name
        workdir = get(input, :workdir) || ""

        {:ok,
         AgentEvents.transcript_event(:command, command,
           timestamp: timestamp,
           turn_id: turn_id,
           payload: %{command: command, output: "", title: command, workdir: workdir}
         )}

      name in @edit_tools ->
        title = edit_title(input)

        {:ok,
         AgentEvents.transcript_event(:tool, title,
           timestamp: timestamp,
           turn_id: turn_id,
           payload: %{tool: "edit", input: input, output: edit_diff(name, input), title: title}
         )}

      true ->
        {:ok,
         AgentEvents.transcript_event(:tool, name,
           timestamp: timestamp,
           turn_id: turn_id,
           payload: %{tool: name, input: input, output: "", title: name}
         )}
    end
  end

  defp event_from_item("tool_result", item, turn_id, timestamp) do
    case get(item, :content) do
      content when is_binary(content) and content != "" ->
        title = if get(item, :is_error), do: "tool result (error)", else: "tool result"

        {:ok,
         AgentEvents.transcript_event(:tool, title,
           timestamp: timestamp,
           turn_id: turn_id,
           payload: %{tool: "result", input: %{}, output: content, title: title}
         )}

      _ ->
        :skip
    end
  end

  defp event_from_item(_type, _item, _turn_id, _timestamp), do: :skip

  # ----------------------------------------------------------------- helpers

  defp tool_name(item) do
    case get(item, :name) do
      name when is_binary(name) and name != "" -> name
      _ -> "tool"
    end
  end

  defp tool_input(item) do
    case get(item, :input) do
      input when is_map(input) -> input
      _ -> %{}
    end
  end

  defp bash_command(input) do
    case get(input, :command) do
      command when is_binary(command) and command != "" -> command
      _ -> nil
    end
  end

  defp edit_title(input) do
    case edit_path(input) do
      path when is_binary(path) and path != "" -> "edit #{path}"
      _ -> "edit"
    end
  end

  defp edit_path(input) do
    get(input, :file_path) || get(input, :path) || get(input, :notebook_path)
  end

  # Render a `+`/`-` diff into the tool part's output so the opencode chat
  # pane colorizes the change, matching how codex surfaces `fileChange`
  # items. Claude carries the before/after text on the tool_call input.
  # Write/new-file: emit the raw new contents with no diff markers. The
  # chat pane's edit_diff_from_payload treats a marker-less block as a
  # whole-file create and greens every line — the same shape codex sends
  # for a new file. A `@@` header here would defeat that detection.
  defp edit_diff("Write", input) do
    stringify(get(input, :content))
  end

  defp edit_diff("MultiEdit", input) do
    edits =
      case get(input, :edits) do
        list when is_list(list) -> list
        _ -> []
      end

    body =
      Enum.map_join(edits, "", fn edit ->
        diff_lines(stringify(get(edit, :old_string)), "-") <>
          diff_lines(stringify(get(edit, :new_string)), "+")
      end)

    hunk_header(input) <> body
  end

  defp edit_diff(_name, input) do
    hunk_header(input) <>
      diff_lines(stringify(get(input, :old_string)), "-") <>
      diff_lines(stringify(get(input, :new_string)), "+")
  end

  # A `@@ … @@` hunk header makes the chat pane's looks_like_unified_diff?
  # detection fire, so the block passes through verbatim and Glamour paints
  # the `-`/`+` lines red/green. Without it the first (path) line isn't a
  # diff marker, the block reads as raw content, and every line — markers
  # included — gets a stray `+`, doubling into `+ -`/`+ +`.
  defp hunk_header(input) do
    case edit_path(input) do
      path when is_binary(path) and path != "" -> "@@ " <> path <> " @@\n"
      _ -> "@@ @@\n"
    end
  end

  defp diff_lines("", _prefix), do: ""

  defp diff_lines(text, prefix) do
    text
    |> String.split("\n")
    |> Enum.map_join("\n", fn line -> "#{prefix} #{line}" end)
    |> Kernel.<>("\n")
  end

  defp stringify(value) when is_binary(value), do: value
  defp stringify(_value), do: ""

  defp notification_method(message) do
    MapAccess.notification_method(message)
  end

  defp notification_item(message) do
    MapAccess.notification_item(message)
  end

  defp claude_turn_id(message) do
    MapAccess.params_turn_id(message, :turn_id)
  end

  defp timestamp_for(message) do
    MapAccess.message_timestamp(message)
  end

  defp get(map, key), do: MapAccess.get(map, key)
end
