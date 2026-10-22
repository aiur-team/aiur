defmodule AiurWeb.VoiceTargets do
  @moduledoc """
  Join-time target check for `voice:dictate` (voice-session contract §5.1).

  A dictation aimed at an agent that has stopped, or at a Command that was
  already resolved, is refused before recording starts instead of failing only
  when the operator presses Send. This module owns the voice-side rules
  (surface per target kind, instance match, refusal text); whether a worker
  or Command can still take text is asked through `AiurWeb.VoiceTargetResolver`,
  bound to the same rules the Send paths use. Executor targets are not
  addressable yet (`unsupported_target`).

  Delivery stays with the surface's own Send; this check only refuses early.
  """

  require Logger

  alias Aiur.Identity
  alias AiurWeb.VoiceTargetResolver

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
  defp check(%{kind: :worker, ticket: ticket}), do: resolve(fn resolver -> resolver.worker(ticket) end)

  defp check(%{kind: :command, decision_id: decision_id, expected_version: version}),
    do: resolve(fn resolver -> resolver.command(decision_id, version) end)

  @resolver_refusals [:target_not_found, :target_not_writable, :target_stale, :unsupported_target, :unknown]

  # The target's state is unknowable when the resolver fails or answers outside
  # its contract; never report it as gone.
  defp resolve(fun) do
    case fun.(VoiceTargetResolver.impl()) do
      :ok -> :ok
      {:error, code} when code in @resolver_refusals -> {:error, code}
      _other -> {:error, :unknown}
    end
  rescue
    _error -> {:error, :unknown}
  catch
    _kind, _reason -> {:error, :unknown}
  end

  defp reason(:target_not_found, :worker), do: "Agent is no longer running."
  defp reason(:target_not_found, _kind), do: "This Command no longer exists."
  defp reason(:target_not_writable, _kind), do: "Agent actions require a unique typed target."
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
end
