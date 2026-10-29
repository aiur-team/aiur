defmodule AiurWeb.Build.ConversationSource.JournalEntries do
  @moduledoc false
  alias AiurWeb.Build.ConversationSource.Entries

  @spec map_entries([map()], String.t()) :: [map()]
  def map_entries(entries, id) do
    Enum.map(entries, fn entry ->
      base = %{id: "journal:#{id}:#{entry.pos}", at: Entries.timestamp(entry.occurred_at || entry.observed_at)}
      Map.merge(base, content(entry))
    end)
  end

  defp content(%{kind: "message", role: "agent", body: body}), do: %{k: "say", text: text(body)}
  defp content(%{kind: "operator_message", body: body}), do: %{k: "op", text: text(body)}
  defp content(%{kind: "system", role: "provider_input"}), do: %{k: "sys", text: "Picked up"}
  defp content(%{kind: "gap", body: body}), do: %{k: "sys", text: text("No record · " <> body)}

  defp content(%{kind: "diff", body: body, output: output}), do: %{k: "sys", text: text(body <> "\n" <> (output || ""))}

  defp content(%{kind: kind} = entry) when kind in ["command", "tool_result"] do
    meta = entry.meta
    code = meta[:exit_code] || meta["exit_code"]
    bad = (is_integer(code) and code != 0) or meta[:success] == false or meta["success"] == false
    %{k: "tool", name: if(kind == "command", do: "bash", else: text(meta[:tool] || meta["tool"] || "tool")), arg: text(entry.body), res: text(entry.output), bad: bad}
  end

  defp content(%{body: body}), do: %{k: "sys", text: text(body)}

  defp text(nil), do: ""
  defp text(value), do: if(String.length(value) > 8_000, do: String.slice(value, 0, 7_999) <> "…", else: value)
end
