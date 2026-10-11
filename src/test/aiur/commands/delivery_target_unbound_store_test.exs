defmodule Aiur.Commands.DeliveryTargetUnboundStoreTest do
  # async: false — rebinds the VM-global :commands_delivery_target and :decision_state_dir.
  use ExUnit.Case, async: false

  alias Aiur.DecisionStore

  @ticket %{identifier: "3313", title: "Port", url: nil}
  @source %{agent_id: "agent-1", session_id: "session-1", event_id: nil}
  @request %{"question" => "Deploy now?", "blocking" => true, "source_id" => "answer-unbound-target", "options" => [%{"id" => "ship", "label" => "Ship it"}]}

  setup do
    dir = Aiur.TestSupport.tmp_root!("aiur-delivery-target-unbound")
    originals = Map.new([:decision_state_dir, :commands_delivery_target], &{&1, Application.fetch_env(:aiur, &1)})
    Application.put_env(:aiur, :decision_state_dir, dir)
    Application.put_env(:aiur, :commands_delivery_target, Aiur.Commands.DeliveryTarget.Unbound)

    on_exit(fn ->
      Enum.each(originals, fn
        {key, {:ok, value}} -> Application.put_env(:aiur, key, value)
        {key, :error} -> Application.delete_env(:aiur, key)
      end)

      File.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  # MP-R1-C8-T02: a composition with no delivery target bound must fail with
  # its own cause. `orchestrator_unavailable` is transient and would retry a
  # missing binding forever while blaming a healthy Orchestrator.
  test "unbound target fails delivery with its own cause, not orchestrator_unavailable", %{dir: dir} do
    parent = self()

    dispatch_scheduler = fn recipient, message, delay_ms ->
      send(parent, {:scheduled, recipient, message, delay_ms})
      make_ref()
    end

    pid =
      start_supervised!(
        {DecisionStore, dispatch_delay_ms: 0, reconcile_delay_ms: 0, retry_delays_ms: [0], name: nil, state_dir: dir, filesystem_sync_fun: fn -> :ok end, dispatch_scheduler: dispatch_scheduler}
      )

    assert_receive {:scheduled, ^pid, {:reconcile_dispatches, []}, 0}, 2_000
    assert {:ok, %{decision: decision}} = DecisionStore.request(@request, [ticket: @ticket, source: @source], pid)
    payload = %{"idempotency_key" => "unbound-1", "expected_version" => 1, "custom_response" => "Proceed"}
    assert {:ok, _result} = DecisionStore.answer(decision.decision_id, payload, [actor: %{kind: :operator, id: "operator-1"}], pid)

    assert_receive {:scheduled, ^pid, first_dispatch, 0}, 2_000
    send(pid, first_dispatch)

    failed = wait_for_decision(pid, decision.decision_id, &(&1.delivery_status == :failed))
    assert [%{status: :failed, failure_reason_class: "delivery_target_unbound"}] = failed.dispatch_attempts
    # The store has settled the attempt; a transient class would have
    # scheduled its retry before `:failed` became observable.
    refute_received {:scheduled, ^pid, {:dispatch_action, _fence, _retry?}, _delay_ms}
  end

  defp wait_for_decision(pid, decision_id, predicate, attempts \\ 100)
  defp wait_for_decision(_pid, _decision_id, _predicate, 0), do: flunk("decision did not reach expected state")

  defp wait_for_decision(pid, decision_id, predicate, attempts) do
    {:ok, decision} = DecisionStore.get(decision_id, pid)

    if predicate.(decision) do
      decision
    else
      Process.sleep(10)
      wait_for_decision(pid, decision_id, predicate, attempts - 1)
    end
  end
end
