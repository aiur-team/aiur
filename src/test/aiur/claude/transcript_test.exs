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
      assert event.msg_id == "i1"
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

    test "passes a pre-extracted REPL transcript_event straight through" do
      event = Aiur.AgentEvents.transcript_event(:assistant, "from the repl", turn_id: "turn-z")
      message = %{event: :transcript, transcript_event: event}

      assert {:ok, ^event} = Transcript.extract(message, "fallback")
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
    alias Aiur.Opencode.ChatCompletions.DeltaRenderer

    test "Edit renders a fenced diff with red/green +/- lines" do
      message =
        item_created(%{
          "id" => "e1",
          "type" => "tool_call",
          "name" => "Edit",
          "input" => %{"file_path" => "lib/aiur.ex", "old_string" => "foo", "new_string" => "bar"}
        })

      assert {:ok, event} = Transcript.extract(message, nil)
      rendered = DeltaRenderer.format_delta(event.role, event.body, event)

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
      rendered = DeltaRenderer.format_delta(event.role, event.body, event)

      assert rendered =~ "```diff"
      assert rendered =~ "+ line one"
    end
  end

  # On-disk transcript jsonl records (the interactive-REPL backend tails the
  # file rather than the JSON-RPC stream). Shapes captured from a real
  # `~/.claude/projects/<slug>/<uuid>.jsonl`.
  defp assistant_record(content_blocks, opts \\ []) do
    %{
      "type" => "assistant",
      "timestamp" => Keyword.get(opts, :timestamp, "2026-06-08T12:00:00.000Z"),
      "sessionId" => Keyword.get(opts, :session_id, "sess-uuid"),
      "message" => %{
        "role" => "assistant",
        "stop_reason" => Keyword.get(opts, :stop_reason, "tool_use"),
        "content" => content_blocks
      }
    }
  end

  defp user_record(content) do
    %{
      "type" => "user",
      "timestamp" => "2026-06-08T12:00:01.000Z",
      "message" => %{"role" => "user", "content" => content}
    }
  end

  describe "extract_disk_record/2 — on-disk transcript shape" do
    test "assistant text block → one :assistant event with parsed timestamp" do
      record =
        assistant_record([%{"type" => "text", "text" => "All set."}],
          timestamp: "2026-06-08T12:34:56.000Z"
        )

      assert [event] = Transcript.extract_disk_record(record, "turn-1")
      assert event.role == :assistant
      assert event.body == "All set."
      assert event.turn_id == "turn-1"
      assert event.timestamp == ~U[2026-06-08 12:34:56.000Z]
    end

    test "assistant thinking block → :reasoning" do
      record = assistant_record([%{"type" => "thinking", "thinking" => "Considering.", "signature" => "x"}])

      assert [event] = Transcript.extract_disk_record(record, "turn-1")
      assert event.role == :reasoning
      assert event.body == "Considering."
    end

    test "assistant Bash tool_use → :command" do
      record =
        assistant_record([
          %{"type" => "tool_use", "name" => "Bash", "id" => "t1", "input" => %{"command" => "ls -la"}}
        ])

      assert [event] = Transcript.extract_disk_record(record, "turn-1")
      assert event.role == :command
      assert event.body == "ls -la"
      assert event.payload.command == "ls -la"
    end

    test "assistant Edit tool_use → :tool with a diff payload" do
      record =
        assistant_record([
          %{
            "type" => "tool_use",
            "name" => "Edit",
            "id" => "t2",
            "input" => %{"file_path" => "lib/a.ex", "old_string" => "foo", "new_string" => "bar"}
          }
        ])

      assert [event] = Transcript.extract_disk_record(record, "turn-1")
      assert event.role == :tool
      assert event.payload.output =~ "- foo"
      assert event.payload.output =~ "+ bar"
    end

    test "a multi-block assistant record yields one event per renderable block" do
      record =
        assistant_record([
          %{"type" => "text", "text" => "Running it."},
          %{"type" => "tool_use", "name" => "Bash", "id" => "t3", "input" => %{"command" => "mix test"}},
          %{"type" => "image", "source" => %{}}
        ])

      events = Transcript.extract_disk_record(record, "turn-1")
      assert length(events) == 2
      assert Enum.map(events, & &1.role) == [:assistant, :command]
    end

    test "assistant disk ids combine the stable record UUID with block identity or index" do
      first =
        assistant_record([
          %{"type" => "text", "text" => "same body"},
          %{"type" => "text", "text" => "same body"}
        ])
        |> Map.put("uuid", "record-one")

      second =
        assistant_record([%{"type" => "text", "text" => "same body"}])
        |> Map.put("uuid", "record-two")

      [first_block, second_block] = Transcript.extract_disk_record(first, "turn-1")
      [other_record] = Transcript.extract_disk_record(second, "turn-1")
      [replayed_first, replayed_second] = Transcript.extract_disk_record(first, "turn-1")

      assert first_block.msg_id != second_block.msg_id
      assert first_block.msg_id != other_record.msg_id
      assert replayed_first.msg_id == first_block.msg_id
      assert replayed_second.msg_id == second_block.msg_id
      assert first_block.msg_id =~ "record-one:text:0"
      assert other_record.msg_id =~ "record-two:text:0"
    end

    test "user tool_result (string content) → :tool output" do
      record =
        user_record([
          %{"type" => "tool_result", "tool_use_id" => "t1", "content" => "exit 0\nok"}
        ])

      assert [event] = Transcript.extract_disk_record(record, "turn-1")
      assert event.role == :tool
      assert event.payload.output == "exit 0\nok"
    end

    test "user tool_result (list content) flattens text blocks into output" do
      record =
        user_record([
          %{
            "type" => "tool_result",
            "tool_use_id" => "t1",
            "content" => [%{"type" => "text", "text" => "line A"}, %{"type" => "text", "text" => "line B"}]
          }
        ])

      assert [event] = Transcript.extract_disk_record(record, "turn-1")
      assert event.payload.output == "line A\nline B"
    end

    test "a bare user prompt string → one :user event (operator's typed message)" do
      assert [event] = Transcript.extract_disk_record(user_record("please fix the bug"), "turn-1")
      assert event.role == :user
      assert event.body == "please fix the bug"
      assert event.turn_id == "turn-1"
    end

    test "an empty user prompt string yields no events" do
      assert [] = Transcript.extract_disk_record(user_record(""), "turn-1")
    end

    test "a queued_command attachment → one :user event (Claude Remote Control message)" do
      record = %{
        "type" => "attachment",
        "timestamp" => "2026-06-10T20:38:33.461Z",
        "attachment" => %{
          "type" => "queued_command",
          "commandMode" => "prompt",
          "prompt" => "hi from claude remote control app"
        }
      }

      assert [event] = Transcript.extract_disk_record(record, "turn-1")
      assert event.role == :user
      assert event.body == "hi from claude remote control app"
      assert event.turn_id == "turn-1"
    end

    test "a slash-command attachment is skipped (control input, not chat)" do
      record = %{
        "type" => "attachment",
        "attachment" => %{
          "type" => "queued_command",
          "commandMode" => "command",
          "prompt" => "/compact"
        }
      }

      assert [] = Transcript.extract_disk_record(record, "turn-1")
    end

    test "non-conversational records are skipped" do
      for type <- ~w(bridge-session system file-history-snapshot ai-title last-prompt permission-mode attachment queue-operation pr-link) do
        assert [] = Transcript.extract_disk_record(%{"type" => type, "message" => %{}}, "turn-1")
      end
    end
  end
end
