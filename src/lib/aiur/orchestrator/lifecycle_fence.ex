defmodule Aiur.Orchestrator.LifecycleFence do
  @moduledoc """
  Orchestrator-owned fence for authoritative input that has not reached the
  provider yet.

  The fence lives on the running entry and is keyed by concrete queue item IDs,
  so queue claim cannot be mistaken for provider delivery and duplicate event
  routing cannot create an anonymous epoch.
  """

  require Logger

  alias Aiur.AgentQueueItem
  alias Aiur.Issue
  alias Aiur.Orchestrator.{DispatchPolicy, State}
  alias Aiur.Orchestrator.OperatorMessages.DeliveryPolicy
  alias Aiur.Tracker

  @pr_anchored_state "pr-watch"

  @type t :: %{
          generation: pos_integer(),
          authoritative_state: String.t() | nil,
          pending_item_ids: MapSet.t(integer()),
          opened_at: DateTime.t()
        }

  @spec protect_queued_item(State.t(), String.t(), AgentQueueItem.t()) :: State.t()
  def protect_queued_item(%State{} = state, identifier, %AgentQueueItem{} = item)
      when is_binary(identifier) do
    case {State.find_running_key_by_identifier(state.running, identifier), authoritative_item?(item)} do
      {nil, _authoritative?} ->
        state

      {_issue_id, false} ->
        state

      {issue_id, true} ->
        protect_running_entry(state, issue_id, item)
    end
  end

  @spec acknowledge_provider_delivery(State.t(), AgentQueueItem.t()) :: State.t()
  def acknowledge_provider_delivery(%State{} = state, %AgentQueueItem{} = item) do
    case State.find_running_key_by_identifier(state.running, item.target_issue_identifier) do
      nil ->
        state

      issue_id ->
        update_fence(state, issue_id, &remove_pending_item(&1, item.id))
    end
  end

  @spec protected_item?(State.t(), AgentQueueItem.t() | integer()) :: boolean()
  def protected_item?(%State{} = state, %AgentQueueItem{id: item_id}),
    do: protected_item?(state, item_id)

  def protected_item?(%State{} = state, item_id) when is_integer(item_id) do
    Enum.any?(state.running, fn
      {_issue_id, %{lifecycle_fence: %{pending_item_ids: pending_item_ids}}} ->
        MapSet.member?(pending_item_ids, item_id)

      _entry ->
        false
    end)
  end

  @spec reconcile_observed_state(State.t(), Issue.t()) :: :admit | {:fenced, State.t()}
  def reconcile_observed_state(%State{} = state, %Issue{} = issue) do
    case running_fence(state, issue) do
      {issue_id, %{authoritative_state: nil}} ->
        case normalize_state(issue.state) do
          observed_state when is_binary(observed_state) ->
            {:fenced, adopt_observed_state(state, issue_id, issue, observed_state)}

          _ ->
            {:fenced, state}
        end

      {issue_id, %{authoritative_state: authoritative_state}}
      when is_binary(authoritative_state) ->
        actual_state = normalize_state(issue.state)

        cond do
          actual_state == authoritative_state ->
            {:fenced, state}

          actual_state == "rework" ->
            {:fenced, adopt_observed_state(state, issue_id, issue, actual_state)}

          true ->
            {:fenced,
             restore_authoritative_state(
               state,
               issue,
               actual_state,
               authoritative_state
             )}
        end

      _none ->
        :admit
    end
  end

  @spec handoff_blocked?(State.t(), Issue.t()) :: boolean()
  def handoff_blocked?(%State{} = state, %Issue{} = issue) do
    match?({_issue_id, _fence}, running_fence(state, issue))
  end

  @spec fence_for_entry(map()) :: map() | nil
  def fence_for_entry(%{lifecycle_fence: %{pending_item_ids: %MapSet{} = pending_item_ids} = fence}) do
    if MapSet.size(pending_item_ids) > 0, do: fence, else: nil
  end

  def fence_for_entry(_entry), do: nil

  defp protect_running_entry(state, issue_id, item) do
    entry = Map.fetch!(state.running, issue_id)
    existing_fence = fence_for_entry(entry)
    comment_rework? = trusted_comment_item?(item) and not pr_anchored_entry?(entry)

    fence = %{
      generation: next_generation(existing_fence),
      authoritative_state: derive_authoritative_state(existing_fence, entry, comment_rework?),
      pending_item_ids: put_pending_item(existing_fence, item.id),
      opened_at: DateTime.utc_now()
    }

    updated_entry =
      entry
      |> maybe_refresh_comment_rework(comment_rework?)
      |> Map.put(:lifecycle_fence, fence)

    %{state | running: Map.put(state.running, issue_id, updated_entry)}
  end

  defp derive_authoritative_state(existing_fence, entry, comment_rework?) do
    cond do
      comment_rework? -> "rework"
      is_map(existing_fence) -> existing_fence.authoritative_state
      State.completed_provenance?(entry) -> nil
      true -> normalize_state(get_in(entry, [:issue, Access.key(:state)])) || "in-progress"
    end
  end

  defp next_generation(%{generation: generation}) when is_integer(generation), do: generation + 1
  defp next_generation(_existing_fence), do: 1

  defp put_pending_item(%{pending_item_ids: %MapSet{} = pending_item_ids}, item_id),
    do: MapSet.put(pending_item_ids, item_id)

  defp put_pending_item(_existing_fence, item_id), do: MapSet.new([item_id])

  @spec remove_pending_item(t(), integer()) :: t() | nil
  defp remove_pending_item(fence, item_id) do
    remaining = MapSet.delete(fence.pending_item_ids, item_id)

    if MapSet.size(remaining) == 0, do: nil, else: %{fence | pending_item_ids: remaining}
  end

  defp authoritative_item?(%AgentQueueItem{category: :operator_message}), do: true
  defp authoritative_item?(%AgentQueueItem{} = item), do: trusted_comment_item?(item)

  defp trusted_comment_item?(%AgentQueueItem{
         category: :coordination_event,
         event_type: :events_digest,
         body: %{events: events}
       })
       when is_list(events),
       do: DeliveryPolicy.trusted_comment_event_digest?(events)

  defp trusted_comment_item?(_item), do: false

  defp pr_anchored_entry?(%{issue: %Issue{state: state}}),
    do: normalize_state(state) == @pr_anchored_state

  defp pr_anchored_entry?(_entry), do: false

  defp maybe_refresh_comment_rework(%{issue: %Issue{} = issue} = entry, true),
    do: %{entry | issue: %{issue | state: "rework"}}

  defp maybe_refresh_comment_rework(entry, _comment_rework?), do: entry

  defp running_fence(state, issue) do
    issue_id =
      cond do
        is_binary(issue.id) and Map.has_key?(state.running, issue.id) -> issue.id
        is_binary(issue.identifier) -> State.find_running_key_by_identifier(state.running, issue.identifier)
        true -> nil
      end

    case Map.get(state.running, issue_id) do
      nil -> nil
      entry -> if fence = fence_for_entry(entry), do: {issue_id, fence}
    end
  end

  defp restore_authoritative_state(state, issue, actual_state, authoritative_state)
       when actual_state == "closed" do
    retain_terminal_handoff(state, issue, actual_state, authoritative_state)
  end

  defp restore_authoritative_state(state, issue, actual_state, authoritative_state)
       when is_binary(actual_state) do
    if DispatchPolicy.terminal_issue_state?(
         actual_state,
         DispatchPolicy.terminal_state_set()
       ) do
      retain_terminal_handoff(state, issue, actual_state, authoritative_state)
    else
      restore_nonterminal_authoritative_state(
        state,
        issue,
        actual_state,
        authoritative_state
      )
    end
  end

  defp restore_authoritative_state(state, issue, actual_state, authoritative_state) do
    Logger.warning(
      "Lifecycle handoff rejected while authoritative input is undelivered: " <>
        "#{State.issue_context(issue)} observed_state=#{inspect(actual_state)} " <>
        "authoritative_state=#{authoritative_state} decision=keep_runner"
    )

    state
  end

  defp adopt_observed_state(state, issue_id, issue, observed_state) do
    entry = Map.fetch!(state.running, issue_id)
    fence = Map.fetch!(entry, :lifecycle_fence)

    updated_fence = %{
      fence
      | authoritative_state: observed_state,
        generation: fence.generation + 1,
        opened_at: DateTime.utc_now()
    }

    cached_issue =
      case Map.get(entry, :issue) do
        %Issue{} = existing -> %{existing | state: observed_state}
        _other -> %{issue | state: observed_state}
      end

    updated_entry =
      entry
      |> Map.put(:issue, cached_issue)
      |> Map.put(:lifecycle_fence, updated_fence)

    Logger.info(
      "Lifecycle fence adopted observed tracker state: " <>
        "#{State.issue_context(issue)} generation=#{updated_fence.generation}"
    )

    %{state | running: Map.put(state.running, issue_id, updated_entry)}
  end

  defp restore_nonterminal_authoritative_state(
         state,
         issue,
         actual_state,
         authoritative_state
       ) do
    issue_key = to_string(issue.id || issue.identifier)

    case Tracker.update_issue_state(issue_key, authoritative_state, expected_state: actual_state) do
      :ok ->
        Logger.info(
          "Stale lifecycle handoff restored while authoritative input is undelivered: " <>
            "#{State.issue_context(issue)} observed_state=#{actual_state} " <>
            "authoritative_state=#{authoritative_state}"
        )

        refresh_cached_authoritative_state(state, issue, authoritative_state)

      {:error, reason} ->
        Logger.warning(
          "Lifecycle handoff restore deferred while authoritative input is undelivered: " <>
            "#{State.issue_context(issue)} observed_state=#{actual_state} " <>
            "authoritative_state=#{authoritative_state} reason=#{inspect(reason)}"
        )

        state
    end
  end

  defp retain_terminal_handoff(state, issue, actual_state, authoritative_state) do
    Logger.warning(
      "Terminal lifecycle handoff held locally while authoritative input is undelivered: " <>
        "#{State.issue_context(issue)} observed_state=#{actual_state} " <>
        "authoritative_state=#{authoritative_state} decision=keep_runner_without_reopening"
    )

    state
  end

  defp refresh_cached_authoritative_state(state, issue, authoritative_state) do
    case running_fence(state, issue) do
      {issue_id, _fence} ->
        update_in(state.running[issue_id].issue, fn
          %Issue{} = cached_issue -> %{cached_issue | state: authoritative_state}
          other -> other
        end)

      nil ->
        state
    end
  end

  defp update_fence(state, issue_id, update) do
    case Map.get(state.running, issue_id) do
      %{lifecycle_fence: fence} = entry ->
        updated_entry =
          case update.(fence) do
            nil -> Map.delete(entry, :lifecycle_fence)
            updated_fence -> Map.put(entry, :lifecycle_fence, updated_fence)
          end

        %{state | running: Map.put(state.running, issue_id, updated_entry)}

      _entry ->
        state
    end
  end

  defp normalize_state(state) when is_binary(state), do: DispatchPolicy.normalize_issue_state(state)
  defp normalize_state(_state), do: nil
end
