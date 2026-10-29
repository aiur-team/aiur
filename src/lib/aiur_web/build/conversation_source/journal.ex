defmodule AiurWeb.Build.ConversationSource.Journal do
  @moduledoc "Bounded, device-masked journal pages, with workspace reads only for tickets without a journal."
  @behaviour AiurWeb.Build.ConversationSource

  alias Aiur.Conversation.{History, Ref}
  alias AiurWeb.Build.ConversationSource.{JournalEntries, Wave0b}
  alias AiurWeb.Conversation.Presenter

  @principal {:device, "streamdeck"}
  @limit 200

  @impl true
  def prepare(ref, opts) do
    with {:ok, prepared} <- Wave0b.prepare(ref, opts) do
      case resolve(prepared) do
        {:ok, id} -> {:ok, Map.put(prepared, :journal_id, id)}
        {:error, :not_found} -> {:ok, Map.delete(prepared, :journal_id)}
        {:error, _} -> {:error, :unavailable}
      end
    end
  end

  defp resolve(ref) do
    identity = ref[:identity] || (ref[:running] || %{})[:tracker_identity]

    case Ref.worker(identity) do
      {:ok, worker} -> existing(Ref.conversation_id(worker))
      _ -> resolve_locator(ref, identity)
    end
  end

  defp resolve_locator(ref, identity) do
    repo = if is_map(identity), do: {identity[:owner] || identity["owner"], identity[:repository] || identity["repository"]}

    case repo || configured_repository() do
      {owner, repository} when is_binary(owner) and is_binary(repository) -> History.resolve_worker(owner, repository, ref.id)
      _ -> {:error, :not_found}
    end
  end

  defp configured_repository do
    case Aiur.Tracker.workspace_repo_segment() do
      repo when is_binary(repo) ->
        case String.split(repo, "/") do
          [owner, repository] -> {owner, repository}
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp existing(id) do
    with {:ok, _} <- History.snapshot(id), do: {:ok, id}
  end

  @impl true
  def tail(ref, cursor, opts), do: read(ref, cursor, :tail, opts)

  @impl true
  def page(ref, cursor, opts), do: read(ref, cursor, :page, opts)

  defp read(ref, cursor, direction, opts) do
    with {:ok, ref} <- prepared(ref, opts) do
      if ref[:journal_id] do
        journal_page(ref, cursor, direction)
      else
        if is_binary(cursor) and String.starts_with?(cursor, "journal:"), do: {:error, :reset}, else: apply(Wave0b, direction, [ref, cursor, opts])
      end
    end
  end

  defp prepared(%{prepared?: true} = ref, _opts), do: {:ok, ref}
  defp prepared(ref, opts), do: prepare(ref, opts)

  defp journal_page(ref, cursor, direction) do
    with {:ok, selection} <- selection(ref.journal_id, cursor, direction),
         {:ok, page} <- History.list_entries(ref.journal_id, selection ++ [limit: @limit, principal: @principal]),
         :ok <- catch_up_bound(page, selection),
         {:ok, sessions} <- History.list_sessions(ref.journal_id) do
      {state, reason} = state(ref, page, sessions)
      last = if direction == :tail, do: page.next_cursor || page.head_pos, else: page.head_pos

      {:ok,
       %{
         state: state,
         reason: reason,
         entries: JournalEntries.map_entries(page.entries, ref.journal_id),
         before: cursor(ref.journal_id, page.prev_cursor),
         last: cursor(ref.journal_id, last),
         more?: if(direction == :tail and not is_nil(selection[:after]), do: page.next_cursor != nil, else: page.prev_cursor != nil),
         live?: ref[:running] != nil and state in [:live, :known_empty],
         observed_at: page.observed_at,
         note: nil,
         evicted: 0
       }}
    end
  end

  defp selection(_id, nil, :tail), do: {:ok, [tail: true]}

  defp selection(id, value, direction) when is_binary(value) do
    prefix = "journal:#{id}:"

    with true <- String.starts_with?(value, prefix),
         {pos, ""} when pos >= 0 <- value |> String.replace_prefix(prefix, "") |> Integer.parse(),
         true <- direction == :tail or pos > 0 do
      {:ok, [{if(direction == :tail, do: :after, else: :before), pos}]}
    else
      _ -> {:error, :reset}
    end
  end

  defp selection(_, _, _), do: {:error, :invalid_cursor}

  # Reset to a bounded tail instead of silently skipping a large unseen suffix.
  defp catch_up_bound(page, after: pos) when page.head_pos - pos > 5_000 or pos > page.head_pos, do: {:error, :reset}
  defp catch_up_bound(_page, _selection), do: :ok

  defp cursor(_id, nil), do: nil
  defp cursor(id, pos), do: "journal:#{id}:#{pos}"

  defp state(ref, page, sessions) do
    latest = History.list_entries(ref.journal_id, tail: true, limit: 1, principal: @principal)

    last_entry =
      case latest do
        {:ok, tail} -> List.last(tail.entries)
        _ -> nil
      end

    case Presenter.state(page, sessions: sessions, last_entry: last_entry, degraded: History.degraded?(ref.journal_id)) do
      :idle -> {:stale, nil}
      :unknown -> {:unavailable, :unknown}
      :degraded -> {:unavailable, :journal_unavailable}
      state -> {state, nil}
    end
  end

  @impl true
  defdelegate subscribe(ref, opts), to: Wave0b
  @impl true
  defdelegate unsubscribe(ref, opts), to: Wave0b
  @impl true
  defdelegate events(ref, opts), to: Wave0b
  @impl true
  defdelegate events_subscribe(identity, opts), to: Wave0b
  @impl true
  defdelegate events_unsubscribe(topic, opts), to: Wave0b
end
