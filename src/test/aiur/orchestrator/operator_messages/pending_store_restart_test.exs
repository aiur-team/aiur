defmodule Aiur.Orchestrator.OperatorMessages.PendingStoreRestartTest do
  use Aiur.TestSupport, async: false

  alias Aiur.Orchestrator
  alias Aiur.Orchestrator.OperatorMessages

  test "idle operator message survives orchestrator restart and is claimed once" do
    path = Path.join(System.tmp_dir!(), "pending-operator-messages-#{System.unique_integer([:positive])}.json")
    previous = Application.get_env(:aiur, :pending_operator_messages_store_path)
    Application.put_env(:aiur, :pending_operator_messages_store_path, path)
    name = Module.concat(__MODULE__, RestartableOrchestrator)

    on_exit(fn ->
      if is_nil(previous), do: Application.delete_env(:aiur, :pending_operator_messages_store_path), else: Application.put_env(:aiur, :pending_operator_messages_store_path, previous)
      File.rm(path)
    end)

    {:ok, first_pid} = Orchestrator.start_link(name: name, initial_poll?: false)
    assert {:ok, queued_id} = Orchestrator.send_operator_message(name, "45", %{kind: :text, body: "resume this work"})
    GenServer.stop(first_pid)

    {:ok, second_pid} = Orchestrator.start_link(name: name, initial_poll?: false)

    assert {:ok, %{id: ^queued_id, target_issue_identifier: "45", body: %{text: "resume this work"}}} =
             OperatorMessages.claim_next_queue_item(name, "45")

    assert :empty = OperatorMessages.claim_next_queue_item(name, "45")
    GenServer.stop(second_pid)

    {:ok, third_pid} = Orchestrator.start_link(name: name, initial_poll?: false)
    assert :empty = OperatorMessages.claim_next_queue_item(name, "45")
    GenServer.stop(third_pid)
  end
end
