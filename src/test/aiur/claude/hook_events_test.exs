defmodule Aiur.Claude.HookEventsTest do
  use ExUnit.Case, async: false

  alias Aiur.Claude.HookEvents
  alias Aiur.GitHub.AgentCommentOrigins

  setup do
    path = Path.join(System.tmp_dir!(), "aiur-hook-event-origins-#{System.unique_integer([:positive])}.json")
    previous_path = Application.get_env(:aiur, :agent_comment_origins_path)
    Application.put_env(:aiur, :agent_comment_origins_path, path)

    on_exit(fn ->
      File.rm(path)
      File.rm_rf(path <> ".tickets")

      if previous_path do
        Application.put_env(:aiur, :agent_comment_origins_path, previous_path)
      else
        Application.delete_env(:aiur, :agent_comment_origins_path)
      end
    end)

    :ok
  end

  describe "normalize/1" do
    test "classifies the lifecycle events and unknowns" do
      assert HookEvents.normalize(%{"hook_event_name" => "UserPromptSubmit"}).event ==
               :user_prompt_submit

      assert HookEvents.normalize(%{"hook_event_name" => "PostToolUse"}).event == :post_tool_use
      assert HookEvents.normalize(%{"hook_event_name" => "PreToolUse"}).event == :pre_tool_use
      assert HookEvents.normalize(%{"hook_event_name" => "Stop"}).event == :stop
      assert HookEvents.normalize(%{"hook_event_name" => "StopFailure"}).event == :stop_failure
      assert HookEvents.normalize(%{"hook_event_name" => "Whatever"}).event == :unknown
      assert HookEvents.normalize(%{}).event == :unknown
    end

    test "extracts fields and tolerates missing / non-binary values" do
      event =
        HookEvents.normalize(%{
          "hook_event_name" => "Stop",
          "last_assistant_message" => "PONG",
          "session_id" => "s1",
          "cwd" => "/w"
        })

      assert event.message == "PONG"
      assert event.session_id == "s1"
      assert event.cwd == "/w"
      assert event.prompt == nil

      # non-binary values normalize to nil rather than crashing
      assert HookEvents.normalize(%{"hook_event_name" => "Stop", "last_assistant_message" => 123}).message ==
               nil
    end

    test "carries transcript_path so the display tailer can follow the active session jsonl" do
      event =
        HookEvents.normalize(%{
          "hook_event_name" => "PostToolUse",
          "transcript_path" => "/home/u/.claude/projects/-w/abc.jsonl"
        })

      assert event.transcript_path == "/home/u/.claude/projects/-w/abc.jsonl"

      # absent / non-binary transcript_path normalizes to nil
      assert HookEvents.normalize(%{"hook_event_name" => "Stop"}).transcript_path == nil
      assert HookEvents.normalize(%{"transcript_path" => 123}).transcript_path == nil
    end
  end

  describe "persist_pre_tool_use/2" do
    test "persists a GitHub comment operation before Claude can run it" do
      identifier = "MT-HOOK-PRE-#{System.unique_integer([:positive])}"
      operation_id = "toolu-#{System.unique_integer([:positive])}"

      assert :ok =
               HookEvents.persist_pre_tool_use(identifier, %{
                 "hook_event_name" => "PreToolUse",
                 "tool_name" => "Bash",
                 "tool_use_id" => operation_id,
                 "tool_input" => %{"command" => "gh pr comment 1153 --body 'Resolved.'"}
               })

      assert {:error, {:pending_origin_recovery, [^operation_id]}} =
               AgentCommentOrigins.origin(identifier, %{"id" => 70_123})
    end

    test "rejects a public comment without a stable tool operation ID" do
      assert {:error, :pre_tool_operation_id_missing} =
               HookEvents.persist_pre_tool_use("MT-HOOK-PRE-MISSING", %{
                 "hook_event_name" => "PreToolUse",
                 "tool_name" => "Bash",
                 "tool_input" => %{"command" => "gh pr comment 1153 --body 'Resolved.'"}
               })
    end
  end

  describe "dispatch/2" do
    test "broadcasts the normalized event to subscribers of the agent topic" do
      :ok = HookEvents.subscribe("MT-HOOK")

      :ok =
        HookEvents.dispatch("MT-HOOK", %{
          "hook_event_name" => "Stop",
          "last_assistant_message" => "PONG",
          "session_id" => "s9"
        })

      assert_receive {:claude_hook, "MT-HOOK", %{event: :stop, message: "PONG", session_id: "s9"}}
    end

    test "is scoped per identifier" do
      :ok = HookEvents.subscribe("MT-HOOK-A")

      :ok =
        HookEvents.dispatch("MT-HOOK-B", %{
          "hook_event_name" => "Stop",
          "last_assistant_message" => "x"
        })

      refute_receive {:claude_hook, _, _}, 50
    end

    test "always returns :ok, even on a malformed payload" do
      assert HookEvents.dispatch("MT-HOOK", %{}) == :ok
      assert HookEvents.dispatch("MT-HOOK", "not a map") == :ok
    end
  end
end
