defmodule AiurWeb.OperatorControlCenter.VoiceTargetResolver do
  @moduledoc """
  The dashboard's answer to `AiurWeb.VoiceTargetResolver`: voice accepts a
  target only where the dashboard's own Send would.

    * worker — exactly one running entry with that issue identifier, from the
      same cached payload the agent drawer reads (`AgentLogModal`).
    * command — the Command still takes an answer (`DecisionAction`), read
      through the `Aiur.Commands` facade, at the version the client saw.
  """

  @behaviour AiurWeb.VoiceTargetResolver

  alias Aiur.Commands
  alias AiurWeb.EndpointConfig
  alias AiurWeb.OperatorControlCenter.{AgentLogModal, DecisionAction, PayloadLoader}

  @impl true
  def worker(ticket) do
    payload = payload_fun().()

    cond do
      is_nil(AgentLogModal.find_running_entry(payload, ticket)) -> {:error, :target_not_found}
      AgentLogModal.unique_running_target?(payload, ticket) -> :ok
      true -> {:error, :target_not_writable}
    end
  end

  @impl true
  def command(decision_id, expected_version) do
    case Commands.get(decision_id, store: decision_store()) do
      {:ok, %{decision: decision}} -> command_state(decision, expected_version)
      {:error, :not_found} -> {:error, :target_not_found}
      {:error, {:invalid_decision_id, _reason}} -> {:error, :target_not_found}
      # Unavailable or partial store: the Command's state is unknowable, not gone.
      {:error, _unavailable} -> {:error, :unknown}
    end
  end

  defp command_state(decision, expected_version) do
    cond do
      not DecisionAction.answerable?(decision) -> {:error, :target_stale}
      expected_version not in [nil, decision.version] -> {:error, :target_stale}
      true -> :ok
    end
  end

  defp payload_fun, do: EndpointConfig.get(:voice_target_payload_fun) || fn -> PayloadLoader.load(:cached) end
  defp decision_store, do: EndpointConfig.get(:decision_store) || Commands.default_store()
end
