defmodule Aiur.AgentRunner.AsyncMessagePromptTargetTest do
  use ExUnit.Case, async: false

  alias Aiur.AgentRunner.TurnPrompt
  alias Aiur.Issue

  defmodule Server do
    use GenServer
    def start_link(owner), do: GenServer.start_link(__MODULE__, owner)
    @impl true
    def init(owner), do: {:ok, owner}
    @impl true
    def handle_call({:listener_get_mode, id}, _from, owner) do
      send(owner, {:mode_read, id})
      {:reply, {:ok, %{effective: :async}}, owner}
    end

    def handle_call({:control_capabilities, id}, _from, owner) do
      send(owner, {:count_read, id})
      {:reply, {:ok, %{listener: %{unread_count: 2}}}, owner}
    end
  end

  test "every turn reads mode and unread count from the worker's Orchestrator" do
    server = start_supervised!({Server, self()})
    issue = %Issue{id: "prompt-target", identifier: "prompt-target", title: "Worker prompt", state: "in-progress"}

    for turn <- [1, 2] do
      prompt = TurnPrompt.build_turn_prompt(issue, [orchestrator: server, spec_status: :ok], turn, nil)
      assert prompt =~ "2 unread"
      assert prompt =~ "Call `aiur_read_messages` at natural pauses and before finishing."
      assert_received {:mode_read, "prompt-target"}
      assert_received {:count_read, "prompt-target"}
    end
  end
end
