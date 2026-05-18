defmodule Aiur.AgentRunnerTranscriptTest do
  use ExUnit.Case, async: true

  alias Aiur.AgentRunner

  describe "transcript_event_from/1" do
    test "turn diff updates become diff transcript events" do
      message = %{
        event: "notification",
        payload: %{
          method: "turn/diff/updated",
          params: %{
            diff: """
            diff --git a/file.txt b/file.txt
            index 1111111..2222222 100644
            --- a/file.txt
            +++ b/file.txt
            @@ -1 +1 @@
            -old
            +new
            """
          }
        },
        timestamp: ~U[2026-05-18 00:00:00Z]
      }

      assert {:ok, event} = AgentRunner.transcript_event_from(message)
      assert event.role == :diff
      assert event.body =~ "diff --git a/file.txt b/file.txt"
      assert event.timestamp == ~U[2026-05-18 00:00:00Z]
    end

    test "turn diff updates with string keys become diff transcript events" do
      message = %{
        "event" => "notification",
        "payload" => %{
          "method" => "turn/diff/updated",
          "params" => %{
            "diff" => """
            diff --git a/file.txt b/file.txt
            index 1111111..2222222 100644
            --- a/file.txt
            +++ b/file.txt
            @@ -1 +1 @@
            -old
            +new
            """
          }
        }
      }

      assert {:ok, event} = AgentRunner.transcript_event_from(message)
      assert event.role == :diff
      assert event.body =~ "diff --git a/file.txt b/file.txt"
    end

    test "empty turn diff updates are skipped" do
      message = %{
        event: "notification",
        payload: %{
          method: "turn/diff/updated",
          params: %{diff: "   \n"}
        }
      }

      assert AgentRunner.transcript_event_from(message) == :skip
    end

    test "assistant messages still become assistant transcript events" do
      message = %{
        event: "notification",
        payload: %{
          method: "item/completed",
          params: %{item: %{type: "agentMessage", text: "done"}}
        }
      }

      assert {:ok, event} = AgentRunner.transcript_event_from(message)
      assert event.role == :assistant
      assert event.body == "done"
    end
  end
end
