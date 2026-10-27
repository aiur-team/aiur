defmodule Aiur.Commands.RollbackTest do
  use ExUnit.Case, async: true

  alias Aiur.Commands.EventData
  alias Aiur.DecisionEvent
  alias Aiur.DecisionEvent.Unrecognized
  alias Aiur.DecisionProjection
  alias Aiur.DecisionValidation

  # Compatibility guard for the existing rollback reader, including every new fact type.
  test "every Command fact retains its opaque envelope and leaves the old projection unchanged" do
    {:ok, decision} = DecisionValidation.normalize(%{question: "Choose?", blocking: false}, ticket: %{identifier: "123"})
    at = DateTime.utc_now()
    actor = %{kind: :system, id: "routing"}

    fixtures = %{
      request_attributed: %{requester: %{kind: :executor}, origin: :executor_cli},
      routed: %{policy: :executor_first, state: :with_executor, cause: nil, at: at, actor: actor},
      escalated: %{cause: :executor_ack_timeout, at: at, detail: "Timeout", actor: actor},
      human_needed: %{cause: :executor_ack_timeout, at: at, short_label: "Choose", requester_kind: :worker, blocking: false, urgency: :normal},
      executor_acknowledged: %{executor_id: "executor", via: :explicit, at: at}
    }

    for type <- EventData.fact_types() do
      assert {:ok, event} = DecisionEvent.new(type, decision.decision_id, 1, Map.fetch!(fixtures, type), event_id: "fact-1", run_id: "rollback-run")
      raw = event |> DecisionEvent.to_json_safe() |> Jason.encode!() |> Jason.decode!()
      assert {:ok, opaque} = Unrecognized.decode(raw, Atom.to_string(type))
      assert opaque.raw == raw
      assert opaque.event_id == event.event_id
      assert {projection, nil} = DecisionProjection.reduce_checked([decision, opaque])
      assert projection.current[decision.decision_id] == decision
    end
  end
end
