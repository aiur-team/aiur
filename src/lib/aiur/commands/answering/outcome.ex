defmodule Aiur.Commands.Answering.Outcome do
  @moduledoc false
  alias Aiur.Commands.ConflictSummary
  alias Aiur.{Decision, DecisionStore}

  @type t ::
          %{status: :accepted | :duplicate, decision: Decision.t(), delivery: :pending | :delivered | :queued_for_restart}
          | %{status: :already_answered, winner: ConflictSummary.t() | nil}
          | %{status: :too_late, reason: :answer_delivered | :answer_in_flight, winner: ConflictSummary.t() | nil}
          | %{status: :withdrawn, reason: :expired | :moot | :resolved | :dismissed}
          | %{status: :stale, current_version: pos_integer()}
          | %{status: :not_allowed, reason: :human_answer | :direct_operator_answer | :executor_scope | :invalid_actor}
          | %{status: :error, reason: term()}

  @spec normalize(term(), keyword()) :: t()
  def normalize(result, opts) do
    do_normalize(result, opts)
  catch
    :exit, _reason -> %{status: :error, reason: :store_unavailable}
  end

  defp do_normalize({:ok, %{status: status, decision: decision}}, _opts) when status in [:accepted, :duplicate],
    do: %{status: status, decision: decision, delivery: delivery(decision)}

  defp do_normalize({:error, {:conflict, {:already_decided, _action}}}, opts),
    do: with_winner(:already_answered, %{}, opts)

  defp do_normalize({:error, {:conflict, reason}}, opts) when reason in [:answer_delivered, :answer_in_flight],
    do: with_winner(:too_late, %{reason: reason}, opts)

  defp do_normalize({:error, {:conflict, {reason, _action}}}, _opts) when reason in [:human_answer, :direct_operator_answer],
    do: %{status: :not_allowed, reason: reason}

  defp do_normalize({:error, {:conflict, {:stale_version, _expected, current}}}, _opts),
    do: %{status: :stale, current_version: current}

  defp do_normalize({:error, {:conflict, status}}, _opts) when status in [:expired, :moot, :resolved, :dismissed],
    do: %{status: :withdrawn, reason: status}

  defp do_normalize({:error, {:answer_invalid, {:executor_scope, _scope}}}, _opts), do: %{status: :not_allowed, reason: :executor_scope}
  defp do_normalize({:error, reason}, _opts), do: %{status: :error, reason: reason}

  defp with_winner(status, fields, opts) do
    case DecisionStore.get(Keyword.fetch!(opts, :decision_id), Keyword.get(opts, :store, DecisionStore)) do
      {:ok, decision} -> Map.merge(fields, %{status: status, winner: ConflictSummary.for(decision, Keyword.fetch!(opts, :actor))})
      {:error, reason} -> %{status: :error, reason: reason}
    end
  end

  defp delivery(%Decision{delivery_status: status}) when status in [:delivered, :consumed], do: :delivered
  defp delivery(%Decision{pending_for_session?: true}), do: :queued_for_restart
  defp delivery(%Decision{}), do: :pending
end
