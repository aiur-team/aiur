defmodule SymphonyElixir.AgentLog do
  @moduledoc """
  Reads and parses the per-agent markdown log written by `SymphonyElixir.AgentRunner`
  at `<workspace_path>/logs/agent.md`. Produces a chat-style list of messages with
  user/assistant/system/tool roles, shared by the web dashboard's per-agent log
  modal and the CLI dashboard's log pane.
  """

  @type log_message :: %{
          role: String.t(),
          title: String.t(),
          timestamp: String.t(),
          body: String.t()
        }

  @log_relative_path "logs/agent.md"
  @body_summary_limit 1_600
  @message_window 80

  @spec workspace_log_path(String.t() | nil) :: String.t() | nil
  def workspace_log_path(workspace_path) when is_binary(workspace_path) do
    Path.join(workspace_path, @log_relative_path)
  end

  def workspace_log_path(_workspace_path), do: nil

  @spec read(String.t() | nil) :: String.t()
  def read(path) when is_binary(path) do
    case File.read(path) do
      {:ok, ""} -> "Agent log is empty."
      {:ok, content} -> content
      {:error, :enoent} -> "Agent log has not been written yet."
      {:error, reason} -> "Unable to read agent log: #{inspect(reason)}"
    end
  end

  def read(_path), do: "No local workspace path is available for this session."

  @spec parse(String.t()) :: [log_message()]
  def parse(content) when is_binary(content) do
    messages =
      ~r/^## ([^\n]+)\s+([^\n]+)\n\n```text\n(.*?)\n```/ms
      |> Regex.scan(content)
      |> Enum.map(fn [_match, timestamp, event, body] -> parse_log_entry(timestamp, event, body) end)
      |> Enum.reject(&is_nil/1)
      |> compact_log_messages()
      |> suppress_redundant_issue_prompts()
      |> Enum.take(-@message_window)

    if messages == [] do
      [log_message("system", "Log", "n/a", "No displayable chat events yet.")]
    else
      messages
    end
  end

  defp parse_log_entry(timestamp, event, body) do
    trimmed_body = String.trim(body)

    with "{" <> _ <- trimmed_body,
         {:ok, payload} <- Jason.decode(trimmed_body) do
      parse_json_log_entry(timestamp, event, payload, trimmed_body)
    else
      _ -> nil
    end
  end

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp parse_json_log_entry(timestamp, _event, %{"method" => method, "params" => params}, _raw_body) do
    case {method, params} do
      {"item/started", %{"item" => %{"type" => "userMessage", "content" => content}}} ->
        user_message_log_entry(timestamp, content_text(content))

      {"item/agentMessage/delta", %{"itemId" => item_id, "delta" => delta}} ->
        "assistant"
        |> log_message("Agent", timestamp, delta)
        |> Map.put(:merge_key, {:assistant_delta, item_id})

      {"item/agentMessage/delta", %{"delta" => delta}} ->
        log_message("assistant", "Agent", timestamp, delta)

      {"item/completed", %{"item" => %{"type" => "agentMessage", "id" => item_id, "text" => text}}} ->
        "assistant"
        |> log_message("Agent", timestamp, text)
        |> Map.put(:merge_key, {:assistant_delta, item_id})
        |> Map.put(:replace_merge?, true)

      {"item/completed", %{"item" => %{"type" => "agentMessage", "text" => text}}} ->
        log_message("assistant", "Agent", timestamp, text)

      {"warning", %{"message" => message}} ->
        log_message("system", "Warning", timestamp, message)

      {"item/started", %{"item" => %{"type" => "commandExecution"}}} ->
        nil

      {"item/commandExecution/outputDelta", _params} ->
        nil

      {"item/completed",
       %{
         "item" => %{
           "type" => "commandExecution",
           "command" => command,
           "exitCode" => exit_code,
           "aggregatedOutput" => output
         }
       }} ->
        if exit_code == 0 and not auth_failure_output?(output) do
          nil
        else
          log_message(
            "tool",
            command_title(exit_code),
            timestamp,
            command_summary(command, exit_code, output)
          )
        end

      {"item/started", %{"item" => %{"type" => type}}} when type in ["reasoning", "agentMessage"] ->
        nil

      {"item/completed", %{"item" => %{"type" => type}}} when type in ["reasoning", "userMessage"] ->
        nil

      {"thread/status/changed", _params} ->
        nil

      {"turn/started", _params} ->
        nil

      {"account/rateLimits/updated", _params} ->
        nil

      {"mcpServer/startupStatus/updated", _params} ->
        nil

      _ ->
        nil
    end
  end

  defp parse_json_log_entry(timestamp, event, payload, raw_body) do
    body =
      case Map.get(payload, "last_message") || Map.get(payload, :last_message) do
        message when is_binary(message) -> message
        _ -> summarize_payload(raw_body)
      end

    log_message("system", humanize_event(event), timestamp, body)
  end

  defp compact_log_messages(messages) do
    messages
    |> Enum.reduce([], &compact_log_message/2)
    |> Enum.reverse()
    |> Enum.map(&Map.delete(&1, :merge_key))
    |> Enum.map(&Map.delete(&1, :replace_merge?))
  end

  defp compact_log_message(message, acc) do
    case {message[:merge_key], List.first(acc)} do
      {nil, _previous} -> [message | acc]
      {key, %{merge_key: key} = previous} -> merge_log_message(message, previous, acc)
      {_key, _previous} -> [message | acc]
    end
  end

  defp merge_log_message(message, previous, acc) do
    if Map.get(message, :replace_merge?) do
      [message | tl(acc)]
    else
      [%{previous | body: previous.body <> message.body, timestamp: message.timestamp} | tl(acc)]
    end
  end

  defp suppress_redundant_issue_prompts(messages) do
    {messages, _seen_issue_prompt?} =
      Enum.reduce(messages, {[], false}, fn message, {acc, seen_issue_prompt?} ->
        cond do
          issue_prompt_log_message?(message) and seen_issue_prompt? ->
            {acc, seen_issue_prompt?}

          issue_prompt_log_message?(message) ->
            {[message | acc], true}

          true ->
            {[message | acc], seen_issue_prompt?}
        end
      end)

    Enum.reverse(messages)
  end

  defp issue_prompt_log_message?(%{role: "user", title: "Issue prompt"}), do: true
  defp issue_prompt_log_message?(_message), do: false

  defp content_text(content) when is_list(content) do
    Enum.map_join(content, "\n\n", fn
      %{"text" => text} -> text
      other -> inspect(other, pretty: true)
    end)
  end

  defp content_text(content), do: inspect(content, pretty: true)

  defp summarize_prompt(text) do
    issue_summary =
      Regex.run(~r/Issue:\n\n(.*?)(?:\n\nDescription:|\z)/s, text, capture: :all_but_first)

    description =
      Regex.run(
        ~r/Description:\n\n(.*?)(?:\n\n(?:Continuation context:|## Required Setup|## Workflow|## Workpad Template)|\z)/s,
        text,
        capture: :all_but_first
      )

    [List.first(issue_summary || []), List.first(description || [])]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
    |> case do
      "" -> summarize_payload(text)
      summary -> summarize_payload(String.trim(summary))
    end
  end

  defp log_message(role, title, timestamp, body) do
    %{
      role: role,
      title: title,
      timestamp: timestamp,
      body: blank_to_placeholder(body)
    }
  end

  defp humanize_event(event) do
    event
    |> to_string()
    |> String.replace(["/", "_", "-"], " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp summarize_payload(body) do
    trimmed = String.trim(body)

    if String.length(trimmed) > @body_summary_limit do
      String.slice(trimmed, 0, @body_summary_limit) <> "\n..."
    else
      trimmed
    end
  end

  defp auth_failure_output?(text) when is_binary(text) do
    String.contains?(String.downcase(text), [
      "failed to log in",
      "token is invalid",
      "auth status"
    ])
  end

  defp auth_failure_output?(_text), do: false

  defp command_title(0), do: "Command output"
  defp command_title(_exit_code), do: "Command failed"

  defp command_summary(command, exit_code, output) do
    """
    $ #{command}
    exit #{exit_code}

    #{summarize_payload(output || "")}
    """
    |> String.trim()
  end

  defp blank_to_placeholder(body) when body in [nil, ""], do: "No content."
  defp blank_to_placeholder(body), do: body

  defp user_message_log_entry(timestamp, text) do
    cond do
      String.starts_with?(text, "Coordination event:") ->
        log_message("system", "Coordination event", timestamp, summarize_payload(text))

      issue_prompt_text?(text) ->
        log_message("user", "Issue prompt", timestamp, summarize_prompt(text))

      true ->
        log_message("user", "Operator message", timestamp, summarize_payload(text))
    end
  end

  defp issue_prompt_text?(text) do
    String.contains?(text, [
      "You are an agent for this repository.",
      "Issue:\n\n",
      "Description:\n\n",
      "Continuation guidance:"
    ])
  end
end
