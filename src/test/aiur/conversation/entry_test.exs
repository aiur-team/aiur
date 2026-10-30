defmodule Aiur.Conversation.EntryTest do
  use ExUnit.Case, async: true
  alias Aiur.Conversation.Entry

  test "assistant deltas skipped; complete messages and reasoning retained" do
    assert :skip = Entry.from_transcript_event(%{role: :assistant, kind: :assistant_delta, body: "part"})
    assert {:ok, %Entry{kind: "message", role: "agent", body: "done"}} = Entry.from_transcript_event(%{role: :assistant, body: "done"})
    assert {:ok, %Entry{kind: "reasoning", body: "thought"}} = Entry.from_transcript_event(%{role: :reasoning, body: "thought"})
  end

  test "worker user input needs delivery evidence to become operator input" do
    event = %{role: :user, body: "hello", msg_id: "m1", payload: %{}}
    assert {:ok, provider} = Entry.from_transcript_event(event)
    assert {provider.kind, provider.role, provider.meta} == {"system", "provider_input", %{provider_role: "user"}}
    assert {:ok, operator} = Entry.from_transcript_event(%{event | payload: %{delivery_id: "d1"}})
    assert {operator.kind, operator.role, operator.refs.delivery_id} == {"operator_message", "operator", "d1"}
    refute Entry.dedup_key(provider) == Entry.dedup_key(operator)
    assert {:ok, %Entry{role: "executor_operator"}} = Entry.from_transcript_event(event, subject_kind: :executor)
  end

  test "command and tools preserve outputs, metadata and call references" do
    assert {:ok, command} =
             Entry.from_transcript_event(%{role: :command, body: "display", msg_id: "call1", turn_id: "turn", payload: %{command: "ls", output: "files", workdir: "/repo", exit_code: 1}})

    assert {command.kind, command.body, command.output, command.meta} == {"command", "ls", "files", %{cwd: "/repo", exit_code: 1}}
    assert command.refs == %{provider_msg_id: "call1", tool_call_id: "call1", turn_id: "turn"}
    assert {:ok, diff} = Entry.from_transcript_event(%{role: :tool, payload: %{tool: "edit", title: "edit a", output: "patch", tool_call_id: "call2"}})
    assert {diff.kind, diff.body, diff.output, diff.refs.tool_call_id} == {"diff", "edit a", "patch", "call2"}
    assert {:ok, tool} = Entry.from_transcript_event(%{role: :tool, body: "search", payload: %{tool: "rg", output: "match", success: false}})
    assert {tool.kind, tool.role, tool.body, tool.output, tool.meta} == {"tool_result", "tool", "search", "match", %{tool: "rg", success: false}}
    assert {:ok, %Entry{kind: "system", role: "system", meta: %{alert: true}}} = Entry.from_transcript_event(%{role: :alert, body: "alert"})
  end

  test "dedup precedence and fallback timestamp" do
    entry = %Entry{role: "agent", body: "same", occurred_at: "2026-01-01T00:00:00Z", refs: %{turn_id: "t"}}
    refute Entry.dedup_key(entry) == Entry.dedup_key(%{entry | occurred_at: "2026-01-01T00:00:01Z"})
    call = %{entry | refs: %{tool_call_id: "call"}}
    item = %{entry | refs: %{tool_call_id: "call", provider_item_id: "item"}}
    msg = %{entry | refs: %{tool_call_id: "call", provider_item_id: "item", provider_msg_id: "msg"}}
    assert Entry.dedup_key(call) == Entry.dedup_key(%{call | body: "changed"})
    assert Entry.dedup_key(item) == Entry.dedup_key(%{item | refs: %{provider_item_id: "item", tool_call_id: "other"}})
    assert Entry.dedup_key(msg) == Entry.dedup_key(%{msg | refs: %{provider_msg_id: "msg"}})
    assert length(Enum.uniq(Enum.map([entry, call, item, msg], &Entry.dedup_key/1))) == 4
  end

  test "mixed bounds preserve capped UTF-8 ends and exact omission counts" do
    text = "a" <> String.duplicate("😀", 51_200) <> "z"

    for {kind, cap, limit} <- [{"message", 16_384, 65_536}, {"diff", 16_384, 65_536}, {"command", 4096, 16_384}, {"tool_result", 4096, 16_384}] do
      entry = Entry.bound(%Entry{kind: kind, body: text, output: text})
      [first, omitted, last] = Regex.run(~r/\A(.*)\n…\[(\d+) bytes omitted\]…\n(.*)\z/su, entry.body, capture: :all_but_first)
      assert String.starts_with?(first, "a")
      assert String.ends_with?(last, "z")
      assert byte_size(first) in (cap - 3)..cap
      assert byte_size(last) in (cap - 3)..cap
      assert binary_part(text, 0, byte_size(first)) == first
      assert binary_part(text, byte_size(text) - byte_size(last), byte_size(last)) == last
      assert String.to_integer(omitted) == byte_size(text) - byte_size(first) - byte_size(last)
      assert byte_size(entry.body) <= limit
      assert String.valid?(entry.body)
      assert entry.body_truncated
      assert entry.output_truncated
      assert entry.output == entry.body
      exact = String.duplicate("x", limit)
      assert %{body: ^exact, body_truncated: false} = Entry.bound(%Entry{kind: kind, body: exact})
    end
  end

  test "invalid UTF-8 replaced; JSON codecs retain fields and reject invalid records" do
    assert {:ok, entry} = Entry.from_transcript_event(%{role: :assistant, body: <<97, 255, 98>>, msg_id: "m"})
    assert entry.body == "a�b"
    entry = %{entry | meta: %{exit_code: 0, success: false, provider_role: "user"}}
    assert {:ok, decoded} = entry |> Entry.to_json() |> Jason.encode!() |> Entry.from_json()
    assert decoded == entry
    assert {:error, :invalid_entry} = Entry.from_json(%{"v" => 2, "kind" => "message", "role" => "agent", "body" => "x"})
    assert {:error, :invalid_entry} = Entry.from_json(%{"kind" => "invented", "role" => "agent"})
    assert {:error, :invalid_entry} = Entry.from_json(Map.delete(Entry.to_json(entry), "v"))
    assert {:error, :invalid_entry} = Entry.from_json(Map.put(Entry.to_json(entry), "refs", %{"provider_msg_id" => 42}))
    assert {:error, :invalid_entry} = Entry.from_json("bad json")
  end
end
