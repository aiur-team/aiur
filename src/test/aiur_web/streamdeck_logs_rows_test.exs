defmodule AiurWeb.StreamdeckLogsRowsTest do
  use ExUnit.Case, async: true

  alias AiurWeb.StreamdeckLogs

  # #1960: the row class drives the per-kind colour on both the emulator and the
  # device, so the mapping lives once in the projection and both renderers read
  # it. Commands and tool rows are one class (the agent acting on an external
  # surface); agent prose is another; system/reasoning/alert are the "logs"
  # class; the user turn is its own.
  describe "row_kind/1" do
    test "maps roles to the three visual classes plus the user turn" do
      assert StreamdeckLogs.row_kind("command") == :command
      assert StreamdeckLogs.row_kind(:tool) == :command
      assert StreamdeckLogs.row_kind("assistant") == :agent
      assert StreamdeckLogs.row_kind(:user) == :user
      assert StreamdeckLogs.row_kind("system") == :logs
      assert StreamdeckLogs.row_kind("reasoning") == :logs
      assert StreamdeckLogs.row_kind("ci") == :logs
      # Unknown roles are not the agent's prose; they are logs.
      assert StreamdeckLogs.row_kind("mystery") == :logs
    end
  end

  describe "glyph/2" do
    test "reads the verb off the raw tool body for the gutter glyph" do
      assert StreamdeckLogs.glyph(:tool, "read lib/a.ex") == "→"
      assert StreamdeckLogs.glyph("tool", "write lib/b.ex") == "←"
      assert StreamdeckLogs.glyph("tool", "edit lib/c.ex") == "←"
    end

    test "gives a generic tool the ⚙ fallback and commands the $ mark" do
      assert StreamdeckLogs.glyph("tool", "emit_alert") == "⚙"
      assert StreamdeckLogs.glyph("command", "mix test") == "$"
    end

    test "prose and other kinds have no glyph" do
      assert StreamdeckLogs.glyph("assistant", "hello") == nil
      assert StreamdeckLogs.glyph("system", "CI passed") == nil
      assert StreamdeckLogs.glyph("user", "please") == nil
    end
  end

  describe "tool_display/1" do
    test "strips the verb prefix because the glyph carries it" do
      assert StreamdeckLogs.tool_display("read lib/a.ex") == "lib/a.ex"
      assert StreamdeckLogs.tool_display("edit lib/b.ex") == "lib/b.ex"
      assert StreamdeckLogs.tool_display("write lib/c.ex") == "lib/c.ex"
    end

    test "leaves a body without a verb prefix untouched" do
      assert StreamdeckLogs.tool_display("lib/a.ex") == "lib/a.ex"
      assert StreamdeckLogs.tool_display("ran the tests") == "ran the tests"
      assert StreamdeckLogs.tool_display(nil) == nil
    end
  end

  test "renders each flattened row as a line" do
    assert StreamdeckLogs.line(%{kind: :event_header, badge: "EMIT", body: "opened"}) == "[EMIT] opened"
    assert StreamdeckLogs.line(%{kind: :message, role: "assistant", body: "hi"}) == "[assistant] hi"
    # A hunk line keeps its sign: it is the only thing saying added or removed.
    assert StreamdeckLogs.line(%{kind: :diff_line, sign: "+", text: "  ok"}) == "+  ok"
    assert StreamdeckLogs.line(%{kind: :diff_line, sign: " ", text: "  same"}) == "   same"
    assert StreamdeckLogs.line(%{kind: :diff, path: nil, additions: 1, deletions: 2, line: "+x"}) == "[diff] changed file +1 -2 +x"
    assert StreamdeckLogs.line(%{kind: :mystery}) == "[INFO]"
  end

  # #1960: the projected message carries `row_kind`/`glyph`/`tool` so the
  # device DTO and the emulator agree, and the body shows the command or path
  # (verb stripped) rather than the tool name.
  # The projection reverses newest-first input to oldest-first, so the feed is
  # given newest-first (assistant turn at t2, tool call at t1) and the message
  # rows come out oldest-first.
  test "projects tool rows with the path, row class, and glyph" do
    logs =
      StreamdeckLogs.project(%{
        events: [],
        transcript: [
          %{type: "message", role: "assistant", body: "done", tool: nil, timestamp: "2026-08-02T00:02:00Z"},
          %{type: "message", role: "tool", body: "read lib/a.ex", tool: "read_file", timestamp: "2026-08-02T00:01:00Z"}
        ]
      })

    [tool, prose] = Enum.filter(logs.transcript, &(&1.kind == :message))

    assert tool.row_kind == :command
    assert tool.glyph == "→"
    assert tool.tool == "read_file"
    assert tool.body == "lib/a.ex"

    assert prose.row_kind == :agent
    assert prose.glyph == nil
    assert prose.body == "done"
  end
end
