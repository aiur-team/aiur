defmodule Aiur.GitHub.StateWriteCoordinator do
  @moduledoc false

  alias Aiur.Alerts
  alias Aiur.GitHub.{IssueState, Labels}

  @spec with_lock(String.t(), function()) :: term()
  def with_lock(issue_number, fun) when is_binary(issue_number) and is_function(fun, 0) do
    :global.trans({{__MODULE__, issue_number}, self()}, fun)
  end

  @spec verify_state_labels(map(), String.t(), [String.t()]) :: :ok | {:error, term()}
  def verify_state_labels(context, intended_label, labels) when is_list(labels) do
    states = Enum.filter(labels, &(String.downcase(&1) in state_labels(context.prefix)))

    case states do
      [label] ->
        if String.downcase(label) == String.downcase(intended_label) do
          :ok
        else
          emit(
            context,
            "state_label_replaced_after_swap",
            "State-label removal left issue #{context.issue_number} with #{label} instead of #{intended_label}."
          )

          {:error, {:state_label_replaced_after_swap, label}}
        end

      [] ->
        emit(
          context,
          "state_label_restored",
          "State-label removal left issue #{context.issue_number} without a workflow state; restoring #{intended_label}."
        )

        case IssueState.add_label(context.issue_number, intended_label, request_fun: context.request_fun) do
          :ok -> :ok
          {:error, reason} -> {:error, {:state_label_restore_failed, intended_label, reason}}
        end

      _ ->
        emit(
          context,
          "contradictory_state_labels",
          "State-label removal left issue #{context.issue_number} with #{length(states)} workflow state labels: #{inspect(states)}."
        )

        {:error, {:contradictory_state_labels_after_swap, states}}
    end
  end

  defp state_labels(prefix), do: Enum.map(Labels.state_labels(prefix), &String.downcase/1)

  defp emit(context, suffix, message) do
    emit_alert = Keyword.get(context.opts, :emit_state_label_alert_fun, &Alerts.emit_system/2)

    emit_alert.("ticket.#{context.issue_number}.#{suffix}",
      message: message,
      reason: "state labels did not match the completed serialized transition",
      needs_attention: true,
      severity: "critical"
    )
  end
end
