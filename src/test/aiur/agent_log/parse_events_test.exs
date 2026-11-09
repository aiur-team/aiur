defmodule Aiur.AgentLog.ParseEventsTest do
  use ExUnit.Case, async: true

  alias Aiur.AgentLog

  describe "parse/1 events" do
    test "parses an item/agentMessage/delta without itemId as assistant" do
      content =
        entry("notification", %{
          "method" => "item/agentMessage/delta",
          "params" => %{"delta" => "thinking..."}
        })

      assert [%{role: "assistant", title: "Agent", body: "thinking..."}] = AgentLog.parse(content)
    end

    test "parses alert events with a dedicated alert role" do
      content =
        entry("alert", %{
          "event" => "alert",
          "name" => "task.todo",
          "message" => "Task entered todo"
        })

      assert [%{role: "alert", title: "task.todo", body: "Task entered todo"}] =
               AgentLog.parse(content)
    end

    test "compacts consecutive deltas with the same itemId" do
      content =
        entry("notification", %{
          "method" => "item/agentMessage/delta",
          "params" => %{"itemId" => "msg-1", "delta" => "Hello "}
        }) <>
          entry("notification", %{
            "method" => "item/agentMessage/delta",
            "params" => %{"itemId" => "msg-1", "delta" => "world"}
          })

      assert [%{role: "assistant", body: "Hello world"}] = AgentLog.parse(content)
    end

    test "item/completed agentMessage with id replaces accumulated deltas" do
      content =
        entry("notification", %{
          "method" => "item/agentMessage/delta",
          "params" => %{"itemId" => "msg-1", "delta" => "partial"}
        }) <>
          entry("notification", %{
            "method" => "item/completed",
            "params" => %{"item" => %{"type" => "agentMessage", "id" => "msg-1", "text" => "final answer"}}
          })

      assert [%{role: "assistant", body: "final answer"}] = AgentLog.parse(content)
    end

    test "parses an item/completed agentMessage without id" do
      content =
        entry("notification", %{
          "method" => "item/completed",
          "params" => %{"item" => %{"type" => "agentMessage", "text" => "done"}}
        })

      assert [%{role: "assistant", body: "done"}] = AgentLog.parse(content)
    end

    test "parses a warning method" do
      content =
        entry("notification", %{
          "method" => "warning",
          "params" => %{"message" => "rate limit hit"}
        })

      assert [%{role: "system", title: "Warning", body: "rate limit hit"}] = AgentLog.parse(content)
    end

    test "skips codex skills context budget warnings" do
      content =
        entry("notification", %{
          "method" => "warning",
          "params" => %{
            "message" => "Skill descriptions were shortened to fit the 2% skills context budget. Codex can still see every skill, but some descriptions are shorter."
          }
        })

      assert [%{role: "system", title: "Log"}] = AgentLog.parse(content)
    end

    test "renders a warning whose message is not a binary" do
      # The `hidden_warning_message?/1` fallback handles non-binary
      # message payloads (codex occasionally emits a structured map
      # instead of a string). The entry should still surface as a
      # warning rather than crash or be silently dropped.
      content =
        entry("notification", %{
          "method" => "warning",
          "params" => %{"message" => %{"code" => "RATE_LIMIT"}}
        })

      assert [%{role: "system", title: "Warning"}] = AgentLog.parse(content)
    end

    test "skips successful commandExecution completions" do
      content =
        entry("notification", %{
          "method" => "item/completed",
          "params" => %{
            "item" => %{
              "type" => "commandExecution",
              "command" => "ls",
              "exitCode" => 0,
              "aggregatedOutput" => "file1\nfile2"
            }
          }
        })

      assert [%{role: "system", title: "Log"}] = AgentLog.parse(content)
    end

    test "skips commandExecution start events" do
      content =
        entry("notification", %{
          "method" => "item/started",
          "params" => %{"item" => %{"type" => "commandExecution"}}
        })

      assert [%{role: "system", title: "Log"}] = AgentLog.parse(content)
    end

    test "skips successful commandExecution with non-binary output" do
      content =
        entry("notification", %{
          "method" => "item/completed",
          "params" => %{
            "item" => %{
              "type" => "commandExecution",
              "command" => "true",
              "exitCode" => 0,
              "aggregatedOutput" => nil
            }
          }
        })

      assert [%{role: "system", title: "Log"}] = AgentLog.parse(content)
    end

    test "renders failed commandExecution as tool message" do
      content =
        entry("notification", %{
          "method" => "item/completed",
          "params" => %{
            "item" => %{
              "type" => "commandExecution",
              "command" => "ls /nope",
              "exitCode" => 2,
              "aggregatedOutput" => "ls: /nope: No such file"
            }
          }
        })

      assert [%{role: "tool", title: "Command failed", body: body}] = AgentLog.parse(content)
      assert body =~ "$ ls /nope"
      assert body =~ "exit 2"
      assert body =~ "No such file"
    end

    test "renders successful commandExecution as tool when output looks like auth failure" do
      content =
        entry("notification", %{
          "method" => "item/completed",
          "params" => %{
            "item" => %{
              "type" => "commandExecution",
              "command" => "gh auth status",
              "exitCode" => 0,
              "aggregatedOutput" => "token is invalid"
            }
          }
        })

      assert [%{role: "tool", title: "Command output"}] = AgentLog.parse(content)
    end

    test "skips item/started reasoning and agentMessage events" do
      content =
        entry("notification", %{
          "method" => "item/started",
          "params" => %{"item" => %{"type" => "reasoning"}}
        }) <>
          entry("notification", %{
            "method" => "item/started",
            "params" => %{"item" => %{"type" => "agentMessage"}}
          })

      assert [%{role: "system", title: "Log"}] = AgentLog.parse(content)
    end

    test "skips item/completed reasoning and userMessage events" do
      content =
        entry("notification", %{
          "method" => "item/completed",
          "params" => %{"item" => %{"type" => "reasoning"}}
        }) <>
          entry("notification", %{
            "method" => "item/completed",
            "params" => %{"item" => %{"type" => "userMessage"}}
          })

      assert [%{role: "system", title: "Log"}] = AgentLog.parse(content)
    end

    test "skips item/commandExecution/outputDelta events" do
      content =
        entry("notification", %{
          "method" => "item/commandExecution/outputDelta",
          "params" => %{"delta" => "..."}
        })

      assert [%{role: "system", title: "Log"}] = AgentLog.parse(content)
    end

    test "skips thread/status/changed, turn/started, account/rateLimits/updated, mcpServer/startupStatus/updated" do
      content =
        entry("notification", %{"method" => "thread/status/changed", "params" => %{}}) <>
          entry("notification", %{"method" => "turn/started", "params" => %{}}) <>
          entry("notification", %{"method" => "account/rateLimits/updated", "params" => %{}}) <>
          entry("notification", %{"method" => "mcpServer/startupStatus/updated", "params" => %{}})

      assert [%{role: "system", title: "Log"}] = AgentLog.parse(content)
    end

    test "unknown method falls through to nil" do
      content =
        entry("notification", %{
          "method" => "totally/unknown",
          "params" => %{"foo" => "bar"}
        })

      assert [%{role: "system", title: "Log"}] = AgentLog.parse(content)
    end

    test "JSON without method renders as humanized system event" do
      content = entry("session_started", %{"session_id" => "abc-123"})

      assert [%{role: "system", title: "Session Started", body: body}] = AgentLog.parse(content)
      assert body =~ "abc-123"
    end

    test "JSON without method prefers last_message when present" do
      content = entry("worker_paused", %{"last_message" => "Agent paused by Executor."})

      assert [%{role: "system", title: "Worker Paused", body: "Agent paused by Executor."}] =
               AgentLog.parse(content)
    end

    test "non-JSON body is skipped" do
      content = """
      ## 2026-05-10T22:00:00Z notification

      ```text
      not json at all
      ```


      """

      assert [%{role: "system", title: "Log"}] = AgentLog.parse(content)
    end

    test "keeps only the last 80 messages" do
      content =
        1..100
        |> Enum.map_join("", fn n ->
          entry("notification", %{
            "method" => "item/agentMessage/delta",
            "params" => %{"delta" => "msg-#{n}"}
          })
        end)

      messages = AgentLog.parse(content)
      assert length(messages) == 80
      assert List.last(messages).body == "msg-100"
      assert List.first(messages).body == "msg-21"
    end

    test "blank body becomes placeholder" do
      content =
        entry("notification", %{
          "method" => "item/agentMessage/delta",
          "params" => %{"delta" => ""}
        })

      assert [%{body: "No content."}] = AgentLog.parse(content)
    end

    test "truncates extremely long bodies in summary path" do
      huge = String.duplicate("x", 2_000)
      content = entry("notification", %{"junk" => huge})

      assert [%{role: "system", body: body}] = AgentLog.parse(content)
      assert String.length(body) <= 1_605
      assert String.ends_with?(body, "\n...")
    end
  end

  defp entry(event, payload) do
    """
    ## 2026-05-10T22:46:39.307486Z #{event}

    ```text
    #{Jason.encode!(payload)}
    ```


    """
  end
end
