defmodule Aiur.Commands.OverridePrompt do
  @moduledoc "Refreshes unacknowledged overrides before every worker turn."

  require Logger

  alias Aiur.Commands
  alias Aiur.Commands.Overrides
  alias Aiur.DecisionRevisionDispatch

  @spec prepare(String.t(), keyword()) :: keyword()
  def prepare(identifier, opts) do
    store = Keyword.get(opts, :decision_store, Commands.default_store())

    pending =
      store
      |> Commands.list_decisions()
      |> Enum.filter(fn decision ->
        record = Overrides.pending(decision)

        decision.ticket.identifier == identifier and not is_nil(record) and
          record.route in [:resume_pending, :capacity_wait]
      end)

    Keyword.put(opts, :pending_overrides, pending)
  end

  @spec render(keyword()) :: String.t()
  def render(opts) do
    Enum.map_join(Keyword.get(opts, :pending_overrides, []), "\n", fn decision ->
      "Operator override — this replaces your earlier instruction for Command #{decision.decision_id}\n\n" <>
        DecisionRevisionDispatch.render(decision) <> "\n\n"
    end)
  end

  @doc "Only a confirmed provider turn start records prompt delivery."
  @spec received(map(), keyword()) :: :ok
  def received(message, opts) do
    payload = Map.get(message, :payload, Map.get(message, "payload", message))
    method = if is_map(payload), do: Map.get(payload, :method, Map.get(payload, "method"))

    if method in ["turn/started", :turn_started] or Map.get(message, :event) == :turn_started do
      Enum.each(Keyword.get(opts, :pending_overrides, []), &persist_receipt(&1, opts))
    end

    :ok
  end

  defp persist_receipt(decision, opts) do
    case Commands.record_command_fact(decision.decision_id, :override_prompt_delivered, %{action_id: decision.active_action_id, at: DateTime.utc_now()},
           server: Keyword.get(opts, :decision_store, Commands.default_store())
         ) do
      {:ok, _} -> :ok
      {:error, {:invalid_transition, :override_not_current}} -> :ok
      {:error, reason} -> receipt_failed(decision, reason)
    end
  catch
    :exit, reason -> receipt_failed(decision, reason)
  end

  defp receipt_failed(decision, reason),
    do: Logger.warning("Override prompt receipt could not persist: command=#{decision.decision_id} reason=#{inspect(reason)}; retrying at the next turn start")
end
