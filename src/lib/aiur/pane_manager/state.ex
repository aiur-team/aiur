defmodule Aiur.PaneManager.State do
  @moduledoc """
  Pure PaneManager state shape and bookkeeping transforms.
  """

  @type agent_id :: Aiur.AgentEvents.agent_identifier()
  @type pane_id :: String.t()

  defstruct identifier_to_pane: %{},
            pane_to_identifier: %{},
            pane_to_slot: %{},
            slot_panes: %{},
            cycle_index: 0,
            max_vertical_panes: 3,
            slot_count: 5,
            agent_list_pane: nil,
            window_target: nil,
            orientation: :horizontal,
            tmux: nil,
            # FIFO queue of pending opens waiting on a `:slot_ready`
            # broadcast. Each entry is `{identifier, from, timer_ref}`.
            # The queue drains 1 entry per `:slot_ready` event in v1 —
            # multi-drain optimization deferred until measured need.
            open_queue: :queue.new(),
            # identifier => timer_ref, so a duplicate-open request can
            # detect the existing queued entry and refuse it without
            # walking the queue.
            open_queue_timers: %{},
            # Tracks the most-recently-opened or -attached chat pane.
            # Drives the `a` "attach to focused pane" keybind in
            # `AgentList` (U6). Reset to nil when the corresponding
            # slot signals `:slot_session_changed` with a nil identifier.
            last_attached_pane_id: nil,
            # identifier => %{pane_id: pane_id, slot: slot_index}
            # Loading placeholders are real visible tmux panes before
            # a Slot worker has produced the final opencode-attach pane.
            # They are included in layout occupancy but not reported as
            # open chat panes.
            placeholder_panes: %{},
            # identifier => issue title string, captured from the `:title`
            # open/attach option. Used to build the "<id> <title>" tmux pane
            # title set on every bind so the pane border names its agent.
            title_by_identifier: %{}

  @type t :: %__MODULE__{}

  @spec record_slot_pane(t(), pos_integer(), pane_id(), agent_id()) :: t()
  def record_slot_pane(%__MODULE__{} = state, slot, pane_id, identifier) do
    %{
      state
      | identifier_to_pane: Map.put(state.identifier_to_pane, identifier, pane_id),
        pane_to_identifier: Map.put(state.pane_to_identifier, pane_id, identifier),
        pane_to_slot: Map.put(state.pane_to_slot, pane_id, slot),
        slot_panes: Map.put(state.slot_panes, slot, pane_id)
    }
  end

  @spec record_placeholder(t(), agent_id(), pane_id(), pos_integer()) :: t()
  def record_placeholder(state, identifier, placeholder_pane_id, slot) do
    placeholders = Map.get(state, :placeholder_panes, %{})

    Map.put(
      state,
      :placeholder_panes,
      Map.put(placeholders, identifier, %{pane_id: placeholder_pane_id, slot: slot})
    )
  end

  @spec drop_placeholder(t(), agent_id()) :: t()
  def drop_placeholder(state, identifier) do
    placeholders = Map.get(state, :placeholder_panes, %{})
    Map.put(state, :placeholder_panes, Map.delete(placeholders, identifier))
  end

  @spec drop_placeholder_by_pane(t(), pane_id()) :: t()
  def drop_placeholder_by_pane(state, pane_id) do
    case Enum.find(state.placeholder_panes, fn {_identifier, placeholder} ->
           placeholder.pane_id == pane_id
         end) do
      {identifier, _placeholder} -> drop_placeholder(state, identifier)
      nil -> state
    end
  end

  # Capture the issue title from the open/attach `:title` option so a later
  # bind can render "<id> <title>" in the pane border. AgentList already
  # resolves the title in-memory and passes it through; absent/blank titles
  # leave the cache untouched and the pane shows the bare identifier.
  @spec remember_title(t(), agent_id(), keyword()) :: t()
  def remember_title(%__MODULE__{} = state, identifier, opts) do
    case Keyword.get(opts, :title) do
      title when is_binary(title) and title != "" ->
        %{state | title_by_identifier: Map.put(state.title_by_identifier, identifier, title)}

      _ ->
        state
    end
  end

  @spec pane_title_text(t(), agent_id()) :: String.t()
  def pane_title_text(%__MODULE__{} = state, identifier) do
    case Map.get(state.title_by_identifier, identifier) do
      title when is_binary(title) and title != "" -> "#{identifier} #{scrub_title(title)}"
      _ -> identifier
    end
  end

  # The pane border is a single line, so a raw newline or control character in
  # an issue title would garble it (no injection risk — the title is one argv
  # element and tmux does not re-evaluate format sequences inside a pane title).
  # Collapse any control char (incl. CR/LF/tab) to a space so the title stays
  # on one line; tmux's `pane-border-format` handles width truncation.
  defp scrub_title(title) do
    String.replace(title, ~r/[\x00-\x1f\x7f]/, " ")
  end

  @spec forget_identifier_for_pane(t(), pane_id()) :: t()
  def forget_identifier_for_pane(%__MODULE__{} = state, pane_id) do
    case Map.get(state.pane_to_identifier, pane_id) do
      nil ->
        state

      old_identifier ->
        %{
          state
          | identifier_to_pane: Map.delete(state.identifier_to_pane, old_identifier),
            title_by_identifier: Map.delete(state.title_by_identifier, old_identifier)
        }
    end
  end

  @spec forget_pane_by_identifier(t(), pane_id()) :: t()
  def forget_pane_by_identifier(%__MODULE__{} = state, pane_id) do
    identifier = Map.get(state.pane_to_identifier, pane_id)
    slot = Map.get(state.pane_to_slot, pane_id)

    new_state = %{
      state
      | pane_to_identifier: Map.delete(state.pane_to_identifier, pane_id),
        pane_to_slot: Map.delete(state.pane_to_slot, pane_id)
    }

    new_state =
      if identifier do
        %{
          new_state
          | identifier_to_pane: Map.delete(new_state.identifier_to_pane, identifier),
            title_by_identifier: Map.delete(new_state.title_by_identifier, identifier)
        }
      else
        new_state
      end

    if slot do
      %{new_state | slot_panes: Map.put(new_state.slot_panes, slot, nil)}
    else
      new_state
    end
  end

  @spec forget_dead_slot(t(), pos_integer()) :: t()
  def forget_dead_slot(%__MODULE__{} = state, slot) do
    case Map.get(state.slot_panes, slot) do
      nil -> state
      pane_id -> forget_pane_by_identifier(state, pane_id)
    end
  end

  @spec advance_cycle(t()) :: t()
  def advance_cycle(%__MODULE__{} = state) do
    %{state | cycle_index: rem(state.cycle_index + 1, state.slot_count)}
  end

  # Raw slot-indexed view: position i = whatever pane (placeholder OR
  # real) is currently assigned to slot index i+1, or nil if free.
  # Used by `first_available_visual_slot` and other state-introspection
  # code that needs to know "which slot index is free for a new
  # placeholder". DO NOT use this for layout — see `visible_panes_packed`.
  @spec slot_panes_list(t()) :: [pane_id() | nil]
  def slot_panes_list(%__MODULE__{} = state) do
    placeholder_slots =
      state.placeholder_panes
      |> Map.values()
      |> Map.new(fn %{pane_id: pane_id, slot: slot} -> {slot, pane_id} end)

    for slot <- 1..state.slot_count do
      Map.get(placeholder_slots, slot) || Map.get(state.slot_panes, slot)
    end
  end

  # Layout-ready view: visible chat panes packed left-to-right,
  # padded to slot_count with nils. Slot indexes are an internal
  # pre-warm detail; the grid should fill from the primary row first.
  # Without packing, a single visible pane that happens to be slot 4
  # renders alone in the secondary row while the agent list sits
  # alone in the primary row — which is the "chat opens under the
  # agent list" report from the user.
  @spec visible_panes_packed(t()) :: [pane_id() | nil]
  def visible_panes_packed(%__MODULE__{} = state) do
    raw = slot_panes_list(state)
    visible = Enum.reject(raw, &is_nil/1)
    padding = List.duplicate(nil, state.slot_count - length(visible))
    visible ++ padding
  end

  @spec first_available_visual_slot(t()) :: pos_integer() | nil
  def first_available_visual_slot(%__MODULE__{} = state) do
    state
    |> slot_panes_list()
    |> Enum.find_index(&is_nil/1)
    |> case do
      nil -> nil
      index -> index + 1
    end
  end

  @spec slot_count(pos_integer()) :: pos_integer()
  def slot_count(max_vertical_panes), do: max_vertical_panes * 2 - 1

  @spec empty_slot_panes(pos_integer()) :: %{optional(pos_integer()) => nil}
  def empty_slot_panes(slot_count) do
    Map.new(1..slot_count, fn slot -> {slot, nil} end)
  end
end
