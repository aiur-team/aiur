defmodule Aiur.Claude.HookEventsTest do
  use ExUnit.Case, async: false

  alias Aiur.Claude.HookEvents

  describe "normalize/1" do
    test "classifies the three lifecycle events and unknowns" do
      assert HookEvents.normalize(%{"hook_event_name" => "UserPromptSubmit"}).event ==
               :user_prompt_submit

      assert HookEvents.normalize(%{"hook_event_name" => "PostToolUse"}).event == :post_tool_use
      assert HookEvents.normalize(%{"hook_event_name" => "Stop"}).event == :stop
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
        HookEvents.dispatch("MT-HOOK-B", %{"hook_event_name" => "Stop", "last_assistant_message" => "x"})

      refute_receive {:claude_hook, _, _}, 50
    end

    test "always returns :ok, even on a malformed payload" do
      assert HookEvents.dispatch("MT-HOOK", %{}) == :ok
      assert HookEvents.dispatch("MT-HOOK", "not a map") == :ok
    end
  end
end
