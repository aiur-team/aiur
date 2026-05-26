defmodule Aiur.Opencode.EventRow do
  @moduledoc """
  Shared formatter for the cross-ticket event ticker rows that show up
  in agent chat panes (R2 of the chat-pane follow-ups plan). Used by
  both `Aiur.Opencode.SessionWriter` (persists to SQL for re-attach
  scrollback) and `Aiur.Opencode.ChatCompletions` (chunks live deltas
  during the per-turn marker bridge SSE).

  Source: `Aiur.Events.DebugLog` entries — one per lifecycle mark on
  every event flowing through Aiur. Three kinds:

    * `:publish` → `📤 <topic> · id=<id>` (this agent emitted an event)
    * `:receive` → `📥 <topic> · from #<source_ticket> · id=<id>`
      (this agent's inbox received an event from another ticket)
    * `:read` → `📄 <topic> · ingested · id=<id>` (this agent's
      `events_digest` was folded into a turn prompt)

  Rows are wrapped in `Aiur.Opencode.Style.dim/1` so they read as
  context, not as agent prose.
  """

  alias Aiur.Opencode.Style

  @doc """
  Does this `DebugLog` entry belong to `identifier`'s chat pane?

  - If the entry carries an explicit `identifier` (the case for
    `:receive` from SubscriptionStore and `:read` from agent_runner),
    match on it directly.
  - If the entry has no identifier (the case for `:publish` from
    `Aiur.Events.Publisher`, which only knows the topic), match by
    parsing the topic prefix: `ticket.<id>.<surface>.<verb>` belongs
    to ticket `<id>`.

  Returns `false` for entries that don't belong to this identifier.
  """
  @spec matches?(map(), String.t()) :: boolean()
  def matches?(%{identifier: ident}, identifier)
      when not is_nil(ident) and is_binary(identifier),
      do: ident == identifier

  def matches?(%{topic: topic}, identifier)
      when is_binary(topic) and is_binary(identifier) do
    String.starts_with?(topic, "ticket.#{identifier}.")
  end

  def matches?(_entry, _identifier), do: false

  @doc """
  Format a `DebugLog` entry as a chat-pane ticker row, dimmed.

  Returns the rendered string ready for chunking via SSE or for
  writing as a `text` part body. Returns `nil` if the entry shape is
  unexpected.
  """
  @spec from(map()) :: String.t() | nil
  def from(%{kind: kind, topic: topic} = entry)
      when kind in [:publish, :receive, :read] and is_binary(topic) do
    id = Map.get(entry, :id)
    body = render(kind, topic, id)
    Style.dim(body)
  end

  def from(_), do: nil

  defp render(:publish, topic, id), do: "📤 #{topic}" <> id_suffix(id)
  defp render(:receive, topic, id), do: "📥 #{topic}" <> source_suffix(topic) <> id_suffix(id)
  defp render(:read, topic, id), do: "📄 #{topic} · ingested" <> id_suffix(id)

  # Pull the source ticket id out of the topic name (events use the
  # convention `ticket.<id>.<surface>.<verb>` per the events
  # foundation brainstorm). Falls back to `?` if the prefix isn't there.
  defp source_suffix(topic) do
    case String.split(topic, ".", parts: 3) do
      ["ticket", src, _rest] -> " · from ##{src}"
      _ -> " · from #?"
    end
  end

  defp id_suffix(nil), do: " · id=?"
  defp id_suffix(id), do: " · id=#{id}"
end
