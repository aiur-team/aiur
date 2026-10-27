defmodule Aiur.Commands.Routing.FactData do
  @moduledoc false

  alias Aiur.DecisionAnswer
  alias Aiur.DecisionEvent.Validation

  @types [:routed, :escalated, :human_needed, :executor_acknowledged]
  @causes ~w(executor_originated executor_offline executor_stalled authority_human_required executor_not_answerable executor_ack_timeout executor_answer_timeout executor_escalated)a

  @spec types() :: [atom()]
  def types, do: @types

  @spec normalize(atom(), map()) :: {:ok, map()} | {:error, term()}
  def normalize(type, raw) do
    with {:ok, at} <- timestamp(Validation.get(raw, :at)),
         {:ok, fields} <- fields(type, raw) do
      {:ok, Map.put(fields, :at, at)}
    end
  end

  defp fields(:routed, raw) do
    with {:ok, policy} <- enum(raw, :policy, [:executor_first, :simultaneous, :human_only]),
         {:ok, state} <- enum(raw, :state, [:with_executor, :with_both, :with_human]),
         {:ok, cause} <- enum(raw, :cause, [nil | @causes]),
         {:ok, %{kind: :system, id: "routing"} = actor} <- DecisionAnswer.normalize_actor(Validation.get(raw, :actor)) do
      {:ok, %{policy: policy, state: state, cause: cause, actor: actor}}
    else
      {:ok, _actor} -> {:error, {:actor, :routing_required}}
      error -> error
    end
  end

  defp fields(:escalated, raw) do
    with {:ok, cause} <- enum(raw, :cause, @causes),
         {:ok, detail} <- Validation.bounded_optional(Validation.get(raw, :detail), 200, :detail),
         {:ok, actor} <- DecisionAnswer.normalize_actor(Validation.get(raw, :actor)) do
      {:ok, %{cause: cause, detail: detail, actor: actor}}
    end
  end

  defp fields(:human_needed, raw) do
    with {:ok, cause} <- enum(raw, :cause, @causes),
         {:ok, label} <- Validation.bounded_optional(Validation.get(raw, :short_label), 40, :short_label),
         {:ok, requester} <- enum(raw, :requester_kind, [:worker, :executor]),
         {:ok, urgency} <- enum(raw, :urgency, [:low, :normal, :high, :critical]),
         blocking when is_boolean(blocking) <- Validation.get(raw, :blocking) do
      {:ok, %{cause: cause, short_label: label, requester_kind: requester, blocking: blocking, urgency: urgency}}
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, {:blocking, :invalid_type}}
    end
  end

  defp fields(:executor_acknowledged, raw) do
    with {:ok, id} <- Validation.map_required_string(raw, :executor_id, 256),
         {:ok, via} <- enum(raw, :via, [:explicit, :answer, :escalate, :moot, :supersede]) do
      {:ok, %{executor_id: id, via: via}}
    end
  end

  defp enum(raw, key, allowed) do
    value = Validation.get(raw, key)

    case Enum.find(allowed, :invalid, &(&1 == value or (is_binary(value) and to_string(&1) == value))) do
      :invalid -> {:error, {key, :invalid_enum}}
      found -> {:ok, found}
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
