defmodule Aiur.OpenAICompat.TranscriptTest do
  use ExUnit.Case, async: true

  alias Aiur.OpenAICompat.Transcript

  test "extracts normalized assistant, reasoning, command, and tool events" do
    assert {:ok, %{role: :assistant, body: "done", msg_id: "msg-1"}} =
             Transcript.extract(%{event: :assistant, payload: %{text: "done", id: "msg-1"}}, "turn-1")

    assert {:ok, %{role: :reasoning, body: "thinking"}} =
             Transcript.extract(%{event: :reasoning, payload: %{text: "thinking"}}, "turn-1")

    assert {:ok, %{role: :command, body: "git status", payload: %{command: "git status"}}} =
             Transcript.extract(
               %{event: :tool_call, payload: %{id: "call-1", name: "exec_command", arguments: %{"command" => "git status"}}},
               "turn-1"
             )

    # A file tool's body carries the path, not the bare tool name — the Stream
    # Deck row shows the path while the glyph carries the read/ write/ edit
    # signal.
    assert {:ok, %{role: :tool, body: "read lib/aiur.ex", payload: %{tool: "read_file", input: %{"path" => "lib/aiur.ex"}}}} =
             Transcript.extract(
               %{event: :tool_call, payload: %{id: "call-2", name: "read_file", arguments: %{"path" => "lib/aiur.ex"}}},
               "turn-1"
             )

    # opencode renders one row per tool, muted on completion; the separate
    # tool_result echo (whose only content would be the bare tool name) is
    # dropped rather than persisted into the Stream Deck feed.
    assert :skip =
             Transcript.extract(
               %{event: :tool_result, payload: %{id: "call-2", name: "read_file", output: "contents", success: true}},
               "turn-1"
             )
  end

  test "a tool call with no scalar argument keeps its name as a deliberate fallback" do
    assert {:ok, %{role: :tool, body: "web_search"}} =
             Transcript.extract(
               %{event: :tool_call, payload: %{id: "call-3", name: "web_search", arguments: %{}}},
               "turn-1"
             )
  end

  test "skips usage and unknown events" do
    assert :skip = Transcript.extract(%{event: :usage, usage: %{}}, "turn")
    assert :skip = Transcript.extract(%{event: :unknown}, "turn")
  end
end
