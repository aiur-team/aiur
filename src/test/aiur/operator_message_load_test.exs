defmodule Aiur.OperatorMessageLoadTest do
  use ExUnit.Case, async: false

  alias Aiur.{Issue, Orchestrator}
  alias Aiur.Orchestrator.OperatorMessages
  alias Aiur.TestSupport.Isolation

  test "a message blocked longer than the old RPC budget returns a request id and delivery status" do
    original_timeout = Application.get_env(:aiur, :operator_message_call_timeout_ms)
    Application.delete_env(:aiur, :operator_message_call_timeout_ms)

    {:ok, orchestrator} = Orchestrator.start_link(name: nil)
    issue_id = "issue-message-load"
    identifier = "5995-load-test"
    worker = Isolation.start_owned!({Task, fn -> worker_loop() end})

    on_exit(fn ->
      restore_timeout(original_timeout)

      if Process.alive?(orchestrator) do
        try do
          :sys.resume(orchestrator)
        catch
          :exit, _reason -> :ok
        end

        Aiur.TestSupport.safe_stop(orchestrator)
      end
    end)

    :sys.replace_state(orchestrator, fn state ->
      entry = %{
        pid: worker,
        ref: make_ref(),
        identifier: identifier,
        issue: %Issue{id: issue_id, identifier: identifier, state: "In Progress", title: "Message load"},
        control: %{can_interrupt: true, safe_checkpoints: [:notification], status: :working},
        session_id: "thread-message-load",
        agent_input_tokens: 0,
        agent_output_tokens: 0,
        agent_total_tokens: 0,
        started_at: DateTime.utc_now()
      }

      %{state | running: %{issue_id => entry}}
    end)

    :ok = :sys.suspend(orchestrator)

    send_task =
      Task.async(fn ->
        OperatorMessages.send_operator_message(
          orchestrator,
          identifier,
          %{kind: :text, body: "binding decision", message_id: "slow-message", delivery_policy: :interrupt, fallback: :queue_next}
        )
      end)

    # Keep the actual GenServer call blocked beyond both former five-second
    # waits (enqueue and keyed reconciliation), then prove the accepted queue
    # handle resolves to the item.
    assert nil == Task.yield(send_task, 10_200)
    :ok = :sys.resume(orchestrator)

    assert {:ok, request_id} = Task.await(send_task, 15_000)
    assert {:ok, :pending} = OperatorMessages.operator_message_status(orchestrator, request_id)

    assert {:ok, %{id: ^request_id, body: %{text: "binding decision"}}} =
             OperatorMessages.claim_next_queue_item(orchestrator, identifier)
  end

  defp worker_loop do
    receive do
      _message -> worker_loop()
    end
  end

  defp restore_timeout(original_timeout) do
    case original_timeout do
      nil -> Application.delete_env(:aiur, :operator_message_call_timeout_ms)
      timeout -> Application.put_env(:aiur, :operator_message_call_timeout_ms, timeout)
    end
  end
end
