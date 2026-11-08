defmodule Aiur.AgentLog.ParseTest do
  use ExUnit.Case, async: true

  alias Aiur.AgentLog

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
end
