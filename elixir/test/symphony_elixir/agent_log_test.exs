defmodule SymphonyElixir.AgentLogTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.AgentLog

  describe "workspace_log_path/1" do
    test "joins workspace path with logs/agent.md" do
      assert AgentLog.workspace_log_path("/tmp/ws") == "/tmp/ws/logs/agent.md"
    end

    test "returns nil for nil input" do
      assert AgentLog.workspace_log_path(nil) == nil
    end

    test "returns nil for non-binary input" do
      assert AgentLog.workspace_log_path(123) == nil
    end
  end

  describe "read/1" do
    test "returns placeholder when path is nil" do
      assert AgentLog.read(nil) == "No local workspace path is available for this session."
    end

    test "returns placeholder when file does not exist" do
      assert AgentLog.read("/nonexistent/path/agent.md") == "Agent log has not been written yet."
    end

    test "returns placeholder for empty file" do
      path = Path.join(System.tmp_dir!(), "agent_log_test_empty_#{System.unique_integer([:positive])}.md")
      File.write!(path, "")

      try do
        assert AgentLog.read(path) == "Agent log is empty."
      after
        File.rm!(path)
      end
    end

    test "returns file content when readable" do
      path = Path.join(System.tmp_dir!(), "agent_log_test_content_#{System.unique_integer([:positive])}.md")
      File.write!(path, "hello world")

      try do
        assert AgentLog.read(path) == "hello world"
      after
        File.rm!(path)
      end
    end

    test "returns error details when file cannot be read" do
      path = Path.join(System.tmp_dir!(), "agent_log_test_dir_#{System.unique_integer([:positive])}")
      File.mkdir_p!(path)

      try do
        assert AgentLog.read(path) =~ "Unable to read agent log:"
      after
        File.rmdir!(path)
      end
    end
  end

  describe "parse/1" do
    test "returns placeholder message when content has no entries" do
      assert [%{role: "system", title: "Log", body: body}] = AgentLog.parse("")
      assert body =~ "No displayable chat events yet"
    end

    test "returns placeholder when content has only non-matching text" do
      assert [%{role: "system", title: "Log"}] = AgentLog.parse("just some prose without entries")
    end

    test "parses an item/started userMessage as user role" do
      content =
        entry("notification", %{
          "method" => "item/started",
          "params" => %{
            "item" => %{"type" => "userMessage", "content" => [%{"text" => "Hello"}]}
          }
        })

      assert [message] = AgentLog.parse(content)
      assert message.role == "user"
      assert message.title == "Issue prompt"
      assert message.body == "Hello"
    end

    test "extracts Issue/Description sections from user prompt" do
      prompt =
        "Issue:\n\nFix login bug\n\nDescription:\n\nLogin fails on invalid email\n\nContinuation context:\n\nblah"

      content =
        entry("notification", %{
          "method" => "item/started",
          "params" => %{
            "item" => %{"type" => "userMessage", "content" => [%{"text" => prompt}]}
          }
        })

      assert [%{role: "user", body: body}] = AgentLog.parse(content)
      assert body =~ "Fix login bug"
      assert body =~ "Login fails on invalid email"
      refute body =~ "Continuation context"
    end

    test "parses an item/agentMessage/delta without itemId as assistant" do
      content =
        entry("notification", %{
          "method" => "item/agentMessage/delta",
          "params" => %{"delta" => "thinking..."}
        })

      assert [%{role: "assistant", title: "Agent", body: "thinking..."}] = AgentLog.parse(content)
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

    test "skips item/started commandExecution events" do
      content =
        entry("notification", %{
          "method" => "item/started",
          "params" => %{"item" => %{"type" => "commandExecution"}}
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

    test "skips completed reasoning and userMessage events" do
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

    test "renders non-text prompt content with inspect" do
      content =
        entry("notification", %{
          "method" => "item/started",
          "params" => %{
            "item" => %{"type" => "userMessage", "content" => [%{"image" => "diagram.png"}]}
          }
        })

      assert [%{role: "user", body: body}] = AgentLog.parse(content)
      assert body =~ ~s("image" => "diagram.png")
    end

    test "renders non-list prompt content with inspect" do
      content =
        entry("notification", %{
          "method" => "item/started",
          "params" => %{
            "item" => %{"type" => "userMessage", "content" => %{"text" => "Hello"}}
          }
        })

      assert [%{role: "user", body: body}] = AgentLog.parse(content)
      assert body =~ ~s("text" => "Hello")
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
