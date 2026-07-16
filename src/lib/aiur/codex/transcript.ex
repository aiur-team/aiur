defmodule Aiur.Codex.Transcript do
  @moduledoc """
  Codex-specific extraction of `Aiur.AgentEvents.transcript_event/3` from
  the raw `item/completed` notification stream codex emits.

  Aiur supports both codex and Claude as coding-agent backends. This
  module isolates the codex notification shape (`payload.method`,
  `payload.params.item`, `aggregatedOutput`, `arguments`, …) so
  `Aiur.AgentRunner` doesn't grow nested if/case branches when the
  Claude side is implemented in `Aiur.Claude.Transcript`.

  Dispatched via `Aiur.CodingAgent.transcript_module/0`.
  """

  alias Aiur.AgentEvents
  alias Aiur.Protocol.MapAccess

  @doc """
  Extract a transcript event from a codex notification message, or
  return `:skip` when no rendering applies. `fallback_turn_id` is the
  aiur-side queue-item turn id used only when codex's own `params.turnId`
  is absent.
  """
  @spec extract(map(), String.t() | nil) :: {:ok, AgentEvents.transcript_event()} | :skip
  def extract(message, fallback_turn_id) when is_map(message) do
    effective_turn_id = codex_turn_id(message) || fallback_turn_id
    timestamp = timestamp_for(message)

    case assistant_delta_from_codex(message) do
      {:ok, event} ->
        {:ok, event}

      :skip ->
        assistant_or_non_assistant_event(message, effective_turn_id, timestamp)
    end
  end

  def extract(_message, _fallback_turn_id), do: :skip

  defp assistant_or_non_assistant_event(message, effective_turn_id, timestamp) do
    case assistant_message_from_codex(message) do
      {text, msg_id} ->
        {:ok,
         AgentEvents.transcript_event(:assistant, text,
           timestamp: timestamp,
           turn_id: effective_turn_id,
           msg_id: msg_id
         )}

      _ ->
        non_assistant_event(message, effective_turn_id, timestamp)
    end
  end

  defp non_assistant_event(message, effective_turn_id, timestamp) do
    cond do
      command_payload = command_payload_from_codex(message) ->
        {:ok,
         AgentEvents.transcript_event(:command, command_payload.command,
           timestamp: timestamp,
           turn_id: effective_turn_id,
           payload: command_payload
         )}

      reasoning_text = reasoning_text_from_codex(message) ->
        {:ok,
         AgentEvents.transcript_event(:reasoning, reasoning_text,
           timestamp: timestamp,
           turn_id: effective_turn_id
         )}

      tool_payload = tool_payload_from_codex(message) ->
        {:ok,
         AgentEvents.transcript_event(:tool, tool_payload.title,
           timestamp: timestamp,
           turn_id: effective_turn_id,
           payload: tool_payload
         )}

      true ->
        :skip
    end
  end

  # ----------------------------------------------------------------- extraction

  defp assistant_message_from_codex(message) do
    with method when method in ["item/completed"] <- notification_method(message),
         item when is_map(item) <- notification_item(message),
         "agentMessage" <- get(item, :type),
         text when is_binary(text) and text != "" <- get(item, :text) do
      {text, item_id(item)}
    else
      _ -> nil
    end
  end

  defp assistant_delta_from_codex(message) do
    with "item/agentMessage/delta" <- notification_method(message),
         params when is_map(params) <- notification_params(message),
         id when is_binary(id) and id != "" <- get(params, :itemId),
         delta when is_binary(delta) and delta != "" <- get(params, :delta) do
      event =
        AgentEvents.transcript_event(:assistant, delta,
          timestamp: timestamp_for(message),
          msg_id: id,
          turn_id: codex_turn_id(message)
        )
        |> Map.put(:kind, :assistant_delta)
        |> Map.put(:id, id)

      {:ok, event}
    else
      _ -> :skip
    end
  end

  defp item_id(item) do
    case get(item, :id) do
      id when is_binary(id) and id != "" -> id
      _ -> nil
    end
  end

  defp command_payload_from_codex(message) do
    with "item/completed" <- notification_method(message),
         item when is_map(item) <- notification_item(message),
         "commandExecution" <- get(item, :type),
         command when is_binary(command) and command != "" <- command_label(item) do
      output = get(item, :aggregatedOutput) || ""
      exit_code = get(item, :exitCode)
      cwd = get(item, :cwd) || ""

      title =
        if is_integer(exit_code) and exit_code != 0,
          do: "#{command} [exit=#{exit_code}]",
          else: command

      %{command: command, output: output, title: title, workdir: cwd, exit_code: exit_code}
    else
      _ -> nil
    end
  end

  defp command_label(item) do
    case command_actions_label(get(item, :commandActions)) do
      label when is_binary(label) and label != "" -> label
      _ -> get(item, :command)
    end
  end

  defp command_actions_label([first | _]) when is_map(first), do: get(first, :command)
  defp command_actions_label(_), do: nil

  defp reasoning_text_from_codex(message) do
    with "item/completed" <- notification_method(message),
         item when is_map(item) <- notification_item(message),
         "reasoning" <- get(item, :type),
         text when is_binary(text) and text != "" <- reasoning_text(item) do
      text
    else
      _ -> nil
    end
  end

  defp reasoning_text(item) do
    case get(item, :summary) do
      list when is_list(list) and list != [] -> reasoning_join(list)
      _ -> reasoning_join(get(item, :content))
    end
  end

  defp reasoning_join(list) when is_list(list) do
    list
    |> Enum.map(fn
      %{} = item -> get(item, :text) || ""
      bin when is_binary(bin) -> bin
      _ -> ""
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp reasoning_join(_), do: ""

  defp tool_payload_from_codex(message) do
    with "item/completed" <- notification_method(message),
         item when is_map(item) <- notification_item(message),
         type when type in ["dynamicToolCall", "fileChange"] <- get(item, :type) do
      build_tool_payload(type, item)
    else
      _ -> nil
    end
  end

  defp build_tool_payload("dynamicToolCall", item) do
    tool_name = get(item, :tool) || "tool"
    arguments = decode_codex_json(get(item, :arguments))
    content = get(item, :contentItems)

    title =
      case namespace_prefix(item) do
        nil -> tool_name
        ns -> "#{ns}:#{tool_name}"
      end

    %{
      tool: tool_name,
      input: arguments || %{},
      output: format_tool_content(content),
      title: title,
      success: get(item, :success)
    }
  end

  defp build_tool_payload("fileChange", item) do
    changes = get(item, :changes) || []

    %{
      tool: "edit",
      input: %{"changes" => changes},
      output: file_change_output(changes),
      title: file_change_title(changes)
    }
  end

  defp file_change_title([first | rest]) when is_map(first) do
    path = get(first, :path) || get(first, :file) || "file"
    if rest == [], do: "edit #{path}", else: "edit #{path} (+#{length(rest)} more)"
  end

  defp file_change_title(_), do: "edit"

  defp file_change_output(changes) when is_list(changes) do
    changes
    |> Enum.map(fn
      %{} = c -> get(c, :diff) || get(c, :content) || ""
      _ -> ""
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  defp file_change_output(_), do: ""

  defp namespace_prefix(item) do
    case get(item, :namespace) do
      ns when is_binary(ns) and ns != "" -> ns
      _ -> nil
    end
  end

  defp decode_codex_json(nil), do: nil
  defp decode_codex_json(%{} = map), do: map

  defp decode_codex_json(str) when is_binary(str) do
    case Jason.decode(str) do
      {:ok, decoded} -> decoded
      _ -> %{"raw" => str}
    end
  end

  defp decode_codex_json(other), do: %{"raw" => inspect(other)}

  defp format_tool_content(nil), do: ""

  defp format_tool_content(list) when is_list(list) do
    Enum.map_join(list, "\n", fn
      %{} = item -> get(item, :text) || Jason.encode!(item)
      bin when is_binary(bin) -> bin
      other -> inspect(other)
    end)
  end

  defp format_tool_content(other), do: inspect(other)

  # ----------------------------------------------------------------- helpers

  defp notification_method(message) do
    MapAccess.notification_method(message)
  end

  defp notification_item(message) do
    MapAccess.notification_item(message)
  end

  defp notification_params(message) do
    with payload when is_map(payload) <- get(message, :payload),
         params when is_map(params) <- get(payload, :params) do
      params
    else
      _ -> nil
    end
  end

  defp codex_turn_id(message) do
    MapAccess.params_turn_id(message, :turnId)
  end

  defp timestamp_for(message) do
    MapAccess.message_timestamp(message)
  end

  defp get(map, key), do: MapAccess.get(map, key)
end
