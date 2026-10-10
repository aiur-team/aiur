defmodule Aiur.LiveConversation.Notify do
  @moduledoc """
  Topics, opaque handles and coalesced change notifications for
  `Aiur.LiveConversation`.

  `schedule_notification/3` arms a timer on the calling process, so only the
  projection itself may call it.
  """

  alias Aiur.LiveConversation.{SnapshotState, Source}

  @topic "live-conversation:changed"
  @restart_topic "live-conversation:restarted"

  @spec restart_topic() :: String.t()
  def restart_topic, do: @restart_topic

  @spec maybe_schedule_notification(map(), term(), term(), boolean()) :: map()
  def maybe_schedule_notification(state, _key, _source, false), do: state
  def maybe_schedule_notification(state, key, source, true), do: schedule_notification(state, key, source)

  @spec schedule_notification(map(), term(), term()) :: map()
  def schedule_notification(%{pending_notifications: pending} = state, key, source) do
    if Map.has_key?(pending, key) do
      state
    else
      Process.send_after(self(), {:notify, key}, state.notification_delay_ms)
      %{state | pending_notifications: Map.put(pending, key, source)}
    end
  end

  @spec unique_handle(map()) :: String.t()
  def unique_handle(state) do
    candidate = state.handle_fun.()
    candidate = if Source.valid_handle?(candidate), do: candidate, else: random_handle()

    if Map.has_key?(state.handles, candidate), do: unique_handle(state), else: candidate
  end

  @spec random_handle() :: String.t()
  def random_handle do
    "conversation:" <> (:crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false))
  end

  @spec random_epoch() :: String.t()
  def random_epoch do
    "projection:" <> (:crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false))
  end

  @spec source_topic(term()) :: String.t()
  def source_topic(key), do: topic("source", key)

  @spec handle_topic(String.t()) :: String.t()
  def handle_topic(handle), do: @topic <> ":v#{SnapshotState.version()}:handle:" <> handle

  @spec subscribe_with_restarts(String.t()) :: :ok | {:error, term()}
  def subscribe_with_restarts(topic) do
    with :ok <- Phoenix.PubSub.subscribe(Aiur.PubSub, topic) do
      Phoenix.PubSub.subscribe(Aiur.PubSub, @restart_topic)
    end
  end

  defp topic(kind, value) do
    digest =
      :crypto.hash(:sha256, :erlang.term_to_binary(value))
      |> Base.url_encode64(padding: false)

    @topic <> ":v#{SnapshotState.version()}:#{kind}:" <> digest
  end

  @spec broadcast(term(), map()) :: :ok | {:error, term()}
  def broadcast(key, snapshot) do
    :ok =
      Phoenix.PubSub.broadcast(
        Aiur.PubSub,
        source_topic(key),
        {:live_conversation_changed, snapshot}
      )

    case snapshot.generation_handle do
      handle when is_binary(handle) ->
        Phoenix.PubSub.broadcast(
          Aiur.PubSub,
          handle_topic(handle),
          {:live_conversation_changed, snapshot}
        )

      _handle ->
        :ok
    end
  end
end
