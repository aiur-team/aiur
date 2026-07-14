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

    cleanup = fn before_restore -> cleanup_fake_orchestrator(name, fake, original, before_restore) end
    ExUnit.Callbacks.on_exit(fn -> cleanup.(fn -> :ok end) end)

    {fake, cleanup}
  end

  defp cleanup_fake_orchestrator(name, fake, original, before_restore) do
    try do
      GenServer.stop(fake)
    catch
      :exit, :noproc -> :ok
      :exit, {:noproc, _} -> :ok
    end

    before_restore.()

    if is_pid(original) do
      try do
        Process.register(original, name)
      rescue
        ArgumentError -> :ok
      end
    end
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

  test "teardown tolerates the orchestrator registration disappearing" do
    original = Process.whereis(Aiur.Orchestrator)
    {_fake, cleanup} = with_fake_orchestrator({:ok, 42})

    Process.unregister(Aiur.Orchestrator)
    cleanup.(fn -> :ok end)

    assert Process.whereis(Aiur.Orchestrator) == original
  end

  test "teardown preserves an orchestrator registered while cleanup is running" do
    {_fake, cleanup} = with_fake_orchestrator({:ok, 42})
    replacement = spawn(fn -> Process.sleep(:infinity) end)

    cleanup.(fn -> Process.register(replacement, Aiur.Orchestrator) end)

    assert Process.whereis(Aiur.Orchestrator) == replacement
    Process.unregister(Aiur.Orchestrator)
    Process.exit(replacement, :kill)
  end
end
