defmodule Aiur.Orchestrator.ControlCLI.Output do
  @moduledoc false
  alias Aiur.ControlCLI.Reasons
  alias Aiur.Issue
  import Aiur.ControlCLI.Protocol
  @spec print_empty_selection(atom(), :all) :: :ok
  def print_empty_selection(:pause, :all), do: control_error("aiur: pause took no action because there are no running agents")
  def print_empty_selection(:resume, :all), do: control_error("aiur: resume took no action because there are no paused agents")

  @spec print_orchestrator_status_error(atom()) :: :ok
  def print_orchestrator_status_error(error) do
    control_error(
      Map.fetch!(
        %{
          timeout: "aiur: timed out while reading agent status",
          unavailable: "aiur: orchestrator is not running"
        },
        error
      )
    )
  end

  # A GenServer.call timeout does not cancel a mutation already in the mailbox.
  @spec print_failure(atom(), map(), term()) :: :ok
  def print_failure(action, status, :timeout) when action in [:resume, :reset_budget] do
    operation = if action == :resume, do: "resume", else: "reset lifetime dispatch budget for"

    control_error(
      "aiur: outcome unknown for #{operation} #{display_identifier(status)}: the orchestrator did not answer in time " <>
        "and may still apply the request. Check the ticket status and log before retrying."
    )
  end

  def print_failure(:resume, status, {:pause_override_clear_failed, reason}) do
    control_error("aiur: failed to resume #{display_identifier(status)}; resume will not hold because agent:paused could not be removed (#{Reasons.format_reason(reason)})")
  end

  def print_failure(:message, status, reason) do
    control_error("aiur: failed to message #{display_identifier(status)} (#{Reasons.format_message_reason(reason)})")
  end

  def print_failure(:reset_budget, status, reason) do
    control_error("aiur: failed to reset lifetime dispatch budget for #{display_identifier(status)} (#{Reasons.format_reason(reason)})")
  end

  def print_failure(action, status, reason) do
    control_error("aiur: failed to #{action} #{display_identifier(status)} (#{Reasons.format_reason(reason)})")
  end

  @spec target_matches?(map(), term()) :: boolean()
  def target_matches?(status, target) do
    Issue.identifier_matches?(status.issue_id, status.identifier, target)
  end

  @spec canonical_identifier(map()) :: String.t()
  def canonical_identifier(status) do
    to_string(status.identifier || status.issue_id)
  end

  @spec display_identifier(map()) :: String.t()
  def display_identifier(%{identifier: identifier, issue_id: issue_id}) do
    cond do
      issue_number_suffix(identifier) ->
        "##{issue_number_suffix(identifier)}"

      numeric_identifier?(identifier) ->
        "##{identifier}"

      numeric_identifier?(issue_id) ->
        "##{issue_id}"

      is_binary(identifier) and identifier != "" ->
        identifier

      true ->
        to_string(issue_id)
    end
  end

  defp issue_number_suffix(identifier) when is_binary(identifier) do
    case Regex.run(~r/#(\d+)$/, identifier) do
      [_, number] -> number
      _ -> nil
    end
  end

  defp issue_number_suffix(_identifier), do: nil

  defp numeric_identifier?(identifier) when is_binary(identifier),
    do: Regex.match?(~r/^\d+$/, identifier)

  defp numeric_identifier?(_identifier), do: false

  @spec print_global_pause_status_unavailable() :: {:error, :unavailable}
  def print_global_pause_status_unavailable do
    control_error("GLOBAL PAUSE STATUS UNAVAILABLE — cannot determine whether aiur is paused")
    {:error, :unavailable}
  end

  @spec print_global_pause_control_error(atom()) :: :ok
  def print_global_pause_control_error(_action) do
    control_error("error: aiur is globally paused; per-ticket resume is refused while new starts are paused.")
    control_error("Run `aiurdev resume` (no arguments) to lift the global pause.")
  end
end
