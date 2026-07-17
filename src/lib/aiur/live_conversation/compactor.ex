defmodule Aiur.LiveConversation.Compactor do
  @moduledoc false

  alias Aiur.LiveConversation.Normalizer

  @partial_fragment_limit 128
  @diagnostic_count_limit 1_000

  @spec apply(map(), {:ok, map()} | {:drop, atom()}) :: {map(), boolean()}
  def apply(%{state: :ended} = snapshot, _normalized), do: {snapshot, false}

  def apply(snapshot, {:ok, message}), do: apply_message(snapshot, message)

  def apply(snapshot, {:drop, reason}) do
    {increment_diagnostic(snapshot, reason), true}
  end

  @spec reindex([map()]) :: map()
  def reindex(messages) do
    messages
    |> Enum.with_index()
    |> Map.new(fn
      {%{delivery: :completed, id: id}, _index} -> {id, :completed}
      {%{id: id}, index} -> {id, %{message_index: index}}
    end)
  end

  @spec increment_diagnostic(map(), atom()) :: map()
  def increment_diagnostic(snapshot, reason) do
    count = Map.get(snapshot.diagnostic_counts, reason, 0)

    if count < @diagnostic_count_limit do
      put_in(snapshot.diagnostic_counts[reason], count + 1)
    else
      %{snapshot | truncated?: true}
    end
  end

  defp apply_message(snapshot, %{id: id, delivery: :partial} = message) do
    case seen_status(snapshot, id) do
      :evicted ->
        {snapshot, false}

      :completed ->
        {snapshot, false}

      %{message_index: index} ->
        append_partial(snapshot, message, index)

      nil ->
        {insert_message(snapshot, message), true}
    end
  end

  defp apply_message(snapshot, %{id: id, delivery: :completed} = message) do
    case seen_status(snapshot, id) do
      :evicted ->
        {snapshot, false}

      :completed ->
        {snapshot, false}

      %{message_index: index} ->
        prior = Enum.at(snapshot.messages, index)

        completed = %{
          message
          | occurred_at: prior.occurred_at,
            order: prior.order,
            fragments: %{},
            fragment: nil
        }

        messages = List.replace_at(snapshot.messages, index, completed)

        snapshot = %{
          live_snapshot(snapshot, message.observed_at)
          | messages: messages,
            seen: Map.put(snapshot.seen, id, :completed),
            truncated?: snapshot.truncated? or message.truncated?
        }

        {snapshot, true}

      nil ->
        {insert_message(snapshot, message), true}
    end
  end

  defp append_partial(snapshot, %{fragment: %{id: fragment_id}} = message, index) do
    prior = Enum.at(snapshot.messages, index)

    cond do
      Map.has_key?(prior.fragments, fragment_id) ->
        {snapshot, false}

      map_size(prior.fragments) >= @partial_fragment_limit ->
        snapshot =
          snapshot
          |> live_snapshot(message.observed_at)
          |> increment_diagnostic(:partial_fragment_limit)
          |> Map.put(:truncated?, true)

        {snapshot, true}

      true ->
        append_bounded_partial(snapshot, prior, message, index)
    end
  end

  defp append_bounded_partial(snapshot, prior, message, index) do
    fragments = Map.put(prior.fragments, message.fragment.id, message.fragment)
    {body, compacted_truncated?} = Normalizer.compact_fragments(fragments)

    messages =
      List.update_at(snapshot.messages, index, fn current ->
        %{
          current
          | body: body,
            observed_at: message.observed_at,
            fragments: fragments,
            truncated?: current.truncated? or message.truncated? or compacted_truncated?
        }
      end)

    snapshot = %{
      live_snapshot(snapshot, message.observed_at)
      | messages: messages,
        truncated?: snapshot.truncated? or message.truncated? or compacted_truncated?
    }

    {snapshot, true}
  end

  defp insert_message(snapshot, message) do
    messages = Enum.sort_by(snapshot.messages ++ [message], & &1.order)

    %{
      live_snapshot(snapshot, message.observed_at)
      | messages: messages,
        seen: reindex(messages),
        truncated?: snapshot.truncated? or message.truncated?
    }
  end

  defp live_snapshot(snapshot, observed_at) do
    if snapshot.state == :restart_unknown do
      %{snapshot | observed_at: observed_at}
    else
      %{
        snapshot
        | state: :live,
          health: :healthy,
          freshness: :current,
          observed_at: observed_at
      }
    end
  end

  defp seen_status(snapshot, id) do
    if Map.has_key?(snapshot.replay_tombstones, id) do
      :evicted
    else
      Map.get(snapshot.seen, id)
    end
  end
end
