defmodule Aiur.Opencode.Slot.State do
  @moduledoc """
  Pure state transitions for a slot. No side effects, no logging, no PubSub, no timers.
  Shell must cancel poll_ref before any transition that sets it nil (giant-slot.md §4 risk 2).
  """

  @poll_death_threshold 3

  defstruct slot_index: nil,
            status: :booting,
            claim_owner: nil,
            claim_ref: nil,
            workspace_path: nil,
            server_pid: nil,
            base_url: nil,
            token: nil,
            generation: 1,
            pane_id: nil,
            attached_identifiers: MapSet.new(),
            visible_identifier: nil,
            visible_session_id: nil,
            # Consecutive empty/unexpected display-message responses
            # from the pane-death poll. tmux returns empty under
            # transient load; one negative reading is not enough to
            # conclude the pane is gone. Concludes death only after
            # @poll_death_threshold consecutive failures.
            poll_death_count: 0,
            # Mirror visible_identifier / visible_session_id for legacy
            # callers still using select/deselect.
            active_identifier: nil,
            active_session_id: nil,
            poll_ref: nil,
            # Identifiers declared in this slot's `opencode.json` models
            # map. opencode-serve does not hot-reload this file; any
            # identifier outside this set fails with `Model not found`.
            # On miss, attach/select triggers a transparent serve
            # rebuild with the freshest active list.
            known_identifiers: MapSet.new(),
            # `{from, identifier}` queued from a `:set_visible` /
            # `:select` whose identifier wasn't in the serve's models
            # map. Drained after `:rebuild_now` reaches `:ready`.
            pending_select: nil,
            # Identifiers queued from `Slot.attach` calls that returned
            # `:identifier_unknown` (the agent became active post-boot
            # and wasn't in the serve's models map). Each triggers a
            # serve rebuild that incorporates them into known_identifiers
            # before retrying the attach. Reply already sent to the
            # caller as `{:error, :identifier_unknown}`; the retry is a
            # background side-effect for fill purposes.
            pending_attaches: MapSet.new()

  @type status :: :booting | :serve_starting | :attach_spawning | :ready | :claimed | :active | :stopping | :failed
  @type t :: %__MODULE__{}

  @doc "Initial state for a newly-started slot."
  @spec new(integer(), String.t()) :: t()
  def new(slot_index, workspace_path),
    do: %__MODULE__{slot_index: slot_index, status: :booting, workspace_path: workspace_path}

  @doc "Lightweight introspection snapshot."
  @spec snapshot(t()) :: map()
  def snapshot(state) do
    %{
      slot_index: state.slot_index,
      status: state.status,
      active_identifier: state.active_identifier,
      active_session_id: state.active_session_id,
      visible_identifier: state.visible_identifier,
      visible_session_id: state.visible_session_id,
      attached_identifiers: state.attached_identifiers,
      pane_id: state.pane_id,
      base_url: state.base_url,
      generation: state.generation
    }
  end

  @doc "Whether `identifier` is in the serve's models map."
  @spec identifier_known?(t(), String.t()) :: boolean()
  def identifier_known?(%{known_identifiers: known}, identifier),
    do: MapSet.member?(known, identifier)

  @doc "Seed identifiers for next serve boot; returns `{:known, ids}` or `:poll_orchestrator`."
  @spec rebuild_seed_identifiers(t()) :: {:known, [String.t()]} | :poll_orchestrator
  def rebuild_seed_identifiers(state) do
    # On rebuild, keep the already-accumulated `state.known_identifiers`
    # so we don't drop previously-attached identifiers in the rebuilt serve.
    cond do
      state.pending_select != nil ->
        {:known, MapSet.to_list(state.known_identifiers)}

      MapSet.size(state.known_identifiers) > 0 ->
        {:known, MapSet.to_list(state.known_identifiers)}

      true ->
        :poll_orchestrator
    end
  end

  @doc "Build the display_opt for materialize_slot (sets top-level model to pending identifier on rebuild)."
  @spec display_opt(t()) :: keyword()
  def display_opt(state) do
    case state.pending_select do
      {_from, identifier} -> [display_identifier: identifier]
      _ -> []
    end
  end

  @doc "Transition to :attach_spawning after serve boot."
  @spec serve_ready(t(), pid(), String.t(), String.t(), [String.t()]) :: t()
  def serve_ready(state, server_pid, base_url, token, agent_ids),
    do: %{state | status: :attach_spawning, server_pid: server_pid, base_url: base_url, token: token, known_identifiers: MapSet.new(agent_ids)}

  @doc "Transition to :ready after attach pane is ready (pane_id may be nil on pending_select fast path)."
  @spec attach_pane_ready(t(), String.t() | nil) :: t()
  def attach_pane_ready(state, pane_id), do: %{state | status: :ready, pane_id: pane_id}

  @doc "Transition to :active after select + respawn succeeds."
  @spec select_applied(t(), String.t(), String.t(), String.t()) :: t()
  def select_applied(state, identifier, session_id, pane_id) do
    %{
      state
      | status: :active,
        active_identifier: identifier,
        active_session_id: session_id,
        visible_identifier: identifier,
        visible_session_id: session_id,
        attached_identifiers: MapSet.put(state.attached_identifiers, identifier),
        pane_id: pane_id
    }
  end

  @doc "Queue an identifier for pending attach after serve rebuild."
  @spec queue_pending_attach(t(), String.t()) :: t()
  def queue_pending_attach(state, identifier),
    do: %{state | known_identifiers: MapSet.put(state.known_identifiers, identifier), pending_attaches: MapSet.put(state.pending_attaches, identifier)}

  @doc "Clear visible fields. Caller MUST cancel poll_ref before calling this."
  @spec clear_visible(t()) :: t()
  def clear_visible(state) do
    %{
      state
      | status: :ready,
        visible_identifier: nil,
        visible_session_id: nil,
        active_identifier: nil,
        active_session_id: nil,
        poll_ref: nil
    }
  end

  @doc "Detach identifier; returns `:not_attached` or `{clears_visible?, new_state}`. Caller cancels poll and broadcasts if clears_visible?."
  @spec detach(t(), String.t()) :: :not_attached | {boolean(), t()}
  def detach(state, identifier) do
    if MapSet.member?(state.attached_identifiers, identifier) do
      new_state = %{
        state
        | attached_identifiers: MapSet.delete(state.attached_identifiers, identifier)
      }

      if state.visible_identifier == identifier do
        cleared = %{
          new_state
          | status: :ready,
            visible_identifier: nil,
            visible_session_id: nil,
            active_identifier: nil,
            active_session_id: nil,
            poll_ref: nil
        }

        {true, cleared}
      else
        {false, new_state}
      end
    else
      :not_attached
    end
  end

  @doc "Clear active/visible fields. Caller MUST cancel poll_ref before calling this."
  @spec deselect(t()) :: t()
  def deselect(state) do
    %{
      state
      | status: :ready,
        active_identifier: nil,
        active_session_id: nil,
        visible_identifier: nil,
        visible_session_id: nil,
        poll_ref: nil
    }
  end

  @doc "Record poll probe; owns the debounce (giant-slot.md §4 risk 2). Returns `{:alive,s}`, `{:retry,n,raw,s}`, or `{:dead,n,raw,s}`."
  @spec record_poll(t(), :alive | {:missing, term()}) ::
          {:alive, t()} | {:retry, non_neg_integer(), term(), t()} | {:dead, non_neg_integer(), term(), t()}
  def record_poll(state, :alive), do: {:alive, %{state | poll_death_count: 0}}

  def record_poll(state, {:missing, raw}) do
    bumped = state.poll_death_count + 1

    if bumped >= @poll_death_threshold do
      {:dead, bumped, raw, state}
    else
      {:retry, bumped, raw, %{state | poll_death_count: bumped}}
    end
  end

  @doc "Reset pane fields after death. Caller calls :spawn_attach continue next."
  @spec pane_died(t()) :: t()
  def pane_died(state) do
    %{
      state
      | status: :attach_spawning,
        pane_id: nil,
        active_identifier: nil,
        active_session_id: nil,
        visible_identifier: nil,
        visible_session_id: nil,
        poll_ref: nil,
        poll_death_count: 0
    }
  end

  @doc "Reset state for a serve rebuild. Caller MUST cancel poll_ref before calling this."
  @spec rebuild_reset(t(), term(), MapSet.t()) :: t()
  def rebuild_reset(state, pending, next_known) do
    %{
      state
      | status: :booting,
        server_pid: nil,
        base_url: nil,
        token: nil,
        pane_id: nil,
        generation: state.generation + 1,
        known_identifiers: next_known,
        pending_select: pending,
        active_identifier: nil,
        active_session_id: nil,
        poll_ref: nil
    }
  end

  @doc "The consecutive-miss threshold used in poll log messages."
  @spec poll_death_threshold() :: non_neg_integer()
  def poll_death_threshold, do: @poll_death_threshold
end
