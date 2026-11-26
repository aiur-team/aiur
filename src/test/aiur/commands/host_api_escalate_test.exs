defmodule Aiur.Commands.HostApiEscalateTest do
  use ExUnit.Case, async: false

  alias Aiur.Commands.{HostApi, Scope}
  alias Aiur.{DecisionQuery, DecisionStore}

  @source %{agent_id: "agent-1", session_id: "session-1", event_id: nil}
  @secret String.duplicate("s", 64)
  @now ~U[2026-11-05 12:00:00Z]

  setup_all do: :ok = Aiur.TestSupport.ensure_runtime_children_running()

  setup do
    original_override = Application.get_env(:aiur, :decision_state_dir)
    dir = Aiur.TestSupport.tmp_root!("aiur-host-api-escalate")
    Application.put_env(:aiur, :decision_state_dir, dir)

    {:ok, store} = DecisionStore.start_link(name: nil, state_dir: dir, filesystem_sync_fun: fn -> :ok end)

    on_exit(fn ->
      Aiur.TestSupport.safe_stop(store)

      case original_override do
        nil -> Application.delete_env(:aiur, :decision_state_dir)
        value -> Application.put_env(:aiur, :decision_state_dir, value)
      end

      Aiur.TestCleanup.rm_rf!(dir)
    end)

    %{store: store}
  end

  test "escalate defers a scoped Command to the Executor and stores the note on the deferred event", %{store: store} do
    decision = request!(store, "42", "escalate")
    scope = scope_for(["42"])
    payload = %{"idempotency_key" => "esc-1", "expected_version" => decision.version, "note" => "not sure, you decide"}

    assert {:ok, %{"command" => command}} = HostApi.escalate(scope, decision.decision_id, payload, store: store)
    assert command["state"] == "escalated"
    assert command["actions"] == %{"answer" => false, "revise" => false, "enrich" => false, "escalate" => false, "reject" => false}

    assert {:ok, %{decision: deferred}} = DecisionQuery.get(decision.decision_id, store: store)
    assert deferred.decision_status == :deferred

    assert {:ok, history} = DecisionStore.audit_history(decision.decision_id, store)
    event = Enum.find(history, &(&1.type == :decision_deferred))
    assert event.data.note == "not sure, you decide"
    assert event.data.actor.id == "player-7"
    assert event.data.actor.source == :host_api
  end

  test "escalate treats an out-of-scope Command as not found and leaves it open", %{store: store} do
    decision = request!(store, "42", "escalate-scope")
    payload = %{"idempotency_key" => "esc-2", "expected_version" => decision.version}

    assert {:error, :not_found} = HostApi.escalate(scope_for(["99"]), decision.decision_id, payload, store: store)
    assert {:ok, %{decision: %{decision_status: :open}}} = DecisionQuery.get(decision.decision_id, store: store)
  end

  test "escalate on a non-deferrable Command is a named conflict", %{store: store} do
    decision = request!(store, "42", "escalate-human", authority: "human_required")
    payload = %{"idempotency_key" => "esc-3", "expected_version" => decision.version}

    assert {:error, {:conflict, :not_deferrable}} = HostApi.escalate(scope_for(["42"]), decision.decision_id, payload, store: store)
    assert {:ok, %{"command" => %{"actions" => %{"escalate" => false}}}} = HostApi.show(scope_for(["42"]), decision.decision_id, store: store)
  end

  test "escalate rejects a stale version and a missing idempotency key", %{store: store} do
    decision = request!(store, "42", "escalate-stale")
    scope = scope_for(["42"])

    assert {:error, {:conflict, {:stale_version, 99, _current}}} =
             HostApi.escalate(scope, decision.decision_id, %{"idempotency_key" => "k", "expected_version" => 99}, store: store)

    assert {:error, {:invalid_answer, {:idempotency_key, :missing}}} =
             HostApi.escalate(scope, decision.decision_id, %{"expected_version" => decision.version}, store: store)
  end

  test "escalate rejects an over-long note as invalid, not a store outage", %{store: store} do
    decision = request!(store, "42", "escalate-long-note")
    payload = %{"idempotency_key" => "k", "expected_version" => decision.version, "note" => String.duplicate("a", 2001)}

    assert {:error, {:invalid_answer, {:note, :too_long}}} = HostApi.escalate(scope_for(["42"]), decision.decision_id, payload, store: store)
  end

  test "escalate rejects a note with control characters as invalid, not a store outage", %{store: store} do
    decision = request!(store, "42", "escalate-ctl-note")
    payload = %{"idempotency_key" => "k", "expected_version" => decision.version, "note" => "bad\u0007note"}

    assert {:error, {:invalid_answer, {:note, :unsafe_characters}}} = HostApi.escalate(scope_for(["42"]), decision.decision_id, payload, store: store)
  end

  test "a pending deferrable Command advertises the escalate action", %{store: store} do
    decision = request!(store, "42", "escalate-flag")
    assert {:ok, %{"command" => %{"actions" => %{"escalate" => true}}}} = HostApi.show(scope_for(["42"]), decision.decision_id, store: store)
  end

  defp scope_for(tickets) do
    {:ok, %{scope: scope}} = Scope.mint("player-7", tickets, secret: @secret, now: @now)
    scope
  end

  defp request!(store, ticket, source_id, opts \\ []) do
    human? = Keyword.get(opts, :authority) == "human_required"

    payload = %{
      "source_id" => source_id,
      "question" => "What should we do about #{source_id}?",
      "blocking" => true,
      "kind" => "architecture",
      "authority" => Keyword.get(opts, :authority, "supervisor_allowed"),
      "reversibility" => "reversible",
      "context" => if(human?, do: %{"authority_basis" => "security"}, else: %{}),
      "options" => [
        %{"id" => "approve", "label" => "Approve", "description" => "Ship it"},
        %{"id" => "hold", "label" => "Hold"}
      ],
      "recommendation" => %{"option_id" => "approve"},
      "artifacts" => ["https://github.com/aiur-team/aiur/issues/42"]
    }

    ticket_map = %{identifier: ticket, title: "Ticket #{ticket}", url: "https://example.test/issues/#{ticket}"}

    assert {:ok, %{decision: decision}} =
             DecisionStore.request(payload, [ticket: ticket_map, source: @source, now: @now], store)

    decision
  end
end
