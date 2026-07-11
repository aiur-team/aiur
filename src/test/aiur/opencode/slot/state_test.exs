defmodule Aiur.Opencode.Slot.StateTest do
  use ExUnit.Case, async: true

  alias Aiur.Opencode.Slot.State

  defp base_state(overrides) do
    Map.merge(
      %State{
        slot_index: 5,
        status: :active,
        generation: 1,
        known_identifiers: MapSet.new(),
        attached_identifiers: MapSet.new(),
        pending_attaches: MapSet.new()
      },
      overrides
    )
  end

  # --- record_poll/2 debounce ---

  test "new builds a booting state for the slot workspace" do
    state = State.new(8, "/tmp/slot-8")
    assert state.slot_index == 8
    assert state.workspace_path == "/tmp/slot-8"
    assert state.status == :booting
  end

  test "record_poll alive resets death count" do
    state = base_state(%{poll_death_count: 2})
    assert {:alive, new_state} = State.record_poll(state, :alive)
    assert new_state.poll_death_count == 0
  end

  test "record_poll missing increments to retry on first miss" do
    state = base_state(%{poll_death_count: 0})
    assert {:retry, 1, _raw, new_state} = State.record_poll(state, {:missing, :some_raw})
    assert new_state.poll_death_count == 1
  end

  test "record_poll missing reaches dead at threshold" do
    state = base_state(%{poll_death_count: 2})
    assert {:dead, 3, _raw, dead_state} = State.record_poll(state, {:missing, :whatever})
    # count NOT persisted in returned state for :dead
    assert dead_state.poll_death_count == 2
  end

  test "record_poll alive after 2 misses resets count" do
    state = base_state(%{poll_death_count: 2})
    assert {:alive, new_state} = State.record_poll(state, :alive)
    assert new_state.poll_death_count == 0
  end

  test "pane_died clears pane, active, and poll fields before respawn" do
    state =
      base_state(%{
        pane_id: "%8",
        active_identifier: "issue-8",
        active_session_id: "session-8",
        visible_identifier: "issue-8",
        visible_session_id: "session-8",
        poll_ref: make_ref(),
        poll_death_count: 3
      })

    new_state = State.pane_died(state)
    assert new_state.status == :attach_spawning
    assert is_nil(new_state.pane_id)
    assert is_nil(new_state.active_identifier)
    assert is_nil(new_state.visible_identifier)
    assert is_nil(new_state.poll_ref)
    assert new_state.poll_death_count == 0
  end

  # --- rebuild_reset/3 ---

  test "rebuild_reset bumps generation and clears fields" do
    state =
      base_state(%{
        generation: 3,
        server_pid: self(),
        base_url: "http://x",
        token: "t",
        pane_id: "p1",
        active_identifier: "ai",
        active_session_id: "s",
        poll_ref: make_ref()
      })

    new_state = State.rebuild_reset(state, nil, MapSet.new(["id-a"]))
    assert new_state.generation == 4
    assert new_state.status == :booting
    assert is_nil(new_state.server_pid)
    assert is_nil(new_state.base_url)
    assert is_nil(new_state.token)
    assert is_nil(new_state.pane_id)
    assert is_nil(new_state.active_identifier)
    assert is_nil(new_state.active_session_id)
    assert is_nil(new_state.poll_ref)
    assert new_state.pending_select == nil
    assert MapSet.member?(new_state.known_identifiers, "id-a")
  end

  test "rebuild_reset stores pending_select" do
    state = base_state(%{generation: 1})
    pending = {self(), "issue-9"}
    new_state = State.rebuild_reset(state, pending, MapSet.new())
    assert new_state.pending_select == pending
  end

  # --- detach/2 ---

  test "detach returns :not_attached when identifier not in attached" do
    state = base_state(%{attached_identifiers: MapSet.new(["a"])})
    assert :not_attached = State.detach(state, "b")
  end

  test "detach of non-visible attached id returns {false, _}" do
    state =
      base_state(%{
        attached_identifiers: MapSet.new(["a", "b"]),
        visible_identifier: "a"
      })

    assert {false, new_state} = State.detach(state, "b")
    refute MapSet.member?(new_state.attached_identifiers, "b")
    assert new_state.visible_identifier == "a"
  end

  test "detach of visible identifier returns {true, _} and clears visible" do
    state =
      base_state(%{
        attached_identifiers: MapSet.new(["a"]),
        visible_identifier: "a",
        visible_session_id: "s1",
        active_identifier: "a",
        active_session_id: "s1",
        status: :active
      })

    assert {true, new_state} = State.detach(state, "a")
    assert is_nil(new_state.visible_identifier)
    assert is_nil(new_state.visible_session_id)
    assert is_nil(new_state.active_identifier)
    assert is_nil(new_state.active_session_id)
    assert new_state.status == :ready
    assert is_nil(new_state.poll_ref)
  end

  # --- clear_visible/1 and deselect/1 ---

  test "clear_visible sets visible/active fields to nil and status :ready" do
    state = base_state(%{visible_identifier: "x", visible_session_id: "s", active_identifier: "x", active_session_id: "s"})
    new_state = State.clear_visible(state)
    assert is_nil(new_state.visible_identifier)
    assert is_nil(new_state.visible_session_id)
    assert is_nil(new_state.active_identifier)
    assert is_nil(new_state.active_session_id)
    assert new_state.status == :ready
    assert is_nil(new_state.poll_ref)
  end

  test "deselect clears all active/visible fields" do
    state =
      base_state(%{
        active_identifier: "x",
        active_session_id: "s",
        visible_identifier: "x",
        visible_session_id: "s"
      })

    new_state = State.deselect(state)
    assert is_nil(new_state.active_identifier)
    assert is_nil(new_state.visible_identifier)
    assert new_state.status == :ready
    assert is_nil(new_state.poll_ref)
  end

  # --- select_applied/4 ---

  test "select_applied sets status :active and updates all fields" do
    state = base_state(%{attached_identifiers: MapSet.new()})
    new_state = State.select_applied(state, "issue-7", "sess-7", "pane-7")
    assert new_state.status == :active
    assert new_state.active_identifier == "issue-7"
    assert new_state.active_session_id == "sess-7"
    assert new_state.visible_identifier == "issue-7"
    assert new_state.visible_session_id == "sess-7"
    assert new_state.pane_id == "pane-7"
    assert MapSet.member?(new_state.attached_identifiers, "issue-7")
  end

  # --- queue_pending_attach/2 ---

  test "queue_pending_attach adds to known and pending_attaches" do
    state = base_state(%{})
    new_state = State.queue_pending_attach(state, "issue-3")
    assert MapSet.member?(new_state.known_identifiers, "issue-3")
    assert MapSet.member?(new_state.pending_attaches, "issue-3")
  end

  # --- attach_pane_ready/2 ---

  test "attach_pane_ready with pane_id sets status :ready" do
    state = base_state(%{status: :attach_spawning})
    new_state = State.attach_pane_ready(state, "pane-99")
    assert new_state.status == :ready
    assert new_state.pane_id == "pane-99"
  end

  test "attach_pane_ready with nil pane_id (fast-path)" do
    state = base_state(%{status: :attach_spawning})
    new_state = State.attach_pane_ready(state, nil)
    assert new_state.status == :ready
    assert is_nil(new_state.pane_id)
  end

  # --- serve_ready/5 ---

  test "serve_ready sets status :attach_spawning and known_identifiers from agent_ids" do
    state = base_state(%{status: :booting})
    new_state = State.serve_ready(state, self(), "http://x:1234", "tok", ["a", "b"])
    assert new_state.status == :attach_spawning
    assert new_state.base_url == "http://x:1234"
    assert new_state.token == "tok"
    assert MapSet.member?(new_state.known_identifiers, "a")
    assert MapSet.member?(new_state.known_identifiers, "b")
  end

  # --- snapshot/1 ---

  test "snapshot returns all expected keys" do
    state = base_state(%{base_url: "http://z"})
    snap = State.snapshot(state)
    expected_keys = ~w(slot_index status active_identifier active_session_id visible_identifier visible_session_id attached_identifiers pane_id base_url generation)a
    Enum.each(expected_keys, fn k -> assert Map.has_key?(snap, k) end)
  end

  # --- identifier_known?/2 ---

  test "identifier_known? returns true when in known_identifiers" do
    state = base_state(%{known_identifiers: MapSet.new(["x"])})
    assert State.identifier_known?(state, "x")
    refute State.identifier_known?(state, "y")
  end

  # --- rebuild_seed_identifiers/1 ---

  test "rebuild_seed_identifiers returns {:known, ids} when pending_select is set" do
    state = base_state(%{pending_select: {self(), "issue-1"}, known_identifiers: MapSet.new(["id-1"])})
    assert {:known, ids} = State.rebuild_seed_identifiers(state)
    assert "id-1" in ids
  end

  test "rebuild_seed_identifiers returns {:known, ids} when known non-empty" do
    state = base_state(%{pending_select: nil, known_identifiers: MapSet.new(["id-2"])})
    assert {:known, ids} = State.rebuild_seed_identifiers(state)
    assert "id-2" in ids
  end

  test "rebuild_seed_identifiers returns :poll_orchestrator when both empty" do
    state = base_state(%{pending_select: nil, known_identifiers: MapSet.new()})
    assert :poll_orchestrator = State.rebuild_seed_identifiers(state)
  end

  # --- display_opt/1 ---

  test "display_opt returns [display_identifier: id] when pending_select is set" do
    state = base_state(%{pending_select: {self(), "issue-5"}})
    assert [display_identifier: "issue-5"] = State.display_opt(state)
  end

  test "display_opt returns [] when pending_select is nil" do
    state = base_state(%{pending_select: nil})
    assert [] = State.display_opt(state)
  end
end
