defmodule Aiur.Opencode.Slot.AttachTest do
  # Characterization tests for code moved out of Slot unchanged: they guard
  # future regressions of the attach and claim transitions.
  use ExUnit.Case, async: true

  alias Aiur.Opencode.Slot
  alias Aiur.Opencode.Slot.{Attach, State}

  defp state(overrides), do: struct!(%State{slot_index: 9, status: :ready}, overrides)

  describe "do_attach/2" do
    test "an already-attached identifier is idempotent and leaves state alone" do
      state = state(attached_identifiers: MapSet.new(["a", "b"]), visible_identifier: "a", visible_session_id: "ses_a")

      assert Attach.do_attach("a", state) == {:ok, "ses_a", state}
      assert Attach.do_attach("b", state) == {:ok, :attached, state}
    end

    test "an identifier the serve was not booted with is refused" do
      assert Attach.do_attach("new", state([])) == {:error, :identifier_unknown}
    end
  end

  describe "claims" do
    test "clear_claim_for/2 releases only the claiming owner's monitor" do
      ref = Process.monitor(self())
      claimed = state(status: :claimed, claim_owner: self(), claim_ref: ref)

      other = spawn(fn -> :ok end)
      assert Attach.clear_claim_for({other, make_ref()}, claimed) == claimed

      cleared = Attach.clear_claim_for({self(), make_ref()}, claimed)
      assert %{claim_owner: nil, claim_ref: nil, status: :claimed} = cleared
      assert Process.demonitor(ref, [:info]) == false
    end

    test "unclaim/1 returns a claimed slot to :ready and leaves other statuses alone" do
      ref = Process.monitor(self())

      assert %{status: :ready, claim_owner: nil, claim_ref: nil} =
               Attach.unclaim(state(status: :claimed, claim_owner: self(), claim_ref: ref))

      active = state(status: :active)
      assert Attach.unclaim(active) == active
    end
  end

  describe "drain_pending_attaches/1" do
    test "retries each pending identifier, announces the ones that attach, and empties the queue" do
      :ok = Aiur.TestSupport.ensure_pubsub_running()
      Phoenix.PubSub.subscribe(Aiur.PubSub, Slot.slots_topic())

      pending = state(attached_identifiers: MapSet.new(["a"]), pending_attaches: MapSet.new(["a", "unknown"]))
      drained = Attach.drain_pending_attaches(pending)

      assert drained == %{pending | pending_attaches: MapSet.new()}
      assert_receive {:slot_attach_added, 9, "a"}, 1_000
      refute_received {:slot_attach_added, 9, "unknown"}
    end

    test "nothing pending is a no-op" do
      idle = state([])
      assert Attach.drain_pending_attaches(idle) == idle
    end
  end
end
