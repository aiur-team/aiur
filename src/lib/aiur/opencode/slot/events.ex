defmodule Aiur.Opencode.Slot.Events do
  @moduledoc """
  PubSub broadcasts for slot lifecycle events.

  All functions must be called from the slot worker process, because
  `visible_changed/3` calls `SlotRegistry.update_pane_state/3` which
  uses `Registry.update_value/2` — this only succeeds for the registrant.
  """

  alias Aiur.Opencode.SlotRegistry

  @slots_topic "opencode:slots"

  @spec slots_topic() :: String.t()
  def slots_topic, do: @slots_topic

  @spec slot_ready(integer()) :: :ok
  def slot_ready(slot_index) do
    Phoenix.PubSub.broadcast(Aiur.PubSub, @slots_topic, {:slot_ready, slot_index})
    Aiur.Perf.event(:slot_ready, slot: slot_index)
  end

  @spec session_changed(integer(), String.t() | nil) :: :ok
  def session_changed(slot_index, identifier_or_nil) do
    Phoenix.PubSub.broadcast(
      Aiur.PubSub,
      @slots_topic,
      {:slot_session_changed, slot_index, identifier_or_nil}
    )
  end

  @spec attach_added(integer(), String.t()) :: :ok
  def attach_added(slot_index, identifier) do
    Phoenix.PubSub.broadcast(
      Aiur.PubSub,
      @slots_topic,
      {:slot_attach_added, slot_index, identifier}
    )
  end

  @spec attach_removed(integer(), String.t()) :: :ok
  def attach_removed(slot_index, identifier) do
    Phoenix.PubSub.broadcast(
      Aiur.PubSub,
      @slots_topic,
      {:slot_attach_removed, slot_index, identifier}
    )
  end

  @doc """
  Broadcasts the visible-identifier transition AND mirrors
  {visible_identifier, pane_id} into SlotRegistry's ETS so readers
  (PaneManager warm-open hot path) can resolve an identifier to its
  painted pane via a lock-free lookup — no GenServer call against
  this slot or AttachPool.

  Must be called from the slot worker process — `Registry.update_value/2`
  only succeeds for the registrant.
  """
  @spec visible_changed(integer(), String.t() | nil, String.t() | nil) :: :ok
  def visible_changed(slot_index, identifier_or_nil, pane_id_or_nil) do
    SlotRegistry.update_pane_state(slot_index, identifier_or_nil, pane_id_or_nil)

    Phoenix.PubSub.broadcast(
      Aiur.PubSub,
      @slots_topic,
      {:slot_visible_changed, slot_index, identifier_or_nil}
    )
  end
end
