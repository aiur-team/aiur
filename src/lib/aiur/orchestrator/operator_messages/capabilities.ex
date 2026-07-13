defmodule Aiur.Orchestrator.OperatorMessages.Capabilities do
  @moduledoc """
  Projects per-issue control capabilities, queue depth, and visible Executor messages.
  """

  alias Aiur.AgentQueueStore
  alias Aiur.Orchestrator.State

  @spec queue_depth_for_issue(State.t(), String.t()) :: non_neg_integer()
  def queue_depth_for_issue(%State{} = state, issue_identifier)
      when is_binary(issue_identifier) do
    state.queue_store |> AgentQueueStore.list_pending(issue_identifier) |> length()
  end

  @spec pending_operator_messages_for_issue(State.t(), String.t()) :: [map()]
  def pending_operator_messages_for_issue(%State{} = state, issue_identifier)
      when is_binary(issue_identifier) do
    state.queue_store
    |> AgentQueueStore.list_visible_operator_messages(issue_identifier)
    |> Enum.map(fn item ->
      %{
        id: item.id,
        # item is an %AgentQueueItem{} struct (no Access), so reach into its body
        # map directly rather than via get_in/2 — the latter crashed the whole
        # Orchestrator whenever the dashboard rendered an issue with a visible
        # Executor message.
        text: operator_item_text(item),
        status: item.status
      }
    end)
  end

  @spec issue_control_capabilities(State.t(), String.t()) :: map()
  def issue_control_capabilities(%State{} = state, issue_identifier)
      when is_binary(issue_identifier) do
    running_entry = State.find_running_by_identifier(state.running, issue_identifier)
    can_interrupt = get_in(running_entry || %{}, [:control, :can_interrupt]) == true
    safe_checkpoints = get_in(running_entry || %{}, [:control, :safe_checkpoints]) || []
    immediate_delivery = get_in(running_entry || %{}, [:control, :immediate_delivery]) == true
    accepts_operator_messages = not is_nil(running_entry)

    %{
      accepts_operator_messages: accepts_operator_messages,
      can_interrupt: can_interrupt,
      immediate_delivery: immediate_delivery,
      accepted_delivery_policies: accepted_delivery_policies(can_interrupt, immediate_delivery),
      safe_checkpoints: safe_checkpoints,
      status: get_in(running_entry || %{}, [:control, :status]) || :working,
      queue_depth: queue_depth_for_issue(state, issue_identifier)
    }
  end

  defp operator_item_text(%{body: %{text: text}}) when is_binary(text), do: text
  defp operator_item_text(_item), do: ""

  # The REPL backend forwards Executor messages straight into the live
  # process, so it offers :immediate instead of the hold-then-deliver
  # :checkpoint / :interrupt policies.
  defp accepted_delivery_policies(_can_interrupt, true), do: [:immediate]
  defp accepted_delivery_policies(true, false), do: [:checkpoint, :interrupt]
  defp accepted_delivery_policies(false, false), do: [:checkpoint]
end
