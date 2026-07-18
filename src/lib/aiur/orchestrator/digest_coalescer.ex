defmodule Aiur.Orchestrator.DigestCoalescer do
  @moduledoc """
  Coalesces queued event-digest items at drain time.
  All functions execute inside the orchestrator GenServer process.
  """

  alias Aiur.{AgentQueueItem, AgentQueueStore}
  alias Aiur.Orchestrator.{CommentWake, OperatorMessages}

  @spec coalesce_events_digests(AgentQueueStore.t(), String.t(), AgentQueueItem.t()) ::
          {AgentQueueStore.t(), AgentQueueItem.t()}
  # Drain-time coalescing: pending `:events_digest` items for the same
  # identifier fold into a single delivery, so an agent that had three
  # events subscribed during a long turn sees ONE `<aiur:events>` block,
  # not three separate ones. Granularity is preserved upstream (one
  # queue item per publish so `[event:consumed]` markers and cursor
  # advance still reflect individual events); coalescing happens only
  # at the drain boundary.
  def coalesce_events_digests(queue_store, issue_identifier, first_item) do
    do_coalesce_events_digests(queue_store, issue_identifier, first_item)
  end

  defp do_coalesce_events_digests(queue_store, issue_identifier, acc_item) do
    {next_store, next_item} =
      AgentQueueStore.claim_next_deliverable_matching(
        queue_store,
        issue_identifier,
        fn item -> match?(%{category: :coordination_event, event_type: :events_digest}, item) end
      )

    case next_item do
      nil ->
        {next_store, acc_item}

      %{} = item ->
        merged = merge_events_digest_items(acc_item, item)
        do_coalesce_events_digests(next_store, issue_identifier, merged)
    end
  end

  defp merge_events_digest_items(first, next) do
    first_events = first.body |> Map.get(:events, []) |> List.wrap()
    next_events = next.body |> Map.get(:events, []) |> List.wrap()

    sorted =
      (first_events ++ next_events)
      |> Enum.uniq_by(&event_dedupe_key/1)
      |> Enum.sort_by(&event_sort_key/1)

    new_body =
      first.body
      |> Map.put(:events, sorted)
      |> Map.put(:summary, CommentWake.event_digest_summary(%{events: sorted}))

    delivery =
      first.delivery
      |> Map.put(:coalesced_item_ids, coalesced_item_ids(first, next))

    %{first | body: new_body, delivery: delivery}
  end

  defp coalesced_item_ids(first, next) do
    (delivery_item_ids(first) ++ delivery_item_ids(next))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp delivery_item_ids(%{id: id, delivery: delivery}) do
    Map.get(delivery, :coalesced_item_ids, [id])
  end

  defp event_sort_key(%{id: id}) when is_integer(id), do: id
  defp event_sort_key(%{"id" => id}) when is_integer(id), do: id
  defp event_sort_key(_), do: 0

  defp event_dedupe_key(event) when is_map(event) do
    topic = event_topic(event)

    case {OperatorMessages.comment_event_topic?(event), event_comment_id(event), event_sort_key(event)} do
      {true, id, _} when is_integer(id) -> {topic, :comment, id}
      {_, _, id} when is_integer(id) and id > 0 -> {topic, :event, id}
      _ -> event
    end
  end

  defp event_dedupe_key(event), do: event

  defp event_topic(event) when is_map(event),
    do: Map.get(event, :topic) || Map.get(event, "topic")

  defp event_comment_id(event) when is_map(event) do
    comment = Map.get(event, :comment) || Map.get(event, "comment") || %{}
    Map.get(comment, :id) || Map.get(comment, "id")
  end
end
