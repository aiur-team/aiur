defmodule Aiur.AgentRunner.StoppedSessionPrompt do
  @moduledoc false

  @tail_bytes 1_048_576
  @max_message_chars 2_000

  @spec render(Path.t() | nil, String.t() | nil) :: String.t()
  def render(workspace, identifier) when is_binary(workspace) and is_binary(identifier) do
    with true <- File.dir?(workspace),
         {status, 0} <- git_status(workspace),
         true <- String.trim(status) != "" do
      """

      ## Resuming from a stopped session

      The previous session stopped before it could finish. Its workspace was kept; continue from this work rather than restarting the ticket. Reconcile the current workspace and workpad, then continue the remaining work.

      `git status --short` in the kept workspace:
      ```text
      #{String.trim_trailing(status)}
      ```

      Last agent message:
      #{last_agent_message(workspace, identifier)}
      """
    else
      _clean_or_unavailable -> ""
    end
  end

  def render(_workspace, _identifier), do: ""

  defp git_status(workspace) do
    System.cmd("git", ["-C", workspace, "status", "--short"], stderr_to_stdout: true)
  rescue
    _error -> {"", 1}
  end

  defp last_agent_message(workspace, identifier) do
    path = Path.join(workspace, "logs/agent.ndjson")

    case read_tail(path) do
      {:ok, content} ->
        content
        |> String.split("\n", trim: true)
        |> Enum.reduce(nil, &remember_agent_message/2)
        |> format_agent_message(identifier)

      _missing_or_unreadable ->
        "(not recorded)"
    end
  rescue
    _error -> "(not recorded)"
  end

  # agent.ndjson can reach tens of MB; only its tail holds the last message.
  defp read_tail(path) do
    with {:ok, %File.Stat{size: size}} <- File.stat(path),
         {:ok, file} <- File.open(path, [:read, :binary]) do
      try do
        case :file.pread(file, max(size - @tail_bytes, 0), @tail_bytes) do
          :eof -> {:ok, ""}
          result -> result
        end
      after
        File.close(file)
      end
    end
  end

  defp remember_agent_message(line, previous) do
    case Jason.decode(line) do
      {:ok, record} when is_map(record) -> update_agent_message(record, previous)
      _invalid_record -> previous
    end
  end

  defp update_agent_message(%{"event" => event} = record, previous)
       when event in ["agent_message", "assistant_message", "task_finished", "task_complete"] do
    record["last_message"] || record["body"] || previous
  end

  defp update_agent_message(%{"event" => "transcript", "transcript_event" => transcript}, previous)
       when is_map(transcript) do
    if transcript["role"] == "assistant" and is_binary(transcript["body"]) and transcript["body"] != "",
      do: transcript["body"],
      else: previous
  end

  defp update_agent_message(record, previous) do
    payload = backend_payload(record)
    params = payload["params"] || %{}
    item = params["item"] || %{}

    case payload["method"] do
      "item/completed" ->
        if item["type"] == "agentMessage" and is_binary(item["text"]) and item["text"] != "", do: item["text"], else: previous

      "item/agentMessage/delta" ->
        remember_delta(params, previous)

      _other ->
        previous
    end
  end

  defp backend_payload(%{"raw" => raw} = record) when is_binary(raw) do
    case Jason.decode(raw) do
      {:ok, payload} when is_map(payload) -> payload
      _invalid_payload -> nested_payload(record)
    end
  end

  defp backend_payload(record), do: nested_payload(record)

  defp nested_payload(record) do
    case record["payload"] do
      payload when is_map(payload) -> payload
      _missing_payload -> record
    end
  end

  defp remember_delta(params, previous) do
    delta = params["delta"]
    item_id = params["itemId"]

    if is_binary(delta) and delta != "" do
      case previous do
        %{item_id: ^item_id, text: text} when is_binary(item_id) -> %{item_id: item_id, text: text <> delta}
        _previous -> %{item_id: item_id, text: delta}
      end
    else
      previous
    end
  end

  defp format_agent_message(%{text: message}, identifier), do: format_agent_message(message, identifier)

  defp format_agent_message(message, identifier) when is_binary(message) and message != "",
    do: "Ticket #{identifier}: " <> String.slice(message, -@max_message_chars..-1//1)

  defp format_agent_message(_missing_message, _identifier), do: "(not recorded)"
end
