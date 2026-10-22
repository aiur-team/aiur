defmodule AiurWeb.VoiceTargets do
  @moduledoc """
  Join-time target check for `voice:dictate` (voice-session contract §5.1).

  A dictation aimed at an agent that has stopped, or at a Command that was
  already resolved, is refused before recording starts instead of failing only
  when the operator presses Send. The rules are the ones the Send paths already
  use, so voice never accepts a target the composer would refuse:

    * worker — exactly one running entry with that issue identifier (the
      agent drawer's rule, `AgentLogModal`).
    * command — the Command still takes an answer (`DecisionAction`), at the
      version the client saw when one is given.
    * executor — not addressable yet (`unsupported_target`).

  Delivery stays with the surface's own Send; this check only refuses early.
  """

  require Logger

  alias Aiur.{DecisionStore, Identity}
  alias AiurWeb.EndpointConfig
  alias AiurWeb.OperatorControlCenter.{AgentLogModal, DecisionAction, PayloadLoader}

  @surfaces %{worker: "agent_composer", command: "command_response", executor: "executor_composer"}

  @type refusal :: %{reason: String.t(), reason_code: String.t()}

  @doc "`:ok`, or the join refusal (`reason` text and stable `reason_code`)."
  @spec validate(AiurWeb.VoiceJoinPayload.target(), String.t()) :: :ok | {:error, refusal()}
  def validate(%{kind: kind} = target, surface) do
    result =
      cond do
        Map.get(@surfaces, kind) != surface -> {:error, :invalid_payload}
        not same_instance?(target) -> {:error, :target_not_found}
        true -> check(target)
      end

    case result do
      :ok ->
        :ok

      {:error, code} ->
        Logger.debug("voice dictate target refused: #{code}")
        {:error, %{reason: reason(code, kind), reason_code: Atom.to_string(code)}}
    end
  end

  defp check(%{kind: :executor}), do: {:error, :unsupported_target}

  defp check(%{kind: :worker, ticket: ticket}) do
    payload = payload_fun().()

    cond do
      is_nil(AgentLogModal.find_running_entry(payload, ticket)) -> {:error, :target_not_found}
      AgentLogModal.unique_running_target?(payload, ticket) -> :ok
      true -> {:error, :target_not_writable}
    end
  rescue
    _error -> {:error, :unknown}
  catch
    :exit, _reason -> {:error, :unknown}
  end

  defp check(%{kind: :command, decision_id: decision_id, expected_version: expected_version}) do
    case DecisionStore.get(decision_id, decision_store()) do
      {:ok, decision} -> command_state(decision, expected_version)
      {:error, :not_found} -> {:error, :target_not_found}
    end
  catch
    # The store's state is unknowable here; never report the Command as gone.
    :exit, _reason -> {:error, :unknown}
  end

  defp command_state(decision, expected_version) do
    cond do
      not DecisionAction.answerable?(decision) -> {:error, :target_stale}
      expected_version not in [nil, decision.version] -> {:error, :target_stale}
      true -> :ok
    end
  end

  defp reason(:target_not_found, :worker), do: AgentLogModal.format_error(:no_running_agent)
  defp reason(:target_not_found, _kind), do: "This Command no longer exists."
  defp reason(:target_not_writable, _kind), do: AgentLogModal.format_error(:ambiguous_identifier)
  defp reason(:target_stale, _kind), do: "This Command has changed. Reload it before dictating an answer."
  defp reason(:unsupported_target, _kind), do: "Voice input can't address this target yet."
  defp reason(:invalid_payload, _kind), do: "Voice request is invalid."
  defp reason(:unknown, _kind), do: "The voice target could not be checked. Try again shortly."

  # Until every daemon carries an instance id, a target naming one is checked
  # only where this daemon knows its own.
  defp same_instance?(%{instance_id: nil}), do: true

  defp same_instance?(%{instance_id: instance_id}) do
    case Identity.instance_id() do
      nil -> true
      own -> own == instance_id
    end
  end

  defp payload_fun, do: EndpointConfig.get(:voice_target_payload_fun) || fn -> PayloadLoader.load(:cached) end
  defp decision_store, do: EndpointConfig.get(:decision_store) || Aiur.Commands.default_store()
end
