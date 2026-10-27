defmodule Aiur.Commands.Projection do
  @moduledoc "Projects additive Command facts without changing either lifecycle status."

  alias Aiur.Commands.Requester
  alias Aiur.Commands.Routing.Facts

  @routing_types Aiur.Commands.Routing.FactData.types()
  alias Aiur.Decision
  alias Aiur.DecisionEvent
  alias Aiur.DecisionProjection.TransitionValidation
  alias Aiur.JSONSafe

  @doc "Public attribution fields shared by the API and dashboard/CLI rows."
  @spec public_v2(Decision.t()) :: map()
  def public_v2(%Decision{} = decision) do
    %{
      requester: public_requester(decision),
      origin: JSONSafe.normalize(Requester.origin(decision)),
      native: public_native(decision.native),
      questions: JSONSafe.normalize(decision.questions),
      short_label: short_label(decision)
    }
    |> Map.merge(Facts.public(decision))
  end

  @doc false
  @spec attributed?(Decision.t()) :: boolean()
  def attributed?(decision) do
    not is_nil(decision.requester) or not is_nil(decision.origin) or
      not is_nil(decision.native) or decision.questions != [] or not is_nil(decision.short_label)
  end

  defp public_requester(%{requester: nil} = decision) do
    JSONSafe.normalize(%{kind: Requester.kind(decision), ticket: Requester.worker_ticket(decision)})
  end

  defp public_requester(decision) do
    decision.requester
    |> Map.take([:kind, :ticket, :session_ref, :executor_id, :harness])
    |> JSONSafe.normalize()
  end

  defp public_native(nil), do: nil

  defp public_native(native) do
    native |> Map.take([:harness, :hold, :question_ids]) |> JSONSafe.normalize()
  end

  # C1-T02 owns content-derived labels; until then only use the explicit summary.
  defp short_label(decision) do
    case decision.short_label || Map.get(decision.context, :short_summary) do
      label when is_binary(label) -> String.slice(label, 0, 40)
      _missing -> nil
    end
  end

  @doc false
  @spec inherit_attributes(Decision.t(), Decision.t()) :: Decision.t()
  def inherit_attributes(current, candidate) do
    fields = Map.take(current, [:requester, :origin, :native, :questions, :short_label])
    Facts.inherit(current, struct!(candidate, fields))
  end

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

  def apply(decision, %{type: type} = event) when type in @routing_types, do: Facts.apply(decision, event)
end
