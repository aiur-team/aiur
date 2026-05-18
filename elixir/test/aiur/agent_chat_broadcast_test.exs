defmodule Aiur.AgentChatBroadcastTest do
  use ExUnit.Case, async: false

  alias Aiur.{AgentChat, AgentPubSub}

  defmodule FakeOrchestrator do
    @moduledoc false
    use GenServer

    def start_link(reply), do: GenServer.start_link(__MODULE__, reply)

    @impl true
    def init(reply), do: {:ok, reply}

    @impl true
    def handle_call(_msg, _from, reply), do: {:reply, reply, reply}
  end

  # Re-register the global `Aiur.Orchestrator` name to point
  # at a fake GenServer that returns `reply` for any `send_operator_message`
  # call. Restores the original registration on test exit.
  defp with_fake_orchestrator(reply) do
    name = Aiur.Orchestrator
    original = Process.whereis(name)
    if is_pid(original), do: Process.unregister(name)

    {:ok, fake} = FakeOrchestrator.start_link(reply)
    Process.register(fake, name)

    ExUnit.Callbacks.on_exit(fn ->
      if Process.alive?(fake), do: Process.unregister(name)

      if is_pid(original) and Process.alive?(original) and is_nil(Process.whereis(name)) do
        Process.register(original, name)
      end
    end)

    fake
  end

  test "send/2 broadcasts a user-role transcript event when the orchestrator accepts the message" do
    _fake = with_fake_orchestrator({:ok, 42})
    :ok = AgentPubSub.subscribe_agent("MT-CHATBC")

    assert {:ok, 42} = AgentChat.send("MT-CHATBC", "hello there")
    assert_receive {:transcript_event, %{role: :user, body: "hello there"}}, 500
  end

  test "send/2 logs a warning and returns the error tuple when the orchestrator rejects" do
    _fake = with_fake_orchestrator({:error, :no_running_agent})
    :ok = AgentPubSub.subscribe_agent("MT-CHATBC-ERR")

    assert {:error, :no_running_agent} = AgentChat.send("MT-CHATBC-ERR", "hi")
    refute_receive {:transcript_event, _}, 100
  end
end
