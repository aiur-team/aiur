defmodule Aiur.Commands.Routing.Sweep do
  @moduledoc false
  alias Aiur.Commands.Requester
  alias Aiur.Commands.Routing.Policy
  alias Aiur.DecisionStore

  @actor %{kind: :system, id: "routing"}

  @spec run([map()], Policy.liveness(), DateTime.t(), map(), GenServer.server()) :: {DateTime.t() | nil, [term()]}
  def run(decisions, liveness, now, config, store) do
    Enum.reduce(decisions, {nil, []}, fn decision, {due, errors} ->
      case process(decision, liveness, now, config, store) do
        {:ok, at} -> {earliest(due, at), errors}
        {:error, reason} -> {due, [{decision.decision_id, reason} | errors]}
      end
    end)
  end

  defp process(%{decision_status: status, answer: nil} = decision, liveness, now, config, store) when status in [:open, :deferred] do
    with {:ok, history} <- DecisionStore.audit_history(decision.decision_id, store),
         {:ok, routed} <- route(decision, history, liveness, now, store),
         {:ok, current} <- escalate(routed, history, liveness, now, config, store),
         :ok <- human_needed(current, history, liveness, now, store) do
      case Policy.escalation_due(current, now, config) do
        {:next, at} -> {:ok, at}
        _none -> {:ok, nil}
      end
    end
  end

  defp process(_decision, _liveness, _now, _config, _store), do: {:ok, nil}

  defp route(decision, history, liveness, now, store) do
    cond do
      deferred?(history) ->
        fact(decision, :routed, %{policy: :executor_first, state: :with_executor, cause: nil, actor: @actor, at: now}, store)

      is_nil(decision.routed_at) ->
        fact(decision, :routed, Policy.route(decision, liveness) |> Map.merge(%{actor: @actor, at: now}), store)

      true ->
        {:ok, decision}
    end
  end

  defp escalate(%{route_state: :with_executor} = decision, history, liveness, now, config, store) do
    cause =
      cond do
        explicit_escalation?(history) and not deferred?(history) -> :executor_escalated
        liveness == :offline -> :executor_offline
        liveness == :stalled -> :executor_stalled
        true -> deadline_cause(decision, now, config)
      end

    if cause, do: fact(decision, :escalated, %{cause: cause, at: now, actor: @actor}, store), else: {:ok, decision}
  end

  defp escalate(decision, _history, _liveness, _now, _config, _store), do: {:ok, decision}

  defp deadline_cause(decision, now, config) do
    case Policy.escalation_due(decision, now, config) do
      {:due, cause, _at} -> cause
      _none -> nil
    end
  end

  defp human_needed(%{human_visible_at: at, human_needed_at: nil} = decision, _history, liveness, now, store) when not is_nil(at) do
    # Re-read after writes to recover the actual visibility cause, including crash repair.
    {:ok, history} = DecisionStore.audit_history(decision.decision_id, store)

    cause =
      case Enum.find(Enum.reverse(history), &(&1.type in [:routed, :escalated] and not is_nil(&1.data.cause))) do
        nil -> List.last(decision.escalations, %{})[:cause] || Policy.route(decision, liveness).cause
        event -> event.data.cause
      end

    data = %{cause: cause, at: now, short_label: nil, requester_kind: Requester.kind(decision), blocking: decision.blocking, urgency: decision.urgency}

    case fact(decision, :human_needed, data, store) do
      {:ok, _updated} -> :ok
      error -> error
    end
  end

  defp human_needed(_decision, _history, _liveness, _now, _store), do: :ok

  defp deferred?(history), do: latest_control(history) == :decision_deferred
  defp explicit_escalation?(history), do: latest_control(history) == :executor_escalated

  defp latest_control(history) do
    case Enum.find(Enum.reverse(history), &(&1.type in [:routed, :decision_deferred, :executor_escalated])) do
      nil -> nil
      event -> event.type
    end
  end

  defp fact(decision, type, data, store) do
    case DecisionStore.record_command_fact(decision.decision_id, type, data, server: store) do
      {:ok, %{decision: updated}} -> {:ok, updated}
      error -> error
    end
  end

  defp earliest(nil, at), do: at
  defp earliest(at, nil), do: at
  defp earliest(a, b), do: if(DateTime.compare(a, b) == :lt, do: a, else: b)
end
