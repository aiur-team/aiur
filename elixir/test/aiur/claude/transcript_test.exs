defmodule Aiur.Claude.TranscriptTest do
  use ExUnit.Case, async: true

  alias Aiur.Claude.Transcript

  # Claude app-server notifications arrive as string-keyed JSON with the
  # item flattened into params.item ({id, created_at, type, ...fields}).
  defp item_created(item, turn_id \\ "turn-1") do
    %{
      payload: %{
        "jsonrpc" => "2.0",
        "method" => "item/created",
        "params" => %{"turn_id" => turn_id, "item" => item}
      }
    }
  end

  describe "extract/2 — Claude notification shape" do
    test "text item → :assistant carrying Claude's own turn_id" do
      message = item_created(%{"id" => "i1", "type" => "text", "text" => "Done."}, "turn-aaa")

      assert {:ok, event} = Transcript.extract(message, "fallback")
      assert event.role == :assistant
      assert event.body == "Done."
      assert event.turn_id == "turn-aaa"
    end

    test "thinking item → :reasoning" do
      message = item_created(%{"id" => "i2", "type" => "thinking", "thinking" => "Let me check."})

      assert {:ok, event} = Transcript.extract(message, nil)
      assert event.role == :reasoning
      assert event.body == "Let me check."
    end

    test "Bash tool_call → :command with command payload" do
      message =
        item_created(%{
          "id" => "i3",
          "type" => "tool_call",
          "tool_use_id" => "tu_1",
          "name" => "Bash",
          "input" => %{"command" => "git status --short"}
        })

      assert {:ok, event} = Transcript.extract(message, nil)
      assert event.role == :command
      assert event.body == "git status --short"
      assert event.payload.command == "git status --short"
      assert event.payload.title == "git status --short"
      assert event.payload.output == ""
    end

    test "Edit tool_call → :tool with file-edit title and diff input" do
      input = %{
        "file_path" => "lib/aiur.ex",
        "old_string" => "foo",
        "new_string" => "bar"
      }

      message =
        item_created(%{
          "id" => "i4",
          "type" => "tool_call",
          "tool_use_id" => "tu_2",
          "name" => "Edit",
          "input" => input
        })

      assert {:ok, event} = Transcript.extract(message, nil)
      assert event.role == :tool
      # Lowercase `edit <path>` body + `tool: "edit"` so the chat pane's
      # format_delta diff branch fires, at parity with codex fileChange.
      assert event.body == "edit lib/aiur.ex"
      assert event.payload.tool == "edit"
      assert event.payload.input == input
      # `@@ <path> @@` header makes the chat pane treat this as a unified
      # diff and pass it through, so Glamour paints the markers — without
      # it the block is misread as raw content and markers double.
      assert event.payload.output =~ "@@ lib/aiur.ex @@"
      assert event.payload.output =~ "- foo"
      assert event.payload.output =~ "+ bar"
    end

    test "Write tool_call → :tool emits raw new-file contents (greened by chat pane)" do
      message =
        item_created(%{
          "id" => "i4b",
          "type" => "tool_call",
          "tool_use_id" => "tu_2b",
          "name" => "Write",
          "input" => %{"file_path" => "lib/new.ex", "content" => "line one\nline two"}
        })

      assert {:ok, event} = Transcript.extract(message, nil)
      assert event.body == "edit lib/new.ex"
      assert event.payload.tool == "edit"
      # Marker-less content; the chat pane greens it as a whole-file create.
      assert event.payload.output == "line one\nline two"
      refute event.payload.output =~ "@@"
    end

    test "non-edit tool_call (skill / MCP) → :tool keyed by tool name" do
      message =
        item_created(%{
          "id" => "i5",
          "type" => "tool_call",
          "tool_use_id" => "tu_3",
          "name" => "Skill",
          "input" => %{"skill" => "ce-plan"}
        })

      assert {:ok, event} = Transcript.extract(message, nil)
      assert event.role == :tool
      assert event.body == "Skill"
      assert event.payload.tool == "Skill"
      assert event.payload.input == %{"skill" => "ce-plan"}
    end

    test "tool_result → :tool carrying the output (build log)" do
      message =
        item_created(%{
          "id" => "i6",
          "type" => "tool_result",
          "tool_use_id" => "tu_1",
          "content" => "?? test-sandbox/\n",
          "is_error" => false
        })

      assert {:ok, event} = Transcript.extract(message, nil)
      assert event.role == :tool
      assert event.payload.output == "?? test-sandbox/\n"
      assert event.payload.title == "tool result"
    end

    test "errored tool_result marks the title" do
      message =
        item_created(%{
          "id" => "i7",
          "type" => "tool_result",
          "tool_use_id" => "tu_9",
          "content" => "command not found",
          "is_error" => true
        })

      assert {:ok, event} = Transcript.extract(message, nil)
      assert event.role == :tool
      assert event.payload.title == "tool result (error)"
    end

    test "item/progress streaming deltas are skipped" do
      message = %{
        payload: %{
          "method" => "item/progress",
          "params" => %{"turn_id" => "t", "delta" => %{"type" => "text", "text" => "partial"}}
        }
      }

      assert :skip = Transcript.extract(message, nil)
    end

    test "turn lifecycle notifications are skipped" do
      message = %{payload: %{"method" => "turn/completed", "params" => %{"status" => "completed"}}}
      assert :skip = Transcript.extract(message, nil)
    end

    test "empty text item is skipped" do
      message = item_created(%{"id" => "i8", "type" => "text", "text" => ""})
      assert :skip = Transcript.extract(message, nil)
    end

    test "falls back to provided turn_id when params omit it" do
      message = %{
        payload: %{
          "method" => "item/created",
          "params" => %{"item" => %{"id" => "i9", "type" => "text", "text" => "hi"}}
        }
      }

      assert {:ok, event} = Transcript.extract(message, "fallback-turn")
      assert event.turn_id == "fallback-turn"
    end
  end

  # The chat pane renders a transcript event by piping it through
  # `ChatCompletions.format_delta/3`. The diff fence only fires when the
  # body starts with lowercase `edit ` AND `payload.tool == "edit"`, so
  # these guard against a casing/keying regression in extract/2 that the
  # field-level assertions above would miss.
  describe "extract/2 → chat format_delta rendering" do
    alias Aiur.Opencode.ChatCompletions

    test "Edit renders a fenced diff with red/green +/- lines" do
      message =
        item_created(%{
          "id" => "e1",
          "type" => "tool_call",
          "name" => "Edit",
          "input" => %{"file_path" => "lib/aiur.ex", "old_string" => "foo", "new_string" => "bar"}
        })

      assert {:ok, event} = Transcript.extract(message, nil)
      rendered = ChatCompletions.format_delta(event.role, event.body, event)

      assert rendered =~ "```diff"
      assert rendered =~ "- foo"
      assert rendered =~ "+ bar"
    end

    test "Write renders a fenced diff of the new file contents" do
      message =
        item_created(%{
          "id" => "e2",
          "type" => "tool_call",
          "name" => "Write",
          "input" => %{"file_path" => "lib/new.ex", "content" => "line one"}
        })

      assert {:ok, event} = Transcript.extract(message, nil)
      rendered = ChatCompletions.format_delta(event.role, event.body, event)

      assert rendered =~ "```diff"
      assert rendered =~ "+ line one"
    end
  end
end
