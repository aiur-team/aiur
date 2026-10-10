defmodule Aiur.Commands.DeliveryTargetTest do
  # async: false — these tests rebind the VM-global :commands_delivery_target.
  use ExUnit.Case, async: false

  alias Aiur.Commands.DeliveryTarget
  alias Aiur.{DecisionAnswer, DecisionDispatch, DecisionExpiry, DecisionValidation}

  defmodule Recorder do
    @behaviour DeliveryTarget

    @impl true
    def send_correlated(ticket_identifier, payload) do
      send(self(), {:target_sent, ticket_identifier, payload})
      {:ok, %{status: :accepted, item: %{id: 7}}}
    end

    @impl true
    def revalidate_issue(issue, _issue_fetcher, _terminal_states), do: {:ok, issue}
    @impl true
    def terminal_state_set, do: MapSet.new()
    @impl true
    def terminal_issue_state?(_state_name, _terminal_states), do: false
    @impl true
    def active_identifiers, do: {:error, :boom}
  end

  defp bind(module) do
    original = Application.fetch_env(:aiur, :commands_delivery_target)
    Application.put_env(:aiur, :commands_delivery_target, module)

    on_exit(fn ->
      case original do
        {:ok, value} -> Application.put_env(:aiur, :commands_delivery_target, value)
        :error -> Application.delete_env(:aiur, :commands_delivery_target)
      end
    end)
  end

  defp open_decision do
    {:ok, decision} =
      DecisionValidation.normalize(
        %{
          "question" => "Should we deploy?",
          "blocking" => true,
          "source_id" => "delivery-target-test",
          "options" => [%{"id" => "ship", "label" => "Ship it"}]
        },
        ticket: %{identifier: "3313", title: "Port", url: nil},
        source: %{agent_id: "agent-1", session_id: "session-1"},
        now: ~U[2026-07-12 10:00:00Z]
      )

    decision
  end

  test "production config binds the orchestration delivery target" do
    assert DeliveryTarget.impl() == Aiur.Orchestrator.CommandDeliveryTarget
  end

  test "DecisionDispatch default send goes through the bound target" do
    bind(Recorder)
    decision = open_decision()

    {:ok, answer} =
      DecisionAnswer.normalize(
        %{"idempotency_key" => "submit-1", "expected_version" => 1, "option_id" => "ship"},
        decision_id: decision.decision_id,
        decision_version: decision.version,
        options: decision.options,
        actor: %{kind: :operator, id: "operator-1"},
        now: ~U[2026-07-12 10:01:00Z]
      )

    decision = %{decision | answer: answer, decision_status: :decided}

    assert {:ok, %{status: :accepted, item: %{id: 7}}} = DecisionDispatch.dispatch(decision, attempt_id: "a1")

    assert_received {:target_sent, "3313", payload}
    assert payload.delivery_policy == :interrupt
    assert payload.correlation.decision_id == decision.decision_id
    assert payload.correlation.attempt_id == "a1"
    refute_received {:target_sent, _identifier, _payload}
  end

  test "DecisionExpiry skips the sweep when the target reports an error" do
    bind(Recorder)
    test_pid = self()
    now = ~U[2026-07-24 12:10:00Z]
    orphan = %{open_decision() | blocking: false, created_at: DateTime.add(now, -600, :second)}

    assert {:error, :boom} =
             DecisionExpiry.sweep(
               now: now,
               grace_seconds: 300,
               decisions_fun: fn -> {:ok, [orphan]} end,
               expire_fun: fn decision_id, _reason_class, _occurred_at ->
                 send(test_pid, {:expired, decision_id})
                 {:ok, %{status: :accepted}}
               end,
               attention_reconcile_fun: fn _decisions, _stale, _expired, _occurred_at -> :ok end
             )

    refute_received {:expired, _decision_id}
  end

  test "unbound target names its own cause on every failing callback" do
    unbound = DeliveryTarget.Unbound

    assert unbound.send_correlated("3313", %{}) == {:error, :delivery_target_unbound}
    assert unbound.active_identifiers() == {:error, :delivery_target_unbound}
    assert unbound.revalidate_issue(%Aiur.Issue{id: "1"}, fn _ids -> {:ok, []} end, MapSet.new()) == {:error, :delivery_target_unbound}
    # An unbound target must never read as "everything terminal".
    assert unbound.terminal_state_set() == MapSet.new()
    refute unbound.terminal_issue_state?("done", MapSet.new(["done"]))
  end
end
