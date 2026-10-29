defmodule AiurWeb.Build.ConversationSource.JournalEntriesTest do
  use ExUnit.Case, async: true
  alias AiurWeb.Build.Payload
  alias AiurWeb.Build.ConversationSource.JournalEntries

  test "journal kinds project to validated deck and modal rows without provider prompts" do
    now = DateTime.utc_now()
    base = %{pos: 1, role: "agent", kind: "message", body: "reply", output: nil, meta: %{}, observed_at: now, occurred_at: nil}

    rows = [
      {%{}, %{k: "say", text: "reply"}},
      {%{kind: "operator_message", role: "operator"}, %{k: "op", text: "reply"}},
      {%{kind: "system", role: "provider_input", body: "PRIVATE_PROMPT"}, %{k: "sys", text: "Picked up"}},
      {%{kind: "reasoning"}, %{k: "sys", text: "reply"}},
      {%{kind: "system"}, %{k: "sys", text: "reply"}},
      {%{kind: "gap", body: "pre-journal"}, %{k: "sys", text: "No record · pre-journal"}},
      {%{kind: "diff", body: "file.ex", output: "+new"}, %{k: "sys", text: "file.ex\n+new"}},
      {%{kind: "command", body: "echo ok", output: "ok", meta: %{exit_code: 0}}, %{k: "tool", name: "bash", arg: "echo ok", res: "ok", bad: false}},
      {%{kind: "command", meta: %{"exit_code" => 2}}, %{k: "tool", name: "bash", arg: "reply", res: "", bad: true}},
      {%{kind: "tool_result", meta: %{tool: "search", success: false}}, %{k: "tool", name: "search", arg: "reply", res: "", bad: true}}
    ]

    for {changes, content} <- rows do
      [entry] = JournalEntries.map_entries([Map.merge(base, changes)], "conv-test")
      assert entry == Map.merge(%{id: "journal:conv-test:1", at: DateTime.to_unix(now, :millisecond)}, content)
      assert Payload.validate(%{v: 1, kind: "conversation-append", id: "7", entries: [entry], gap: false}) == :ok
    end
  end

  test "wire text is bounded while stable IDs and occurred timestamps are preserved" do
    now = DateTime.utc_now()
    entry = %{pos: 99, kind: "message", role: "agent", body: String.duplicate("é", 8_100), output: nil, meta: %{}, occurred_at: DateTime.to_iso8601(now), observed_at: nil}
    [row] = JournalEntries.map_entries([entry], "conv-test")
    assert row.id == "journal:conv-test:99"
    assert row.at == DateTime.to_unix(now, :millisecond)
    assert String.length(row.text) == 8_000
    assert String.ends_with?(row.text, "…")
  end
end
