defmodule Aiur.AgentLogTest do
  use ExUnit.Case, async: true

  alias Aiur.AgentLog

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

  describe "workspace_structured_log_path/1" do
    test "joins workspace path with logs/agent.ndjson" do
      assert AgentLog.workspace_structured_log_path("/tmp/ws") == "/tmp/ws/logs/agent.ndjson"
    end

    test "returns nil for invalid input" do
      assert AgentLog.workspace_structured_log_path(nil) == nil
      assert AgentLog.workspace_structured_log_path(123) == nil
    end
  end

  describe "read_workspace/1" do
    test "prefers structured ndjson events over markdown projection" do
      workspace = tmp_workspace()
      File.mkdir_p!(Path.join(workspace, "logs"))

      File.write!(
        Path.join(workspace, "logs/agent.md"),
        entry("notification", %{
          "method" => "item/agentMessage/delta",
          "params" => %{"delta" => "from markdown"}
        })
      )

      File.write!(
        Path.join(workspace, "logs/agent.ndjson"),
        ndjson(%{
          "event" => "notification",
          "timestamp" => "2026-05-10T22:46:39Z",
          "raw" =>
            Jason.encode!(%{
              "method" => "item/agentMessage/delta",
              "params" => %{"delta" => "from ndjson"}
            })
        })
      )

      assert %{path: path, messages: [%{role: "assistant", body: "from ndjson"}]} =
               AgentLog.read_workspace(workspace)

      assert path == Path.join(workspace, "logs/agent.ndjson")
    end

    test "falls back to markdown when structured log is missing" do
      workspace = tmp_workspace()
      File.mkdir_p!(Path.join(workspace, "logs"))

      File.write!(
        Path.join(workspace, "logs/agent.md"),
        entry("notification", %{
          "method" => "item/agentMessage/delta",
          "params" => %{"delta" => "from markdown"}
        })
      )

      assert %{path: path, messages: [%{role: "assistant", body: "from markdown"}]} =
               AgentLog.read_workspace(workspace)

      assert path == Path.join(workspace, "logs/agent.md")
    end

    test "returns no-workspace placeholder when no workspace path is available" do
      assert %{path: nil, messages: [%{role: "system", body: body}]} = AgentLog.read_workspace(nil)
      assert body == "No local workspace path is available for this session."
    end
  end

  describe "read/1" do
    test "returns placeholder when path is nil" do
      assert AgentLog.read(nil) == "No local workspace path is available for this session."
    end

    test "returns placeholder when file does not exist" do
      assert AgentLog.read("/nonexistent/path/agent.md") == "Agent log has not been written yet."
    end

    test "returns read error details for other file errors" do
      path = Aiur.TestSupport.tmp_root!("agent_log_test_dir")
      File.mkdir_p!(path)

      try do
        assert AgentLog.read(path) =~ "Unable to read agent log:"
      after
        File.rmdir!(path)
      end
    end

    test "returns placeholder for empty file" do
      path = Aiur.TestSupport.tmp_root!("agent_log_test_empty") <> ".md"
      File.write!(path, "")

      try do
        assert AgentLog.read(path) == "Agent log is empty."
      after
        File.rm!(path)
      end
    end

    test "returns file content when readable" do
      path = Aiur.TestSupport.tmp_root!("agent_log_test_content") <> ".md"
      File.write!(path, "hello world")

      try do
        assert AgentLog.read(path) == "hello world"
      after
        File.rm!(path)
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

    test "parses structured ndjson notification raw payloads" do
      content =
        ndjson(%{
          "event" => "notification",
          "timestamp" => "2026-05-10T22:46:39Z",
          "raw" =>
            Jason.encode!(%{
              "method" => "item/started",
              "params" => %{
                "item" => %{"type" => "userMessage", "content" => [%{"text" => "Hello from ndjson"}]}
              }
            })
        })

      assert [%{role: "user", title: "Executor", body: "Hello from ndjson"}] = AgentLog.parse(content)
    end

    test "parses structured ndjson alerts from top-level fields" do
      content =
        ndjson(%{
          "event" => "alert",
          "timestamp" => "2026-05-10T22:46:39Z",
          "name" => "ticket.63.agent.phase.work.start",
          "message" => "working"
        })

      assert [
               %{
                 role: "alert",
                 title: "ticket.63.agent.phase.work.start",
                 body: "working",
                 alert_name: "ticket.63.agent.phase.work.start"
               }
             ] = AgentLog.parse(content)
    end

    test "skips malformed structured ndjson lines and keeps valid messages" do
      content =
        [
          ndjson(%{
            "event" => "notification",
            "raw" =>
              Jason.encode!(%{
                "method" => "item/agentMessage/delta",
                "params" => %{"delta" => "first"}
              })
          }),
          "not json\n",
          ndjson(%{
            "event" => "notification",
            "raw" =>
              Jason.encode!(%{
                "method" => "item/agentMessage/delta",
                "params" => %{"delta" => "second"}
              })
          })
        ]
        |> IO.iodata_to_binary()

      assert [
               %{role: "assistant", body: "first"},
               %{role: "assistant", body: "second"}
             ] = AgentLog.parse(content)
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
      assert message.title == "Executor"
      assert message.body == "Hello"
    end

    test "renders non-text user message content safely" do
      content =
        entry("notification", %{
          "method" => "item/started",
          "params" => %{
            "item" => %{"type" => "userMessage", "content" => [%{"image" => "ref-1"}]}
          }
        })

      assert [%{role: "user", body: body}] = AgentLog.parse(content)
      assert body =~ ~s("image" => "ref-1")
    end

    test "renders scalar user message content safely" do
      content =
        entry("notification", %{
          "method" => "item/started",
          "params" => %{
            "item" => %{"type" => "userMessage", "content" => "plain prompt"}
          }
        })

      assert [%{role: "user", body: ~s("plain prompt")}] = AgentLog.parse(content)
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

      assert [%{role: "user", title: "Issue prompt", body: body}] = AgentLog.parse(content)
      assert body =~ "Fix login bug"
      assert body =~ "Login fails on invalid email"
      refute body =~ "Continuation context"
    end

    test "does not include workflow instructions in issue prompt summaries" do
      prompt = """
      Issue:

      Fix login bug

      Description:

      Login fails on invalid email

      ## Workspace setup

      Follow repository setup.

      ## How to operate

      Load the aiur-agent skill.
      """

      content =
        entry("notification", %{
          "method" => "item/started",
          "params" => %{
            "item" => %{"type" => "userMessage", "content" => [%{"text" => prompt}]}
          }
        })

      assert [%{role: "user", title: "Issue prompt", body: body}] = AgentLog.parse(content)
      assert body =~ "Fix login bug"
      assert body =~ "Login fails on invalid email"
      refute body =~ "Workspace setup"
      refute body =~ "How to operate"
      refute body =~ "aiur-agent"
    end

    test "keeps an issue's own ## headings but stops at the workspace-setup section" do
      # The reason the description terminator matches explicit template headers
      # (`## Workspace setup`) rather than a bare `## `: an issue body routinely
      # carries its own `## ` subheadings, and those must survive in the summary.
      prompt = """
      Issue:

      Slim the pre-prompt

      Description:

      ## Problem

      The pre-prompt is long.

      ## Proposal

      Move it into a skill.

      ## Workspace setup

      Follow repository setup.
      """

      content =
        entry("notification", %{
          "method" => "item/started",
          "params" => %{
            "item" => %{"type" => "userMessage", "content" => [%{"text" => prompt}]}
          }
        })

      assert [%{role: "user", title: "Issue prompt", body: body}] = AgentLog.parse(content)
      assert body =~ "## Problem"
      assert body =~ "## Proposal"
      assert body =~ "Move it into a skill."
      refute body =~ "Workspace setup"
      refute body =~ "Follow repository setup."
    end

    test "stops at the legacy ## Workflow header used by the github-codex example template" do
      # `src/examples/workflows/github-codex.prompt.md` still emits `## Workflow`
      # after the description; its rendered prompts flow through this parser, so
      # the terminator must keep stripping that section too.
      prompt = """
      Issue:

      Fix login bug

      Description:

      Login fails on invalid email

      ## Workflow

      1. Read the issue and current labels.
      """

      content =
        entry("notification", %{
          "method" => "item/started",
          "params" => %{
            "item" => %{"type" => "userMessage", "content" => [%{"text" => prompt}]}
          }
        })

      assert [%{role: "user", title: "Issue prompt", body: body}] = AgentLog.parse(content)
      assert body =~ "Login fails on invalid email"
      refute body =~ "Workflow"
      refute body =~ "Read the issue and current labels"
    end

    test "the shipped prompt template still emits the ## Workspace setup terminator" do
      # Guards the coupling between the `summarize_prompt/1` terminator and the
      # template header: if `.aiur/prompt.md` renames the section, this fails
      # loudly so the regex above is updated in lockstep.
      template_path = Path.join([File.cwd!(), "..", ".aiur", "prompt.md"])

      assert File.exists?(template_path),
             "expected the shipped prompt template at #{template_path}"

      assert File.read!(template_path) =~ "\n## Workspace setup\n"
    end

    test "falls back to raw summary for continuation prompts without issue sections" do
      prompt = "Continuation guidance:\n\nResume from the current workspace state."

      content =
        entry("notification", %{
          "method" => "item/started",
          "params" => %{
            "item" => %{"type" => "userMessage", "content" => [%{"text" => prompt}]}
          }
        })

      assert [%{role: "user", title: "Issue prompt", body: body}] = AgentLog.parse(content)
      assert body == prompt
    end

    test "suppresses repeated issue prompts after the first displayed one" do
      prompt = "Issue:\n\nFix login bug\n\nDescription:\n\nLogin fails on invalid email"

      content =
        entry("notification", %{
          "method" => "item/started",
          "params" => %{
            "item" => %{"type" => "userMessage", "content" => [%{"text" => prompt}]}
          }
        }) <>
          entry("notification", %{
            "method" => "item/started",
            "params" => %{
              "item" => %{"type" => "userMessage", "content" => [%{"text" => prompt}]}
            }
          })

      assert [%{role: "user", title: "Issue prompt", body: body}] = AgentLog.parse(content)
      assert body =~ "Fix login bug"
    end

    test "renders coordination-event user messages as system notices" do
      content =
        entry("notification", %{
          "method" => "item/started",
          "params" => %{
            "item" => %{
              "type" => "userMessage",
              "content" => [%{"text" => "Coordination event: blocker_became_terminal\n\nBlocker MT-1 reached done"}]
            }
          }
        })

      assert [%{role: "system", title: "Coordination event", body: body}] = AgentLog.parse(content)
      assert body =~ "blocker_became_terminal"
    end

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

  defp ndjson(payload), do: Jason.encode!(payload) <> "\n"

  defp tmp_workspace do
    path = Aiur.TestSupport.tmp_root!("aiur-agent-log")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
