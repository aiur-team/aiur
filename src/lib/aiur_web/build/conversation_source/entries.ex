defmodule AiurWeb.Build.ConversationSource.Entries do
  @moduledoc false

  @spec map_entries([map()], map(), boolean()) :: [map()]
  def map_entries(messages, row, first?) do
    last_prompt = if first?, do: messages |> Enum.filter(&(Map.get(&1, :title) == "Issue prompt")) |> List.last()
    Enum.map(messages, &entry(&1, row, &1 == last_prompt))
  end

  @spec projection([map()]) :: [map()]
  def projection(messages) do
    Enum.map(messages, fn message ->
      base = %{id: text(Map.get(message, :id, "")), at: timestamp(Map.get(message, :occurred_at))}

      case Map.get(message, :role) do
        "agent" -> Map.merge(base, %{k: "say", text: text(Map.get(message, :body, ""))})
        "operator" -> Map.merge(base, %{k: "op", text: text(Map.get(message, :body, ""))})
        "tool" -> Map.merge(base, %{k: "tool", name: text(Map.get(message, :title, "")), arg: first_line(Map.get(message, :body, "")), res: ""})
        _ -> Map.merge(base, %{k: "sys", text: text(Map.get(message, :title, ""))})
      end
    end)
  end

  defp entry(message, row, last_prompt?) do
    answer? = message[:role] == "user" and message[:title] == "Executor" and is_binary(message[:action_id])
    id = if answer?, do: "answer:#{message.action_id}", else: Map.get(message, :id, "")
    base = %{id: text(id), at: timestamp(Map.get(message, :timestamp))}
    base = if answer?, do: Map.put(base, :cursor, message.id), else: base
    Map.merge(base, content(message, row, last_prompt?))
  end

  defp content(%{role: "assistant", body: body}, _, _), do: %{k: "say", text: text(body)}
  defp content(%{role: "user", title: "Executor", body: body}, _, _), do: %{k: "op", text: text(body)}
  defp content(%{role: "user", title: "Issue prompt"}, row, last?), do: %{k: "sys", text: pickup(row, last?)}
  defp content(%{role: "tool"} = message, _, _), do: tool(message)
  defp content(%{role: "alert"} = message, _, _), do: %{k: "sys", text: text("Alert · #{message[:alert_name] || message[:title]}")}
  defp content(%{role: "system", title: "Warning", body: body}, _, _), do: %{k: "sys", text: "Warning · " <> String.slice(first_line(body), 0, 120)}
  defp content(message, _, _), do: %{k: "sys", text: text(Map.get(message, :title, ""))}

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

  defp tool(message) do
    body = text(Map.get(message, :body, ""))
    [command | _] = String.split(body, ~r/\nexit -?\d+/, parts: 2)
    command = String.replace_prefix(command, "$ ", "")
    arg = first_line(command) <> if(String.contains?(command, "\n"), do: " …", else: "")

    exit_code =
      case Regex.run(~r/\nexit (-?\d+)/, body) do
        [_, code] -> code
        _ -> "unknown"
      end

    res = if message[:title] == "Command output", do: "✗ auth failure", else: "✗ exit #{exit_code}"
    %{k: "tool", name: "bash", arg: arg, res: res, bad: true}
  end

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
