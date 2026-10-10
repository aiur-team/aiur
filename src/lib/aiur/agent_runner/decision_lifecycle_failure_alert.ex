defmodule Aiur.AgentRunner.DecisionLifecycleFailureAlert do
  @moduledoc false

  require Logger

  alias Aiur.Alerts

  @spec recording_failed(term(), map(), String.t(), term()) :: {:ok, %{status: String.t()}}
  def recording_failed(issue, payload, name, reason) do
    decision_id = Map.get(payload, "decision_id", "unknown")

    Logger.error(
      "Decision lifecycle recording failed ticket=#{issue_identifier(issue)} decision=#{decision_id} name=#{name} reason=#{inspect(reason)}"
    )

    try do
      Alerts.emit_custom(
        "system.decision_lifecycle.recording_failed",
        "Could not record #{name} for decision #{decision_id}.",
        issue: issue,
        reason: "Durable decision lifecycle recording failed: #{inspect(reason)}",
        needs_attention: false,
        severity: "error",
        event_source: :system
      )
    rescue
      _error -> :ok
    end

    {:ok, %{status: "recording_failed"}}
  end

  defp issue_identifier(%{identifier: identifier}), do: identifier || "unknown"
  defp issue_identifier(_issue), do: "unknown"
end
