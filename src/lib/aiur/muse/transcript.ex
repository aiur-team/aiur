defmodule Aiur.Muse.Transcript do
  @moduledoc "Native Muse view items rendered through Aiur's shared transcript contract."

  alias Aiur.AgentEvents
  alias Aiur.Muse.Approvals

  @spec extract(map(), String.t() | nil) :: {:ok, AgentEvents.transcript_event()} | :skip
  def extract(
        %{payload: %{"method" => "item/completed", "params" => %{"item" => item}}} = message,
        fallback
      )
      when is_map(item) do
    {role, body, payload} = item_content(item)

    if is_binary(body) and body != "" do
      completed = event(role, body, item, message, fallback, payload)
      {:ok, stream_completion(completed, message)}
    else
      :skip
    end
  end

  def extract(
        %{
          muse_item_kind: "agentMessage",
          payload: %{"method" => "item/delta", "params" => params}
        } = message,
        fallback
      ) do
    case params do
      %{"field" => "text", "delta" => text, "itemId" => id} when is_binary(text) and text != "" ->
        {:ok,
         event(:assistant, text, params, message, fallback, nil)
         |> Map.put(:kind, :assistant_delta)
         |> Map.put(:id, id)}

      _ ->
        :skip
    end
  end

  def extract(%{payload: %{"method" => method, "params" => params}} = message, fallback)
      when method in ["approval/request", "approval/requested", "approval/updated"] do
    choices =
      (params["availableChoices"] || [])
      |> Enum.filter(&match?(%{"choiceId" => id, "label" => label} when is_binary(id) and is_binary(label), &1))
      |> Enum.map_join("\n", fn choice ->
        "#{choice["label"]}: /approve #{params["approvalId"]} #{Approvals.requirement_token(params["currentRequirementId"])} #{choice["choiceId"]}"
      end)

    body =
      "Muse needs approval for #{approval_subject(params["subject"])}. Reply with the exact command for your choice:\n#{choices}"

    {:ok, event(:system, body, params, message, fallback, %{approval: params})}
  end

  def extract(
        %{
          payload: %{"method" => "turn/completed", "params" => %{"terminal" => "failed"} = params}
        } = message,
        fallback
      ) do
    body = get_in(params, ["error", "message"]) || params["reason"] || "Muse turn failed"
    {:ok, event(:system, body, params, message, fallback, %{error: params["error"]})}
  end

  def extract(%{reason: :native_user_input_required, payload: %{"method" => "userInput/request", "params" => params}} = message, fallback) do
    body = "Muse requested a native input dialog that Aiur cannot display. Cancellation requested; send your instructions in chat after the turn stops."
    {:ok, event(:system, body, params, message, fallback, %{reason: :native_user_input_required})}
  end

  def extract(_message, _fallback), do: :skip

  defp stream_completion(%{role: :assistant, body: body} = event, %{muse_streamed_text: streamed}) when is_binary(streamed) do
    remainder =
      if String.starts_with?(body, streamed),
        do: binary_part(body, byte_size(streamed), byte_size(body) - byte_size(streamed)),
        else: "\n\n" <> body

    Map.put(event, :stream_body, remainder)
  end

  defp stream_completion(event, _message), do: event

  defp approval_subject(%{"kind" => kind} = subject) when is_binary(kind) do
    detail =
      Enum.find_value(["command", "toolName", "path", "host", "target"], fn key ->
        case subject[key] do
          value when is_binary(value) and value != "" -> value
          _ -> nil
        end
      end)

    if detail, do: "#{kind}: #{detail}", else: kind
  end

  defp approval_subject(_subject), do: "a native request"

  defp item_content(%{"kind" => "agentMessage"} = item), do: {:assistant, item["text"], nil}

  defp item_content(%{"kind" => "userMessage"} = item),
    do: {:user, item["displayText"] || item["text"], nil}

  defp item_content(%{"kind" => "reasoning"} = item), do: {:reasoning, item["text"], nil}

  defp item_content(%{"kind" => "toolCall"} = item) do
    tool = item["tool"] || "Muse tool"
    arguments = arguments(item["args"])
    body = AgentEvents.tool_call_body(tool, arguments)

    payload = %{
      title: tool,
      body: body,
      tool: tool,
      arguments: arguments,
      output: item["visibleOutput"],
      status: item["status"]
    }

    {:tool, body, payload}
  end

  defp item_content(%{"kind" => "userShell"} = item) do
    command = item["commandText"] || "Shell command"

    payload = %{
      command: command,
      title: command,
      output: item["visibleOutput"],
      exit_code: item["exitCode"]
    }

    {:command, command, payload}
  end

  defp item_content(item) do
    body =
      item["fallbackText"] || item["summary"] ||
        "Muse #{item["kind"] || "unknown item"} (#{item["status"] || "unknown"})"

    {:system, body, %{native_kind: item["kind"], status: item["status"]}}
  end

  defp event(role, body, item, message, fallback, payload) do
    AgentEvents.transcript_event(role, body,
      timestamp: message[:timestamp],
      msg_id: item["itemId"] || item["approvalId"],
      turn_id: item["turnId"] || fallback,
      payload: payload
    )
  end

  defp arguments(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> decoded
      _ -> value
    end
  end

  defp arguments(value), do: value || %{}
end
