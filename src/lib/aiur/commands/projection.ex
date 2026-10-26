defmodule Aiur.Commands.Projection do
  @moduledoc "Projects additive Command facts without changing either lifecycle status."

  alias Aiur.Commands.Requester
  alias Aiur.Decision
  alias Aiur.DecisionEvent
  alias Aiur.DecisionProjection.TransitionValidation

  @spec apply(Decision.t(), DecisionEvent.t()) :: {:ok, Decision.t()} | {:error, term()}
  def apply(decision, %DecisionEvent{type: :request_attributed} = event) do
    with :ok <- TransitionValidation.require_current_version(decision, event.decision_version) do
      # Every attribution sets origin, including an otherwise empty fact.
      # Fresh requested snapshots leave it nil, resetting idempotence per version.
      if is_nil(decision.origin) do
        fields = Map.put(event.data, :origin, event.data.origin || Requester.origin(decision))
        {:ok, struct!(decision, fields)}
      else
        {:ok, decision}
      end
    end
  end
end
