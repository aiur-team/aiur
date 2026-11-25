defmodule Aiur.Codex.RolloutTranscriptTest do
  use ExUnit.Case, async: true

  alias Aiur.Codex.RolloutTranscript

  @fixture Path.expand("../../fixtures/codex_rollouts/0.171/tui-main.jsonl", __DIR__)

  test "pins the captured Codex version and maps only completed rollout items" do
    records = File.stream!(@fixture) |> Enum.map(&Jason.decode!/1)
    assert RolloutTranscript.version_status(hd(records)) == :tested
    assert RolloutTranscript.version_status(%{"type" => "session_meta", "payload" => %{"cli_version" => "0.172.0"}}) == :untested

    events = Enum.flat_map(records, &RolloutTranscript.extract/1)
    assert Enum.map(events, & &1.role) == [:user, :assistant, :command, :assistant, :user, :assistant, :command, :command, :command, :assistant, :user, :assistant, :assistant]
    assert Enum.all?(events, &(is_binary(&1.msg_id) and &1.msg_id != ""))
    assert hd(events).turn_id != nil
    assert Enum.at(events, 2).payload == %{command: "<redacted> <redacted> <redacted>", output: "<redacted>", exit_code: 0, workdir: "<redacted>"}
  end

  test "unsupported first layout and incomplete records produce no events" do
    assert [] = RolloutTranscript.extract(%{"type" => "response_item", "payload" => %{"type" => "message"}})
    assert [] = RolloutTranscript.extract(%{"type" => "event_msg", "payload" => %{"type" => "item_started", "item" => %{"type" => "AgentMessage"}}})
    assert RolloutTranscript.version_status(%{"type" => "session_meta", "payload" => %{}}) == :absent
    assert RolloutTranscript.extract_file([%{"type" => "response_item"}]) == {:error, :unsupported}
    assert {:error, :unsupported} = RolloutTranscript.extract_file([%{"type" => "session_meta", "payload" => %{"cli_version" => "0.172.0"}}, %{"type" => "event_msg"}])
  end

  test "maps reasoning, edits, tool calls and compaction with stable item ids" do
    base = %{"type" => "event_msg", "timestamp" => "2026-11-20T06:33:36.144Z", "payload" => %{"type" => "item_completed", "turn_id" => "turn-1"}}
    item = fn fields -> Map.put(base, "payload", Map.merge(base["payload"], %{"item" => fields})) end

    assert [%{role: :reasoning, body: "summary", msg_id: "r"}] =
             RolloutTranscript.extract(item.(%{"type" => "Reasoning", "id" => "r", "summary_text" => [%{"text" => "summary"}], "raw_content" => "raw"}))

    assert [%{role: :tool, payload: %{tool: "edit", output: "diff"}, msg_id: "f"}] = RolloutTranscript.extract(item.(%{"type" => "FileChange", "id" => "f", "changes" => [%{"diff" => "diff"}]}))
    assert [%{role: :tool, body: "search", msg_id: "t"}] = RolloutTranscript.extract(item.(%{"type" => "McpToolCall", "id" => "t", "tool" => "search"}))
    assert [%{role: :system, body: "Context compacted", payload: %{session_boundary: "compact"}}] = RolloutTranscript.extract(item.(%{"type" => "ContextCompaction", "id" => "c"}))
  end
end
