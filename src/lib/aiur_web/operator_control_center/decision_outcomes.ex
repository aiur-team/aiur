defmodule AiurWeb.OperatorControlCenter.DecisionOutcomes do
  @moduledoc "Dashboard copy for the shared Command answer outcomes."

  @spec outcome_notice(map()) :: {:success | :error, String.t(), [atom()]}
  def outcome_notice(%{status: status, decision: decision, delivery: delivery}) when status in [:accepted, :duplicate] do
    ticket = decision.ticket.identifier

    text =
      case delivery do
        :delivered -> "Delivered to ##{ticket} at #{time(delivered_at(decision))}"
        :queued_for_restart -> "Answer recorded. ##{ticket} is not running; it will receive it when it restarts."
        :pending -> "Answer recorded. Delivering to ##{ticket}…"
      end

    {:success, text, []}
  end

  def outcome_notice(%{status: :already_answered, winner: winner}) when is_map(winner) do
    {:error, "Already answered by #{actor_label(winner)} at #{time(winner.accepted_at)}: '#{winner.summary}'", []}
  end

  def outcome_notice(%{status: :too_late, reason: :answer_in_flight}),
    do: {:error, "Delivery is in progress. Send a follow-up message instead.", [:follow_up]}

  def outcome_notice(%{status: :too_late} = outcome),
    do: {:error, "Already delivered at #{time(Map.get(outcome, :delivered_at))}. Send a follow-up message instead.", [:follow_up]}

  def outcome_notice(%{status: :withdrawn, reason: reason}), do: {:error, "No longer needed: #{reason}", []}
  def outcome_notice(%{status: :stale}), do: {:error, "This Command changed. Refresh to see the latest.", [:refresh]}
  def outcome_notice(%{status: :not_allowed}), do: {:error, "You cannot replace this answer.", []}
  def outcome_notice(%{status: :error, reason: :store_unavailable}), do: {:error, "Command storage is currently unavailable.", []}
  def outcome_notice(%{status: :error, reason: {:store_unavailable, _reason}}), do: {:error, "Command storage is read-only or unavailable.", []}
  def outcome_notice(%{status: :error, reason: {:answer_invalid, {:option_id, :unknown}}}), do: {:error, "That option is no longer available.", []}
  def outcome_notice(_unknown), do: {:error, "The command was rejected. Canonical state was refreshed.", []}

  @spec replaceable?(map()) :: boolean()
  def replaceable?(%{decision_status: :decided, conflict_summary: %{actor_kind: :executor, replaceable: true}}), do: true
  def replaceable?(_decision), do: false

  @spec disabled?(map(), map()) :: boolean()
  def disabled?(decision, state) do
    match?(%{status: status} when status in [:too_late, :withdrawn], state[:outcome]) or
      withdrawn?(decision) or
      match?(%{delivered?: true}, decision[:conflict_summary]) or match?(%{in_flight?: true}, decision[:conflict_summary])
  end

  @spec canonical_notice(map()) :: map() | nil
  def canonical_notice(%{decision_status: :expired, blocking: true, answer: nil}), do: nil
  def canonical_notice(%{decision_status: status}) when status in [:moot, :expired], do: %{status: :withdrawn, reason: status}

  def canonical_notice(%{conflict_summary: %{delivered?: true}} = decision),
    do: %{status: :accepted, delivery: :delivered, decision: decision}

  def canonical_notice(%{conflict_summary: %{in_flight?: true}} = decision), do: %{status: :accepted, delivery: :pending, decision: decision}
  def canonical_notice(%{conflict_summary: %{actor_kind: :executor} = winner}), do: %{status: :already_answered, winner: winner}

  def canonical_notice(%{pending_for_session?: true, answer: answer} = decision) when is_map(answer),
    do: %{status: :accepted, decision: decision, delivery: :queued_for_restart}

  def canonical_notice(%{decision_status: :resolved}), do: %{status: :withdrawn, reason: :resolved}
  def canonical_notice(_decision), do: nil

  @spec delivered_at(map()) :: DateTime.t() | nil
  def delivered_at(decision) do
    Enum.find_value(decision.dispatch_attempts, & &1.delivered_at) || get_in(decision, [:acknowledgement, :occurred_at])
  end

  defp withdrawn?(%{decision_status: :expired, blocking: true, answer: nil}), do: false
  defp withdrawn?(%{decision_status: status}), do: status in [:moot, :expired, :resolved]
  defp withdrawn?(_decision), do: false

  defp time(%DateTime{} = at), do: at |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  defp time(_unknown), do: "an unknown time"
  defp actor_label(%{actor_kind: :executor}), do: "the Executor"
  defp actor_label(%{actor_kind: :operator}), do: "you on another device"
  defp actor_label(%{actor_kind: kind}), do: kind |> to_string() |> String.replace("_", " ")
end
