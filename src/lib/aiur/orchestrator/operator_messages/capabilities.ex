defmodule Aiur.Orchestrator.OperatorMessages.Capabilities do
  @moduledoc """
  Projects per-issue control capabilities, queue depth, and visible Executor messages.
  """

  alias Aiur.AgentQueueStore
  alias Aiur.Orchestrator.{ControlLifecycle, State}

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
        status: operator_message_status(item)
      }
    end)
  end

  @spec issue_control_capabilities(State.t(), String.t()) :: map()
  def issue_control_capabilities(%State{} = state, issue_identifier)
      when is_binary(issue_identifier) do
    running_entry = State.find_running_by_identifier(state.running, issue_identifier)

    issue_control_capabilities(state, issue_identifier, running_entry)
  end

  @doc false
  @spec issue_control_capabilities(State.t(), String.t(), map() | nil) :: map()
  def issue_control_capabilities(%State{} = state, issue_identifier, running_entry)
      when is_binary(issue_identifier) and (is_map(running_entry) or is_nil(running_entry)) do
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
      unit_control: unit_control_capability(running_entry),
      pending_control: pending_control(state, running_entry),
      queue_depth: queue_depth_for_issue(state, issue_identifier)
    }
    |> maybe_put(:latest_control, control_payload(state, running_entry, :latest))
    |> maybe_put(:latest_resume_control, control_payload(state, running_entry, :resume))
    |> maybe_put(:recent_controls, control_history_payload(state, running_entry))
  end

  defp operator_item_text(%{body: %{text: text}}) when is_binary(text), do: text
  defp operator_item_text(_item), do: ""

  defp operator_message_status(%{status: :failed}), do: :failed

  defp operator_message_status(%{provider_delivered_at: %DateTime{}}),
    do: :delivered

  defp operator_message_status(_item), do: :queued

  # The REPL backend forwards Executor messages straight into the live
  # process, so it offers :immediate instead of the hold-then-deliver
  # :checkpoint / :interrupt policies.
  defp accepted_delivery_policies(_can_interrupt, true), do: [:immediate]
  defp accepted_delivery_policies(true, false), do: [:checkpoint, :interrupt]
  defp accepted_delivery_policies(false, false), do: [:checkpoint]

  defp unit_control_capability(nil), do: :unsupported

  defp unit_control_capability(running_entry) do
    get_in(running_entry, [:control, :application_confirmation]) || :request_only
  end

  defp pending_control(%State{control_lifecycle: lifecycle}, %{issue: %{id: issue_id}}) do
    lifecycle
    |> ControlLifecycle.current_pending(issue_id)
    |> case do
      nil -> nil
      request -> ControlLifecycle.event_payload(request)
    end
  end

  defp pending_control(_state, _running_entry), do: nil

  defp control_payload(%State{control_lifecycle: lifecycle}, %{issue: %{id: issue_id}}, selector) do
    lifecycle
    |> select_control(issue_id, selector)
    |> case do
      nil -> nil
      request -> ControlLifecycle.event_payload(request)
    end
  end

  defp control_payload(_state, _running_entry, _selector), do: nil

  defp control_history_payload(%State{control_lifecycle: lifecycle}, %{issue: %{id: issue_id}}) do
    case ControlLifecycle.history(lifecycle, issue_id) do
      [] -> nil
      history -> Enum.map(history, &ControlLifecycle.event_payload/1)
    end
  end

  defp control_history_payload(_state, _running_entry), do: nil

  defp select_control(lifecycle, issue_id, :latest), do: ControlLifecycle.latest(lifecycle, issue_id)
  defp select_control(lifecycle, issue_id, :resume), do: ControlLifecycle.latest_for_action(lifecycle, issue_id, :resume)

  defp maybe_put(capabilities, _key, nil), do: capabilities
  defp maybe_put(capabilities, key, value), do: Map.put(capabilities, key, value)
end
