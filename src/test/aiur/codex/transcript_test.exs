defmodule Aiur.Codex.TranscriptTest do
  use ExUnit.Case, async: true

  alias Aiur.Codex.Transcript

  describe "extract/2 — codex notification shape" do
    test "agentMessage item/completed → :assistant transcript with codex's own turn_id" do
      message = %{
        payload: %{
          method: "item/completed",
          params: %{
            turnId: "turn-aaa",
            item: %{type: "agentMessage", text: "Done.", id: "msg_1"}
          }
        }
      }

      assert {:ok, event} = Transcript.extract(message, "fallback")
      assert event.role == :assistant
      assert event.body == "Done."
      assert event.turn_id == "turn-aaa"
      assert event.msg_id == "msg_1"
    end

    test "agentMessage delta preserves its provider id and partial delivery marker" do
      message = %{
        payload: %{
          method: "item/agentMessage/delta",
          params: %{turnId: "turn-aaa", itemId: "msg_1", delta: "partial"}
        }
      }

      assert {:ok, %{role: :assistant, body: "partial", msg_id: "msg_1", kind: :assistant_delta, id: "msg_1"}} =
               Transcript.extract(message, "fallback")
    end

    test "commandExecution item/completed → :command with clean payload (no $ prefix, real output)" do
      message = %{
        payload: %{
          method: "item/completed",
          params: %{
            turnId: "turn-bbb",
            item: %{
              type: "commandExecution",
              command: "/bin/bash -lc \"git status --short\"",
              commandActions: [%{command: "git status --short"}],
              aggregatedOutput: "?? test-sandbox/\n",
              exitCode: 0,
              cwd: "/home/dev/repo"
            }
          }
        }
      }

      assert {:ok, event} = Transcript.extract(message, nil)
      assert event.role == :command
      assert event.body == "git status --short"
      refute String.starts_with?(event.body, "$ ")
      assert event.payload.command == "git status --short"
      assert event.payload.output == "?? test-sandbox/\n"
      assert event.payload.workdir == "/home/dev/repo"
      assert event.payload.title == "git status --short"
      assert event.turn_id == "turn-bbb"
    end

    test "commandExecution with non-zero exitCode includes exit code in title" do
      message = %{
        payload: %{
          method: "item/completed",
          params: %{
            item: %{
              type: "commandExecution",
              command: "false",
              commandActions: [%{command: "false"}],
              aggregatedOutput: "",
              exitCode: 1
            }
          }
        }
      }

      assert {:ok, event} = Transcript.extract(message, nil)
      assert event.payload.title == "false [exit=1]"
    end

    test "dynamicToolCall item/completed → :tool transcript with payload tool name" do
      message = %{
        payload: %{
          method: "item/completed",
          params: %{
            turnId: "turn-ccc",
            item: %{
              type: "dynamicToolCall",
              tool: "emit_alert",
              arguments: ~s({"name":"attention.x","message":"hi"}),
              contentItems: [%{text: "ok"}],
              status: "completed",
              success: true
            }
          }
        }
      }

      assert {:ok, event} = Transcript.extract(message, nil)
      assert event.role == :tool
      assert event.payload.tool == "emit_alert"
      assert event.payload.input == %{"name" => "attention.x", "message" => "hi"}
      assert event.payload.output == "ok"
      assert event.payload.title == "emit_alert"
    end

    test "fileChange item/completed → :tool transcript with tool: \"edit\"" do
      message = %{
        payload: %{
          method: "item/completed",
          params: %{
            item: %{
              type: "fileChange",
              changes: [%{path: "lib/x.ex", diff: "+ defmodule X do\n"}],
              status: "completed"
            }
          }
        }
      }

      assert {:ok, event} = Transcript.extract(message, nil)
      assert event.role == :tool
      assert event.payload.tool == "edit"
      assert event.payload.title == "edit lib/x.ex"
      assert event.payload.output == "+ defmodule X do\n"
    end

    test "reasoning item with empty content → :skip (codex's compressed-thinking placeholder)" do
      message = %{
        payload: %{
          method: "item/completed",
          params: %{item: %{type: "reasoning", content: [], summary: []}}
        }
      }

      assert Transcript.extract(message, nil) == :skip
    end

    test "item/started (any type) → :skip" do
      message = %{
        payload: %{
          method: "item/started",
          params: %{item: %{type: "commandExecution", command: "ls"}}
        }
      }

      assert Transcript.extract(message, nil) == :skip
    end

    test "codex's params.turnId takes precedence over fallback_turn_id" do
      message = %{
        payload: %{
          method: "item/completed",
          params: %{turnId: "codex-turn", item: %{type: "agentMessage", text: "hi"}}
        }
      }

      assert {:ok, event} = Transcript.extract(message, "aiur-fallback")
      assert event.turn_id == "codex-turn"
    end

    test "fallback_turn_id used when codex omits params.turnId" do
      message = %{
        payload: %{
          method: "item/completed",
          params: %{item: %{type: "agentMessage", text: "hi"}}
        }
      }

      assert {:ok, event} = Transcript.extract(message, "aiur-fallback")
      assert event.turn_id == "aiur-fallback"
    end

    test "non-codex message shape → :skip (lets caller fall back to legacy path)" do
      assert Transcript.extract(%{event: "agent_message", last_message: "hi"}, nil) == :skip
    end

    test "tolerates string-keyed JSON shape from codex" do
      message = %{
        "payload" => %{
          "method" => "item/completed",
          "params" => %{
            "turnId" => "turn-xyz",
            "item" => %{"type" => "agentMessage", "text" => "hi"}
          }
        }
      }

      assert {:ok, event} = Transcript.extract(message, nil)
      assert event.role == :assistant
      assert event.turn_id == "turn-xyz"
    end
  end
end
