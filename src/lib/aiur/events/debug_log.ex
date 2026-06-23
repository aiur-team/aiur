defmodule Aiur.Events.DebugLog do
  @moduledoc """
  Phoenix.PubSub topic + entry shape for the debug-only event-flow
  ticker rendered at the bottom of the agent-list pane when `--debug`
  is on.

  Broadcasts are best-effort and unconditional from the producer side
  — the AgentList only subscribes when `debug_mode?` is true, so the
  broadcasts are no-ops in normal operation (cost is one PubSub
  `local_broadcast/3` per event, which is cheap).

  Three lifecycle marks:

    * `:publish` — `Aiur.Events.Publisher.publish/3` accepted an event
    * `:receive` — `Aiur.Events.SubscriptionStore.handle_info({:event, _})`
      enqueued an event for a specific subscribing identifier
    * `:read`    — the agent's queue consumed an `events_digest` item
      (the digest reached the agent's prompt)

  The renderer maps these to 💬 / 📬 / 📄 respectively.
  """

  @topic "aiur:events:debug"

  @type kind :: :publish | :receive | :read

  @type entry :: %{
          required(:kind) => kind(),
          required(:topic) => String.t(),
          required(:id) => non_neg_integer() | nil,
          required(:identifier) => String.t() | nil,
          required(:body) => map() | nil,
          required(:at) => integer()
        }

  @spec topic() :: String.t()
  def topic, do: @topic

  @doc """
  Per-identifier sub-topic. A subscriber on this topic receives only
  the marks that belong to `identifier` (its own `:publish` events plus
  the `:receive`/`:read` events addressed to it) — see `route_identifier/1`.
  """
  @spec identifier_topic(String.t()) :: String.t()
  def identifier_topic(identifier) when is_binary(identifier),
    do: @topic <> ":" <> identifier

  @spec subscribe() :: :ok
  def subscribe, do: Phoenix.PubSub.subscribe(Aiur.PubSub, @topic)

  @doc """
  Subscribe to a single agent's marks instead of the global firehose.
  Used by `Aiur.Opencode.SessionWriter` so each writer receives only
  its own marks — at high concurrency the global topic fanned every
  mark to all M×N writers, which all but one then discarded.
  """
  @spec subscribe(String.t()) :: :ok
  def subscribe(identifier) when is_binary(identifier),
    do: Phoenix.PubSub.subscribe(Aiur.PubSub, identifier_topic(identifier))

  @spec unsubscribe() :: :ok
  def unsubscribe, do: Phoenix.PubSub.unsubscribe(Aiur.PubSub, @topic)

  @spec unsubscribe(String.t()) :: :ok
  def unsubscribe(identifier) when is_binary(identifier),
    do: Phoenix.PubSub.unsubscribe(Aiur.PubSub, identifier_topic(identifier))

  @spec broadcast(kind(), String.t(), keyword()) :: :ok
  def broadcast(kind, topic, opts \\ [])
      when kind in [:publish, :receive, :read] and is_binary(topic) do
    entry = %{
      kind: kind,
      topic: topic,
      id: Keyword.get(opts, :id),
      identifier: Keyword.get(opts, :identifier),
      body: Keyword.get(opts, :body),
      at: System.monotonic_time(:millisecond)
    }

    # Global topic: the AgentList debug ticker and the ChatCompletions
    # live bridge consume the full firehose here.
    Phoenix.PubSub.local_broadcast(Aiur.PubSub, @topic, {:event_debug, entry})

    # Per-identifier topic: route the mark to the single agent it
    # belongs to so per-agent subscribers (SessionWriter) skip the
    # discard-it-255-times fan-out. The routing key mirrors
    # `Aiur.Opencode.EventRow.matches?/2` exactly.
    case route_identifier(entry) do
      nil ->
        :ok

      identifier ->
        Phoenix.PubSub.local_broadcast(
          Aiur.PubSub,
          identifier_topic(identifier),
          {:event_debug, entry}
        )
    end

    :ok
  rescue
    # PubSub may not be running in cold-boot or test-shutdown windows.
    _ -> :ok
  end

  # The identifier a mark belongs to: the explicit `identifier` field
  # (set for `:receive`/`:read`), falling back to the `ticket.<id>.`
  # prefix in the topic (the `:publish` path, which carries no explicit
  # identifier). Mirrors `Aiur.Opencode.EventRow.matches?/2`.
  defp route_identifier(%{identifier: identifier}) when is_binary(identifier),
    do: identifier

  defp route_identifier(%{topic: "ticket." <> rest}) do
    case String.split(rest, ".", parts: 2) do
      [id, _suffix] when id != "" -> id
      _ -> nil
    end
  end

  defp route_identifier(_entry), do: nil
end
