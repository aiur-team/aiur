defmodule Aiur.DecisionProjection.AuthorityReclassification do
  @moduledoc false

  alias Aiur.{Decision, DecisionEvent}

  @spec reclassifiable?(Decision.t()) :: boolean()
  def reclassifiable?(%Decision{} = decision), do: not human_only?(decision)

  @spec transition(term(), term()) :: {:ok, Decision.t()} | {:error, term()}
  def transition(
        %Decision{authority: :human_required} = decision,
        %DecisionEvent{
          type: :authority_reclassified,
          decision_version: next_version,
          data: %{authority: :supervisor_allowed, expected_version: expected_version}
        }
      ) do
    cond do
      decision.decision_status not in [:open, :deferred] -> {:error, :not_open}
      human_only?(decision) -> {:error, :human_authority_reclassification_forbidden}
      expected_version != decision.version or next_version != decision.version + 1 -> {:error, :version_mismatch}
      true -> {:ok, %{decision | authority: :supervisor_allowed, version: next_version}}
    end
  end

  def transition(_decision, _event), do: {:error, :unsupported_event}

  defp human_only?(decision) do
    not is_nil(decision.legacy_attention) or decision.kind == "legacy_attention" or
      not is_nil(Map.get(decision.context, :authority_basis))
  end
end
