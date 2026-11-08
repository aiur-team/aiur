defmodule Aiur.Commands.ExecutorDelivery do
  @moduledoc "Deliver Executor answers through the durable wake inbox before recording notification."

  alias Aiur.Commands
  alias Aiur.Commands.Requester
  alias Aiur.DecisionEvent.Validation
  alias Aiur.DecisionProjection.TransitionValidation

  @spec on_enqueued(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def on_enqueued(decision_id, action_id, opts \\ []) do
    Commands.record_command_fact(decision_id, :requester_notified, %{action_id: action_id, at: DateTime.utc_now(), channel: :wake_inbox}, opts)
  end

  @doc false
  @spec normalize(map()) :: {:ok, map()} | {:error, term()}
  def normalize(raw) do
    with {:ok, action_id} <- Validation.map_required_string(raw, :action_id, 256),
         channel when channel in [:wake_inbox, "wake_inbox"] <- Validation.get(raw, :channel),
         {:ok, at} <- timestamp(Validation.get(raw, :at)) do
      {:ok, %{action_id: action_id, channel: :wake_inbox, at: at}}
    else
      {:error, _reason} = error -> error
      _other -> {:error, {:channel, :invalid_enum}}
    end
  end

  @doc false
  @spec apply_fact(Aiur.Decision.t(), Aiur.DecisionEvent.t()) :: {:ok, Aiur.Decision.t()} | {:error, term()}
  def apply_fact(decision, event) do
    with :ok <- TransitionValidation.require_current_version(decision, event.decision_version),
         true <- Requester.executor?(decision),
         true <- decision.active_action_id == event.data.action_id do
      {:ok, %{decision | requester_notified_at: decision.requester_notified_at || event.data.at}}
    else
      false -> {:error, :requester_notification_mismatch}
      error -> error
    end
  end

  defp timestamp(%DateTime{} = at), do: {:ok, at}

  defp timestamp(raw) when is_binary(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, at, _offset} -> {:ok, at}
      _invalid -> {:error, {:at, :invalid_timestamp}}
    end
  end

  defp timestamp(_raw), do: {:error, {:at, :invalid_timestamp}}
end
