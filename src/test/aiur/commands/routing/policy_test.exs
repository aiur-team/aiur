defmodule Aiur.Commands.Routing.PolicyTest do
  use ExUnit.Case, async: true

  alias Aiur.Commands.Routing.Policy

  @config %{ack_ms: 300_000, answer_ms: 900_000, urgent_factor: 0.5}

  test "route table preserves requester, liveness and authority precedence across urgency and blocking" do
    for urgency <- [:low, :normal, :high, :critical], blocking <- [false, true] do
      for authority <- [:human_required, :supervisor_allowed, :supervisor_preferred, :corrupt],
          reversibility <- [:reversible, :irreversible, :partially_reversible, nil],
          liveness <- [:live, :stalled, :offline] do
        decision = %{authority: authority, reversibility: reversibility, urgency: urgency, blocking: blocking}
        executor = Map.put(decision, :requester, %{kind: :executor})
        assert Policy.route(executor, liveness) == human_only(:executor_originated)

        expected =
          case {liveness, authority, reversibility} do
            {:offline, _, _} -> human_only(:executor_offline)
            {:stalled, _, _} -> human_only(:executor_stalled)
            {:live, :human_required, _} -> %{policy: :simultaneous, state: :with_both, cause: :authority_human_required}
            {:live, authority, :reversible} when authority in [:supervisor_allowed, :supervisor_preferred] -> %{policy: :executor_first, state: :with_executor, cause: nil}
            _ -> human_only(:executor_not_answerable)
          end

        assert Policy.route(decision, liveness) == expected
        assert Policy.route(Map.put(decision, :requester, %{kind: :worker}), liveness) == expected
      end
    end
  end

  test "liveness requires positive live evidence, with any live entry winning" do
    for {states, expected} <- [
          {[:active], :live},
          {[:idle, :stalled], :live},
          {[:unknown, :expired, :active], :live},
          {[:stalled], :stalled},
          {[:unknown], :stalled},
          {[:expired, :unknown], :stalled},
          {[:expired], :offline},
          {[], :offline}
        ] do
      assert Policy.liveness(%{executors: Enum.map(states, &%{state: &1})}) == expected
    end
  end

  test "ack timeout fires exactly at its deadline and wins when both timers are overdue" do
    decision = command()
    deadline = DateTime.add(decision.routed_at, @config.ack_ms, :millisecond)

    for elapsed <- [300_000, 360_000, 960_000] do
      assert Policy.escalation_due(decision, DateTime.add(decision.routed_at, elapsed, :millisecond), @config) ==
               {:due, :executor_ack_timeout, deadline}
    end
  end

  test "ack stops only the ack timer without restarting the answer timer" do
    decision = command() |> Map.put(:executor_acknowledged_at, DateTime.utc_now())
    answer_at = DateTime.add(decision.routed_at, @config.answer_ms, :millisecond)
    assert Policy.escalation_due(decision, DateTime.add(decision.routed_at, 360_000, :millisecond), @config) == {:next, answer_at}
    assert Policy.escalation_due(decision, DateTime.add(decision.routed_at, 960_000, :millisecond), @config) == {:due, :executor_answer_timeout, answer_at}
  end

  test "urgent factor shortens both deadlines only for blocking high or critical Commands" do
    for urgency <- [:low, :normal, :high, :critical], blocking <- [true, false] do
      decision = Map.merge(command(), %{urgency: urgency, blocking: blocking})
      now = DateTime.add(decision.routed_at, 180_000, :millisecond)
      urgent? = blocking and urgency in [:high, :critical]
      ack_ms = if urgent?, do: 150_000, else: 300_000
      ack_at = DateTime.add(decision.routed_at, ack_ms, :millisecond)
      expected = if urgent?, do: {:due, :executor_ack_timeout, ack_at}, else: {:next, ack_at}
      assert Policy.escalation_due(decision, now, @config) == expected

      acked = Map.put(decision, :executor_acknowledged_at, now)
      answer_ms = if urgent?, do: 450_000, else: 900_000
      assert Policy.escalation_due(acked, now, @config) == {:next, DateTime.add(decision.routed_at, answer_ms, :millisecond)}
    end
  end

  test "next deadline uses configured milliseconds and caller clock, including skew" do
    decision = command()
    config = %{ack_ms: 5_001, answer_ms: 15_001, urgent_factor: 0.25}
    ack_at = DateTime.add(decision.routed_at, 5_001, :millisecond)

    for elapsed <- [-60_000, 0, 5_000] do
      assert Policy.escalation_due(decision, DateTime.add(decision.routed_at, elapsed, :millisecond), config) == {:next, ack_at}
    end

    assert Policy.escalation_due(decision, decision.routed_at, %{config | answer_ms: 1_000}) ==
             {:next, DateTime.add(decision.routed_at, 1_000, :millisecond)}
  end

  test "inactive, answered and legacy unrouted Commands never escalate" do
    decision = command()
    now = DateTime.add(decision.routed_at, 1_000_000, :millisecond)

    variants =
      Enum.map([:with_human, :with_both, nil], &Map.put(decision, :route_state, &1)) ++
        Enum.map([:answered, :expired, :cancelled], &Map.put(decision, :decision_status, &1)) ++
        [Map.put(decision, :answer, %{option_id: "yes"}), Map.put(decision, :routed_at, nil), Map.delete(decision, :routed_at)]

    for variant <- variants do
      assert Policy.escalation_due(variant, now, @config) == :none
    end

    assert Policy.escalation_due(%{}, now, @config) == :none
  end

  test "N1: every eligible Executor-only Command is armed with a finite deadline or is due" do
    for status <- [:open, :deferred],
        acked? <- [true, false],
        urgency <- [:normal, :high, :critical],
        blocking <- [true, false],
        ack_ms <- [0, 1, 300_000],
        answer_ms <- [0, 1, 900_000],
        factor <- [0.25, 0.5, 1.0],
        elapsed <- [-1, 0, 1, 1_000_000] do
      decision = Map.merge(command(), %{decision_status: status, urgency: urgency, blocking: blocking})
      decision = if acked?, do: Map.put(decision, :executor_acknowledged_at, decision.routed_at), else: decision
      config = %{ack_ms: ack_ms, answer_ms: answer_ms, urgent_factor: factor}
      now = DateTime.add(decision.routed_at, elapsed, :millisecond)
      assert Policy.armed?(decision, config)

      case Policy.escalation_due(decision, now, config) do
        {:due, cause, %DateTime{} = at} ->
          assert cause in [:executor_ack_timeout, :executor_answer_timeout]
          assert DateTime.compare(at, now) != :gt

        {:next, %DateTime{} = at} ->
          assert DateTime.compare(at, now) == :gt
      end
    end
  end

  test "armed invariant detects missing routing time and is vacuous for human routes" do
    refute Policy.armed?(Map.delete(command(), :routed_at), @config)
    refute Policy.armed?(Map.put(command(), :routed_at, nil), @config)
    assert Policy.armed?(%{route_state: :with_human}, @config)
    assert Policy.armed?(%{route_state: :with_both}, @config)
  end

  defp command do
    %{
      route_state: :with_executor,
      routed_at: DateTime.utc_now(),
      decision_status: :open,
      answer: nil,
      urgency: :normal,
      blocking: false
    }
  end

  defp human_only(cause), do: %{policy: :human_only, state: :with_human, cause: cause}
end
