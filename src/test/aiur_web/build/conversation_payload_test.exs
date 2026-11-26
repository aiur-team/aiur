defmodule AiurWeb.Build.ConversationPayloadTest do
  use ExUnit.Case, async: true
  alias AiurWeb.Build.{ConversationPayload, Payload}

  test "conversation envelopes preserve unknown values and validate every kind" do
    entry = %{id: "a:0", k: "say", at: nil, text: "<img onerror='bad'>"}
    view = %{state: :stale, live?: false, observed_at: nil, entries: [entry], more?: true, before: "a:0"}
    message = ConversationPayload.view("12", view)
    assert message["observed_at"] == nil
    assert message["entries"] == [%{"id" => "a:0", "k" => "say", "at" => nil, "text" => "<img onerror='bad'>"}]
    assert Payload.validate(message) == :ok

    for extra <- [
          %{kind: "conversation-earlier", entries: [entry], before: "a:0", more: true},
          %{kind: "conversation-append", entries: [entry], gap: true},
          %{kind: "conversation-state", state: "restart_unknown", live: false, observed_at: nil}
        ] do
      assert Payload.validate(Map.merge(%{v: 1, id: "12"}, extra)) == :ok
    end
  end

  test "strict entry schema refuses private data, bad kinds, timestamps and oversized text" do
    view = %{state: :live, live?: true, entries: [%{id: "a:0", k: "say", at: nil, text: "hello"}], more?: false}
    message = ConversationPayload.view("12", view)
    assert Payload.validate(message) == :ok

    for entry <- [
          %{"id" => "a:0", "k" => "say", "at" => 0, "text" => "hello", "workspace" => "/private"},
          %{"id" => "a:0", "k" => "wat", "at" => nil, "text" => "hello"},
          %{"id" => "a:0", "k" => "say", "at" => "now", "text" => "hello"},
          %{"id" => "a:0", "k" => "say", "at" => nil, "text" => String.duplicate("x", 8_002)}
        ] do
      assert {:error, [_ | _]} = Payload.validate(Map.put(message, "entries", [entry]))
    end

    assert {:error, [_ | _]} = Payload.validate(Map.put(message, "id", "pack:bad"))
    assert {:error, [_ | _]} = Payload.validate(Map.put(message, "note", "invented"))
  end

  test "design event and diff rows are typed without permitting arbitrary event names" do
    entries = [
      %{id: "d:0", k: "ev", at: 12, ev: "commit", label: "Committed", sub: "fix", go: "12"},
      %{id: "d:1", k: "diff", at: 13, file: "file.ex", lines: [["+", "hello"]], add: 1, del: 0},
      %{id: "d:2", cursor: "ab:42", k: "tool", at: nil, name: "bash", arg: "false", res: "exit 1", bad: true}
    ]

    message = %{v: 1, kind: "conversation-append", id: "12", entries: entries, gap: false}
    assert Payload.validate(message) == :ok
    assert {:error, [_ | _]} = Payload.validate(put_in(message, [:entries, Access.at(0), :ev], "unknown"))
  end
end
