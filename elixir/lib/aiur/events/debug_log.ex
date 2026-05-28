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

  The renderer maps these to ✉️ / 📥 / 📄 respectively.
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

  @spec subscribe() :: :ok
  def subscribe, do: Phoenix.PubSub.subscribe(Aiur.PubSub, @topic)

  @spec unsubscribe() :: :ok
  def unsubscribe, do: Phoenix.PubSub.unsubscribe(Aiur.PubSub, @topic)

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

    Phoenix.PubSub.local_broadcast(Aiur.PubSub, @topic, {:event_debug, entry})
    :ok
  rescue
    # PubSub may not be running in cold-boot or test-shutdown windows.
    _ -> :ok
  end
end
