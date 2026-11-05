defmodule AgentConversation.Timeline do
  @moduledoc """
  The transcript timeline: history pages, the live tail and their reconciliation.

  A host reads history in pages and pushes live entries; both arrive as
  unordered-ish batches that overlap. The timeline keeps one entry per position
  and per entry id, so a live entry that repeats a paged entry is counted as a
  duplicate instead of appearing twice.

  Reconnects follow the same rule a durable subscription needs: subscribe first,
  catch up, then discard every live entry at or below the head the catch-up page
  reported. `reconcile/2` implements exactly that and reports how many entries it
  discarded, which is what makes duplicate-delivery tests meaningful.
  """

  alias AgentConversation.Entry

  defstruct entries: %{},
            head_pos: 0,
            oldest_pos: nil,
            newest_pos: nil,
            complete_from_start: false,
            sessions: [],
            observed_at: nil,
            duplicates: 0,
            discarded: 0

  @activity_kinds ~w(message reasoning command diff tool_result operator_message system gap)
  @minimap_limit 200

  @type direction :: :tail | :start | :older | :newer | {:around, pos_integer()}
  @type t :: %__MODULE__{
          entries: %{optional(pos_integer()) => map()},
          head_pos: non_neg_integer(),
          oldest_pos: pos_integer() | nil,
          newest_pos: pos_integer() | nil,
          complete_from_start: boolean(),
          sessions: [map()],
          observed_at: DateTime.t() | nil,
          duplicates: non_neg_integer(),
          discarded: non_neg_integer()
        }

  @doc "An empty timeline."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Merges one history page.

  `:older` pages extend the timeline downward, `:newer` and `:tail` upward, and
  `{:around, pos}` fills a window around a jump target. Entries outside a page's
  own bounds are still accepted: the transport is the authority on what a page
  covers and the timeline only ever deduplicates.
  """
  @spec merge(t(), map(), direction()) :: t()
  def merge(%__MODULE__{} = timeline, page, direction \\ :tail) when is_map(page) do
    entries = page |> Map.get(:entries, []) |> List.wrap() |> Enum.map(&Entry.normalize/1)
    head = integer(Map.get(page, :head_pos))
    timeline = %{timeline | head_pos: max(timeline.head_pos, head)}

    timeline =
      timeline
      |> Map.put(:sessions, Map.get(page, :sessions) || timeline.sessions)
      |> Map.put(:observed_at, Map.get(page, :observed_at) || timeline.observed_at)
      |> put_complete(direction, page)

    Enum.reduce(entries, timeline, &insert(&2, &1))
  end

  @doc """
  Appends live entries, dropping anything at or below the last known head.

  The drop is the difference between "the agent said something new" and "the
  server replayed that I already had": a position at or below the head is either
  already in the timeline or was explicitly paged out of it.
  """
  @spec live(t(), [map()]) :: t()
  def live(%__MODULE__{} = timeline, entries) when is_list(entries) do
    Enum.reduce(entries, timeline, fn entry, acc ->
      entry = Entry.normalize(entry)

      cond do
        not is_integer(entry.pos) -> acc
        entry.pos <= acc.head_pos and acc.head_pos > 0 -> %{acc | discarded: acc.discarded + 1}
        true -> insert(acc, entry)
      end
    end)
  end

  @doc """
  Reconciles a reconnect: merges the catch-up page, then applies live entries.

  Returns the timeline and the number of entries discarded because the catch-up
  head already covered them.
  """
  @spec reconcile(t(), map() | [map()], [map()]) :: {t(), non_neg_integer()}
  def reconcile(timeline, page, entries \\ [])

  def reconcile(%__MODULE__{} = timeline, page, entries) when is_map(page),
    do: apply_live(merge(timeline, page, :tail), entries)

  def reconcile(%__MODULE__{} = timeline, entries, _none) when is_list(entries), do: apply_live(timeline, entries)

  defp apply_live(timeline, entries) do
    live = live(timeline, entries)
    {live, live.discarded - timeline.discarded}
  end

  @doc "Every entry, oldest first."
  @spec visible(t()) :: [map()]
  def visible(%__MODULE__{entries: entries}), do: entries |> Map.values() |> Enum.sort_by(& &1.pos)

  @doc "Every loaded position, ascending."
  @spec positions(t()) :: [pos_integer()]
  def positions(%__MODULE__{entries: entries}), do: entries |> Map.keys() |> Enum.sort()

  @doc "The cursor that asks the transport for the next older page, or nil."
  @spec older_cursor(t()) :: pos_integer() | nil
  def older_cursor(%__MODULE__{oldest_pos: nil}), do: nil
  def older_cursor(%__MODULE__{oldest_pos: pos}) when pos <= 1, do: nil
  def older_cursor(%__MODULE__{oldest_pos: pos}), do: pos

  @doc "The cursor that asks the transport for the next newer page, or nil."
  @spec newer_cursor(t()) :: pos_integer() | nil
  def newer_cursor(%__MODULE__{newest_pos: nil, head_pos: head}) when head > 0, do: head
  def newer_cursor(%__MODULE__{newest_pos: newest, head_pos: head}) when newest < head, do: newest
  def newer_cursor(_timeline), do: nil

  @doc "Whether earlier history exists beyond what is loaded."
  @spec older?(t()) :: boolean()
  def older?(%__MODULE__{} = timeline), do: not timeline.complete_from_start and older_cursor(timeline) != nil

  @doc "Whether later entries exist beyond what is loaded."
  @spec newer?(t()) :: boolean()
  def newer?(%__MODULE__{newest_pos: nil, head_pos: head}), do: head > 0
  def newer?(%__MODULE__{newest_pos: newest, head_pos: head}), do: newest < head

  @doc "Whether the conversation has any entry at all."
  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{entries: entries}), do: entries == %{}

  @doc """
  The right-edge minimap rows.

  Activity rows are one tick each, newest last, capped at `:limit` (200 by
  default) so a long transcript never renders an unbounded rail. Supplying
  `:anchors` switches the rail to the host's jump points, which is how the
  dashboard's event anchors reach the embed.
  """
  @spec minimap(t(), keyword()) :: [map()]
  def minimap(%__MODULE__{} = timeline, opts \\ []) do
    limit = Keyword.get(opts, :limit, @minimap_limit)

    case Keyword.get(opts, :anchors) do
      anchors when is_list(anchors) and anchors != [] -> anchors |> Enum.map(&anchor_row/1) |> Enum.take(-limit)
      _none -> timeline |> activity_rows() |> Enum.take(-limit)
    end
  end

  @doc "Rows eligible for the minimap, oldest first."
  @spec activity_rows(t()) :: [map()]
  def activity_rows(%__MODULE__{} = timeline) do
    for entry <- visible(timeline), entry.kind in @activity_kinds do
      %{pos: entry.pos, kind: entry.kind, at: entry.observed_at, label: row_label(entry)}
    end
  end

  defp anchor_row(anchor) do
    %{
      pos: Map.get(anchor, :pos) || Map.get(anchor, "pos"),
      kind: to_string(Map.get(anchor, :kind) || Map.get(anchor, "kind") || "event"),
      at: Map.get(anchor, :at) || Map.get(anchor, "at"),
      label: Map.get(anchor, :label) || Map.get(anchor, "label") || "Event"
    }
  end

  defp row_label(entry) do
    case entry.kind do
      "gap" -> "History gap"
      "system" -> "System"
      kind -> String.capitalize(String.replace(kind, "_", " "))
    end
  end

  defp put_complete(timeline, :start, _page), do: %{timeline | complete_from_start: true}

  defp put_complete(timeline, _direction, page),
    do: %{timeline | complete_from_start: Map.get(page, :complete_from_start, timeline.complete_from_start) == true}

  defp insert(timeline, %{pos: pos} = entry) when is_integer(pos) and pos > 0 do
    if Map.has_key?(timeline.entries, pos) or seen?(timeline, entry) do
      %{timeline | duplicates: timeline.duplicates + 1}
    else
      %{
        timeline
        | entries: Map.put(timeline.entries, pos, entry),
          oldest_pos: min_nil(timeline.oldest_pos, pos),
          newest_pos: max_nil(timeline.newest_pos, pos),
          head_pos: max(timeline.head_pos, pos)
      }
    end
  end

  defp insert(timeline, _entry), do: timeline

  defp seen?(timeline, entry) do
    id = Entry.identity(entry)

    Enum.any?(timeline.entries, fn {_pos, existing} -> Entry.identity(existing) == id end)
  end

  defp min_nil(nil, value), do: value
  defp min_nil(current, value), do: min(current, value)

  defp max_nil(nil, value), do: value
  defp max_nil(current, value), do: max(current, value)

  defp integer(value) when is_integer(value) and value >= 0, do: value
  defp integer(_value), do: 0
end
