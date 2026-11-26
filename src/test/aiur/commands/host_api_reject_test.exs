defmodule Aiur.Commands.HostApiRejectTest do
  use ExUnit.Case, async: false

  alias Aiur.Commands.{HostApi, Scope}
  alias Aiur.{DecisionDispatch, DecisionQuery, DecisionStore}

  @source %{agent_id: "agent-1", session_id: "session-1", event_id: nil}
  @secret String.duplicate("s", 64)
  @now ~U[2026-11-05 12:00:00Z]
  @reason "This question is wrong: the build already shipped.\nDon't ask again — see #42."

  setup_all do: :ok = Aiur.TestSupport.ensure_runtime_children_running()

  setup do
    original = Application.get_env(:aiur, :decision_state_dir)
    dir = Aiur.TestSupport.tmp_root!("aiur-host-api-reject")
    Application.put_env(:aiur, :decision_state_dir, dir)
    {:ok, store} = DecisionStore.start_link(name: nil, state_dir: dir, filesystem_sync_fun: fn -> :ok end)

    on_exit(fn ->
      Aiur.TestSupport.safe_stop(store)

      case original do
        nil -> Application.delete_env(:aiur, :decision_state_dir)
        value -> Application.put_env(:aiur, :decision_state_dir, value)
      end

      Aiur.TestCleanup.rm_rf!(dir)
    end)

    %{store: store, dir: dir}
  end

  test "rejecting a blocking Command records the verbatim reason and survives a store restart", %{store: store, dir: dir} do
    command = request!(store, "42", "blocking")
    assert command.blocking

    assert {:ok, %{"command" => component}} =
             HostApi.reject(scope_for(["42"]), command.decision_id, payload(command.version), store: store)

    assert component["state"] == "rejected"
    assert component["reason"] == @reason
    assert component["answer"]["rejected"] == true
    assert component["answer"]["custom_response"] == @reason
    assert component["actions"]["reject"] == false
    assert component["actions"]["answer"] == false

    Aiur.TestSupport.safe_stop(store)
    {:ok, restarted} = DecisionStore.start_link(name: nil, state_dir: dir, filesystem_sync_fun: fn -> :ok end)
    on_exit(fn -> Aiur.TestSupport.safe_stop(restarted) end)

    assert {:ok, %{"command" => reread}} = HostApi.show(scope_for(["42"]), command.decision_id, store: restarted)
    assert reread["state"] == "rejected"
    assert reread["reason"] == @reason
    assert reread["answer"]["rejected"] == true
  end

  test "a pending Command advertises the reject action", %{store: store} do
    command = request!(store, "42", "pending")

    assert {:ok, %{"command" => component}} = HostApi.show(scope_for(["42"]), command.decision_id, store: store)
    assert component["state"] == "pending"
    assert component["actions"]["reject"] == true
  end

  test "the waiting agent's delivery names the rejection and the reason", %{store: store} do
    command = request!(store, "42", "delivery")
    assert {:ok, _} = HostApi.reject(scope_for(["42"]), command.decision_id, payload(command.version), store: store)
    assert {:ok, %{decision: decided}} = DecisionQuery.get(command.decision_id, store: store)

    assert {:ok, _} =
             DecisionDispatch.dispatch(decided,
               attempt_id: "att_1",
               send_fun: fn _server, "42", delivered ->
                 send(self(), {:delivered, delivered.body})
                 {:ok, %{}}
               end
             )

    assert_received {:delivered, body}
    assert body =~ "Command rejected by the operator. Reason: " <> @reason
    refute body =~ "Custom response"
  end

  test "an out-of-scope Command is not found and stays unrejected", %{store: store} do
    hidden = request!(store, "99", "hidden")

    assert {:error, :not_found} = HostApi.reject(scope_for(["42"]), hidden.decision_id, payload(hidden.version), store: store)
    assert {:ok, %{decision: unchanged}} = DecisionQuery.get(hidden.decision_id, store: store)
    assert unchanged.decision_status == :open
    assert unchanged.answer == nil
  end

  test "a missing reason, a stale version and an over-long reason are refused", %{store: store} do
    command = request!(store, "42", "invalid")
    scope = scope_for(["42"])

    assert {:error, {:invalid_answer, {:reason, :missing}}} =
             HostApi.reject(scope, command.decision_id, Map.delete(payload(command.version), "reason"), store: store)

    assert {:error, {:invalid_answer, {:reason, :missing}}} =
             HostApi.reject(scope, command.decision_id, %{payload(command.version) | "reason" => "   "}, store: store)

    stale = %{payload(command.version) | "expected_version" => command.version + 5}
    assert {:ok, %{"command" => %{"state" => state}}} = HostApi.reject(scope, command.decision_id, stale, store: store)
    assert state != "rejected"

    long = %{payload(command.version) | "reason" => String.duplicate("x", 4_001)}

    assert {:error, {:invalid_answer, {:custom_response, :too_long}}} =
             HostApi.reject(scope, command.decision_id, long, store: store)
  end

  test "a retry with the same idempotency key does not record a second rejection", %{store: store} do
    command = request!(store, "42", "retry")
    scope = scope_for(["42"])
    body = payload(command.version)

    assert {:ok, %{"command" => %{"state" => "rejected"}}} = HostApi.reject(scope, command.decision_id, body, store: store)
    assert {:ok, %{"command" => %{"state" => "rejected", "answer" => %{"custom_response" => @reason}}}} = HostApi.reject(scope, command.decision_id, body, store: store)
  end

  test "the plain answer operation cannot smuggle the rejected flag", %{store: store} do
    command = request!(store, "42", "smuggle")

    assert {:ok, %{"command" => component}} =
             HostApi.answer(
               scope_for(["42"]),
               command.decision_id,
               %{
                 "idempotency_key" => "k-smuggle",
                 "expected_version" => command.version,
                 "custom_response" => "fine",
                 "rejected" => true
               },
               store: store
             )

    assert component["state"] == "answered"
  end

  defp payload(version) do
    %{"idempotency_key" => "reject-1", "expected_version" => version, "reason" => @reason}
  end

  defp scope_for(tickets) do
    {:ok, %{scope: scope}} = Scope.mint("player-7", tickets, secret: @secret, now: @now)
    scope
  end

  defp request!(store, ticket, source_id) do
    payload = %{
      "source_id" => source_id,
      "question" => "What should we do about #{source_id}?",
      "blocking" => true,
      "kind" => "architecture",
      "authority" => "supervisor_allowed",
      "reversibility" => "reversible",
      "options" => [%{"id" => "approve", "label" => "Approve"}, %{"id" => "hold", "label" => "Hold"}],
      "recommendation" => %{"option_id" => "approve"},
      "artifacts" => []
    }

    ticket_map = %{identifier: ticket, title: "Ticket #{ticket}", url: "https://example.test/issues/#{ticket}"}

    assert {:ok, %{decision: decision}} =
             DecisionStore.request(payload, [ticket: ticket_map, source: @source, now: @now], store)

    decision
  end
end
