defmodule Aiur.Orchestrator.StatusCLI.AgentActivityTextTest do
  use ExUnit.Case, async: true

  alias Aiur.Orchestrator.StatusCLI.AgentActivityText

  describe "describe/1" do
    test "renders one activity line per normalized in-process event" do
      assert AgentActivityText.describe(%{event: :session_started}) == "turn started"
      assert AgentActivityText.describe(%{event: :turn_completed, message: %{id: "req-2"}}) == "turn completed"
      assert AgentActivityText.describe(%{event: :reasoning, message: %{text: "thinking out loud"}}) == "thinking"

      assert AgentActivityText.describe(%{
               event: :tool_call,
               message: %{name: "exec_command", arguments: %{"command" => "mix test --max-cases 4"}}
             }) == "run mix test --max-cases 4"

      assert AgentActivityText.describe(%{event: :tool_call, message: %{name: "read_file", arguments: %{"path" => "lib/a.ex"}}}) ==
               "read lib/a.ex"

      assert AgentActivityText.describe(%{event: :assistant, message: %{text: "All checks pass\n"}}) == "All checks pass"
      assert AgentActivityText.describe(%{event: :assistant, message: %{text: "   "}}) == nil
    end

    test "leaves app-server payloads to the method humanizer" do
      assert AgentActivityText.describe(%{event: :notification, message: %{method: "turn/started"}}) == nil
      assert AgentActivityText.describe(%{event: :agent_message, body: "hello"}) == nil
      assert AgentActivityText.describe(nil) == nil
    end
  end
end
