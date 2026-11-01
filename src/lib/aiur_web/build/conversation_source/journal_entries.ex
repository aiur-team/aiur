defmodule AiurWeb.Build.ConversationSource.JournalEntries do
  @moduledoc false
  alias AiurWeb.Build.ConversationSource.Entries

  @spec map_entries([map()], String.t(), String.t() | nil) :: [map()]
  def map_entries(entries, id, workspace \\ nil) do
    Enum.map(entries, fn entry ->
      base = %{id: "journal:#{id}:#{entry.pos}", at: Entries.timestamp(entry.occurred_at || entry.observed_at)}
      Map.merge(base, content(entry, workspace))
    end)
  end

  defp content(%{kind: "message", role: "agent", body: body}, _workspace), do: %{k: "say", text: text(body)}
  defp content(%{kind: "operator_message", body: body}, _workspace), do: %{k: "op", text: text(body)}
  defp content(%{kind: "system", role: "provider_input"}, _workspace), do: %{k: "sys", text: "Picked up"}
  defp content(%{kind: "gap", body: body}, _workspace), do: %{k: "sys", text: text("No record · " <> body)}

  defp content(%{kind: "diff", body: body, output: output}, workspace) do
    file = relative_path(body, workspace)
    diff = text(output)
    {added, removed} = line_counts(diff)
    %{k: "diff", file: file, lines: diff_lines(diff), add: added, del: removed, summary: "#{file} · +#{added} −#{removed}"}
  end

  defp content(%{kind: kind} = entry, workspace) when kind in ["command", "tool_result"] do
    meta = entry.meta
    code = meta[:exit_code] || meta["exit_code"]
    bad = (is_integer(code) and code != 0) or meta[:success] == false or meta["success"] == false
    name = if(kind == "command", do: "bash", else: text(meta[:tool] || meta["tool"] || "tool"))
    arg = relative_path(entry.body, workspace)
    output = relative_text(entry.output, workspace)

    tool_content(name, arg, output, code, bad, workspace)
  end

  defp content(%{body: body}, _workspace), do: %{k: "sys", text: text(body)}

  defp tool_content("edit" = name, arg, output, code, bad, workspace) do
    {added, removed} = line_counts(output)
    file = edit_path(arg, output, workspace)
    %{k: "tool", name: name, arg: file, res: output, summary: "#{file} · +#{added} −#{removed}", bad: bad, status: status(code, bad)}
  end

  defp tool_content("write" = name, arg, output, code, bad, workspace) do
    file = arg |> text() |> String.replace_prefix("write ", "") |> relative_path(workspace)
    summary = if file == "", do: first_line(output), else: file <> if(first_line(output) == "", do: "", else: " · " <> first_line(output))
    %{k: "tool", name: name, arg: file, res: output, summary: summary, bad: bad, status: status(code, bad)}
  end

  defp tool_content(name, arg, output, code, bad, workspace) do
    summary = Enum.find([first_line(output), first_line(arg)], &(&1 != "")) || "No result"
    %{k: "tool", name: name, arg: relative_text(text(arg), workspace), res: output, summary: summary, bad: bad, status: status(code, bad)}
  end

  defp edit_path(arg, output, workspace) do
    case diff_path(output, workspace) do
      "Edited file" when arg != "" -> relative_path(arg, workspace)
      path -> path
    end
  end

  defp diff_lines(""), do: []
  defp diff_lines(diff), do: diff |> String.split("\n") |> Enum.map(fn line -> [String.slice(line, 0, 1), line] end)

  defp line_counts(diff) do
    lines = String.split(diff || "", "\n")
    {Enum.count(lines, &(String.starts_with?(&1, "+") and not String.starts_with?(&1, "+++"))), Enum.count(lines, &(String.starts_with?(&1, "-") and not String.starts_with?(&1, "---")))}
  end

  defp diff_path(output, workspace) do
    case Regex.run(~r/(?:Update|Add|Delete) File:\s*(.+)/, output || "") do
      [_, path] -> relative_path(path, workspace)
      _ -> unified_diff_path(output, workspace)
    end
  end

  defp unified_diff_path(output, workspace) do
    case Regex.run(~r/^\+\+\+ b\/(.+)$/m, output || "") do
      [_, path] -> relative_path(path, workspace)
      _ -> "Edited file"
    end
  end

  defp relative_path(path, workspace) when is_binary(path) and is_binary(workspace) do
    path = String.trim(path)
    if path == workspace, do: ".", else: relative_text(path, workspace)
  end

  defp relative_path(path, _workspace), do: text(path)
  defp relative_text(value, workspace) when is_binary(value) and is_binary(workspace), do: String.replace(value, workspace <> "/", "")
  defp relative_text(value, _workspace), do: text(value)
  defp first_line(value), do: value |> text() |> String.split("\n", parts: 2) |> hd()
  defp status(code, true) when is_integer(code), do: "Exit #{code}"
  defp status(_code, true), do: "Failed"
  defp status(_code, false), do: ""

  defp text(nil), do: ""
  defp text(value), do: if(String.length(value) > 8_000, do: String.slice(value, 0, 7_999) <> "…", else: value)
end
