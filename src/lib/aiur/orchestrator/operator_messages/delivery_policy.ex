defmodule Aiur.Orchestrator.OperatorMessages.DeliveryPolicy do
  @moduledoc """
  Normalizes message delivery requests and decides when queued work wakes a running agent.
  """

  alias Aiur.Opencode.ActiveTurns
  alias Aiur.Orchestrator.{CommentWake, EventTopics, State}

  @spec normalize_delivery_request(term(), term(), map()) ::
          {:ok, keyword()} | {:error, atom()}
  # `:auto` lets the caller defer to the backend: the persistent REPL takes
  # Executor messages immediately mid-turn; everything else holds at a safe
  # checkpoint (native codex/headless-claude turn UX).
  def normalize_delivery_request(:auto, _fallback, %{immediate_delivery: true}) do
    {:ok, [delivery_policy: :immediate]}
  end

  def normalize_delivery_request(:auto, _fallback, _capabilities) do
    {:ok, [delivery_policy: :checkpoint]}
  end

  def normalize_delivery_request(:immediate, _fallback, %{immediate_delivery: true}) do
    {:ok, [delivery_policy: :immediate]}
  end

  def normalize_delivery_request(:immediate, _fallback, _capabilities) do
    {:error, :immediate_not_supported}
  end

  def normalize_delivery_request(:checkpoint, _fallback, _capabilities) do
    {:ok, [delivery_policy: :checkpoint]}
  end

  def normalize_delivery_request(:interrupt, fallback, %{can_interrupt: true}) do
    {:ok, [delivery_policy: :interrupt, fallback: fallback]}
  end

  def normalize_delivery_request(:interrupt, :queue_next, _capabilities) do
    {:ok, [delivery_policy: :checkpoint, fallback: :queue_next]}
  end

  def normalize_delivery_request(:interrupt, _fallback, _capabilities) do
    {:error, :interrupt_not_supported}
  end

  def normalize_delivery_request(_other, _fallback, _capabilities) do
    {:error, :invalid_message}
  end

  @spec notify_running_queue_update(map(), term()) :: :ok
  def notify_running_queue_update(%{pid: pid} = running_entry, item) when is_pid(pid) do
    if Process.alive?(pid) do
      send(
        pid,
        {:agent_queue_updated, item.target_issue_identifier, item.id, deliver_now?(running_entry, item)}
      )
    end

    :ok
  end

  def notify_running_queue_update(_running_entry, _item), do: :ok

  @spec event_digest_delivery_opts(map() | nil, term()) :: keyword()
  def event_digest_delivery_opts(running_entry, event_or_events) do
    if queue_wake_required?(running_entry) or
         trusted_comment_wake_required?(running_entry, event_or_events) do
      [source: :system, priority: :now, interrupt_requested: true]
    else
      [source: :system]
    end
  end

  @doc false
  @spec comment_event_topic?(map()) :: boolean()
  def comment_event_topic?(event) when is_map(event) do
    topic = Map.get(event, :topic) || Map.get(event, "topic")

    if is_binary(topic) do
      case EventTopics.classify_event_topic(topic) do
        {:pr_review_comment, _identifier} -> true
        {:issue_commented, _identifier} -> true
        _ -> false
      end
    else
      false
    end
  end

  def comment_event_topic?(_event), do: false

  defp deliver_now?(running_entry, item) do
    queue_wake_required?(running_entry) or
      item.delivery[:interrupt_requested] == true or
      item.delivery[:immediate] == true
  end

  defp trusted_comment_wake_required?(running_entry, event_or_events),
    do:
      State.active_running_entry?(running_entry) and
        trusted_comment_event_digest?(event_or_events)

  defp trusted_comment_event_digest?(events) when is_list(events),
    do: Enum.any?(events, &trusted_comment_event_digest?/1)

  defp trusted_comment_event_digest?(event) when is_map(event) do
    comment_event_topic?(event) and CommentWake.actionable_trusted_comment_event?(event)
  end

  defp trusted_comment_event_digest?(_event), do: false

  defp queue_wake_required?(running_entry) do
    State.sleeping_running_entry?(running_entry) or
      (State.active_running_entry?(running_entry) and no_active_turn?(running_entry))
  end

  defp no_active_turn?(%{identifier: identifier}) when is_binary(identifier),
    do: ActiveTurns.active_turn_ids(identifier) == []

  defp no_active_turn?(_running_entry), do: false
end
