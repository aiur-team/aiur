defmodule AiurWeb.Build.ConversationSource.Entries do
  @moduledoc false

  @spec map_entries([map()], map(), boolean(), String.t() | nil) :: [map()]
  def map_entries(messages, row, first?, workspace \\ nil) do
    last_prompt = if first?, do: messages |> Enum.filter(&(Map.get(&1, :title) == "Issue prompt")) |> List.last()
    Enum.map(messages, &entry(&1, row, &1 == last_prompt, workspace))
  end

  @spec projection([map()], String.t() | nil) :: [map()]
  def projection(messages, workspace \\ nil) do
    Enum.map(messages, &project_entry(&1, workspace))
  end

  defp project_entry(message, workspace) do
    base = %{id: text(Map.get(message, :id, "")), at: timestamp(Map.get(message, :occurred_at))}
    Map.merge(base, project_content(message, workspace))
  end

  defp project_content(%{role: "agent"} = message, _workspace), do: %{k: "say", text: text(Map.get(message, :body, ""))}
  defp project_content(%{role: "operator"} = message, _workspace), do: %{k: "op", text: text(Map.get(message, :body, ""))}
  defp project_content(%{role: "tool"} = message, workspace), do: projected_tool(message, workspace)
  defp project_content(message, _workspace), do: %{k: "sys", text: text(Map.get(message, :title, ""))}

  defp projected_tool(message, workspace) do
    name = message |> Map.get(:title, "") |> text() |> String.downcase()
    body = message |> Map.get(:body, "") |> text() |> relative_text(workspace)
    summary = if name in ["edit", "write"], do: edit_summary(body), else: first_line(body)
    %{k: "tool", name: name, arg: first_line(body), res: body, summary: summary, bad: false}
  end

  defp entry(message, row, last_prompt?, workspace) do
    answer? = message[:role] == "user" and message[:title] == "Executor" and is_binary(message[:action_id])
    id = if answer?, do: "answer:#{message.action_id}", else: Map.get(message, :id, "")
    base = %{id: text(id), at: timestamp(Map.get(message, :timestamp))}
    base = if answer?, do: Map.put(base, :cursor, message.id), else: base
    Map.merge(base, content(message, row, last_prompt?, workspace))
  end

  defp content(%{role: "assistant", body: body}, _, _, _), do: %{k: "say", text: text(body)}
  defp content(%{role: "user", title: "Executor", body: body}, _, _, _), do: %{k: "op", text: text(body)}
  defp content(%{role: "user", title: "Issue prompt"}, row, last?, _), do: %{k: "sys", text: pickup(row, last?)}
  defp content(%{role: "tool"} = message, _, _, workspace), do: tool(message, workspace)
  defp content(%{role: "alert"} = message, _, _, _), do: %{k: "sys", text: text("Alert · #{message[:alert_name] || message[:title]}")}
  defp content(%{role: "system", title: "Warning", body: body}, _, _, _), do: %{k: "sys", text: "Warning · " <> String.slice(first_line(body), 0, 120)}
  defp content(message, _, _, _), do: %{k: "sys", text: text(Map.get(message, :title, ""))}

  defp pickup(row, true) do
    agent = row[:agent] || row["agent"]
    model = row[:model] || model_name(agent)
    effort = row[:effort] || if(is_map(agent), do: agent[:effort] || agent["effort"])
    if is_binary(model) and is_binary(effort), do: text("Picked up by #{model} · #{effort} effort"), else: "Picked up"
  end

  defp pickup(_, _), do: "Picked up"

  defp model_name(agent) when is_map(agent), do: agent[:name] || agent["name"] || agent[:model] || agent["model"]
  defp model_name(agent) when is_binary(agent), do: agent
  defp model_name(_), do: nil

  defp tool(message, workspace) do
    body = text(Map.get(message, :body, "")) |> relative_text(workspace)
    [command | _] = String.split(body, ~r/\nexit -?\d+/, parts: 2)
    command = String.replace_prefix(command, "$ ", "")
    arg = first_line(command) <> if(String.contains?(command, "\n"), do: " …", else: "")

    exit_code =
      case Regex.run(~r/\nexit (-?\d+)/, body) do
        [_, code] -> code
        _ -> "unknown"
      end

    name = tool_name(message[:title])
    res = if message[:title] == "Command output", do: "✗ auth failure", else: "✗ exit #{exit_code}"
    %{k: "tool", name: name, arg: arg, res: res, summary: arg, status: res, bad: true}
  end

  defp tool_name(title) when is_binary(title) do
    case Regex.run(~r/\A([[:alnum:]_-]+)(?:\s+tool)?\z/i, title) do
      [_, name] -> String.downcase(name)
      _ -> "bash"
    end
  end

  defp tool_name(_), do: "bash"

  defp edit_summary(body) do
    file =
      case Regex.run(~r/(?:Update|Add|Delete) File:\s*([^\n]+)/, body) do
        [_, path] -> String.trim(path)
        _ -> first_line(body)
      end

    {added, removed} = line_counts(body)
    "#{file} · +#{added} −#{removed}"
  end

  defp line_counts(body) do
    lines = String.split(body, "\n")
    {Enum.count(lines, &(String.starts_with?(&1, "+") and not String.starts_with?(&1, "+++"))), Enum.count(lines, &(String.starts_with?(&1, "-") and not String.starts_with?(&1, "---")))}
  end

  defp relative_text(value, workspace) when is_binary(workspace), do: String.replace(value, workspace <> "/", "")
  defp relative_text(value, _workspace), do: value

  @spec timestamp(term()) :: integer() | nil
  def timestamp(%DateTime{} = value), do: DateTime.to_unix(value, :millisecond)

  def timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, time, _} -> DateTime.to_unix(time, :millisecond)
      _ -> nil
    end
  end

  def timestamp(_), do: nil

  defp first_line(body), do: body |> text() |> String.split("\n", parts: 2) |> hd()

  defp text(value) when is_binary(value) do
    valid = String.replace_invalid(value, "")
    if String.length(valid) > 8_000, do: String.slice(valid, 0, 7_999) <> "…", else: valid
  end

  defp text(_), do: ""
end
