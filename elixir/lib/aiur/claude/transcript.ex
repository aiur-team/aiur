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

  alias Aiur.AgentEvents

  @edit_tools ~w(Edit Write MultiEdit NotebookEdit)

  @spec extract(map(), String.t() | nil) :: {:ok, AgentEvents.transcript_event()} | :skip
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

  # ----------------------------------------------------------------- items

  defp event_from_item("text", item, turn_id, timestamp) do
    case get(item, :text) do
      text when is_binary(text) and text != "" ->
        {:ok, AgentEvents.transcript_event(:assistant, text, timestamp: timestamp, turn_id: turn_id)}

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
  defp edit_diff("Write", input) do
    header(input) <> diff_lines(stringify(get(input, :content)), "+")
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

    header(input) <> body
  end

  defp edit_diff(_name, input) do
    header(input) <>
      diff_lines(stringify(get(input, :old_string)), "-") <>
      diff_lines(stringify(get(input, :new_string)), "+")
  end

  defp header(input) do
    case edit_path(input) do
      path when is_binary(path) and path != "" -> path <> "\n"
      _ -> ""
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
    case get(message, :payload) do
      payload when is_map(payload) -> get(payload, :method)
      _ -> nil
    end
  end

  defp notification_item(message) do
    with payload when is_map(payload) <- get(message, :payload),
         params when is_map(params) <- get(payload, :params) do
      get(params, :item)
    else
      _ -> nil
    end
  end

  defp claude_turn_id(message) do
    with payload when is_map(payload) <- get(message, :payload),
         params when is_map(params) <- get(payload, :params),
         id when is_binary(id) and id != "" <- get(params, :turn_id) do
      id
    else
      _ -> nil
    end
  end

  defp timestamp_for(message) do
    case Map.get(message, :timestamp) || Map.get(message, "timestamp") do
      %DateTime{} = ts -> ts
      _ -> DateTime.utc_now()
    end
  end

  # Tolerate both atom- and binary-keyed maps. Claude notifications arrive
  # as string-keyed JSON; internal aiur messages stay atom-keyed.
  defp get(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp get(_map, _key), do: nil
end
