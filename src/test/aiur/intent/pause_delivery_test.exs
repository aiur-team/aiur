defmodule Aiur.Intent.PauseDeliveryTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO
  import Aiur.IntentFixtures

  alias Aiur.ControlCLI.FleetPause
  alias Aiur.Intent.{Change, Registers, Store}
  alias Aiur.Orchestrator.{GlobalPause, Slots, State}
  alias Aiur.Orchestrator.StatusCLI.Diagnostics

  @now 5_000_000

  setup do
    {:ok, store} = Store.start_link(dir: tmp_dir("fleet-pause"), name: nil)
    %{store: store, opts: [store: store, own_gateway: "LOCAL", now_ms: @now]}
  end

  defp pause_change(id, wall, value, slot \\ "human", origin \\ "PEER") do
    change(%{
      change_id: id,
      entity_kind: "fleet",
      entity_key: "fleet",
      field: "pause",
      value_json: value,
      slot: slot,
      origin_gateway: origin,
      hlc_wall_ms: wall
    })
  end

  defp remote!(store, c), do: {:ok, [_]} = Store.append_remote(store, [c])

  describe "Registers.fleet_pause/1" do
    test "never synced, paused by a peer, and cleared by a later human unpause", %{store: store, opts: opts} do
      remote!(store, change(%{change_id: "ticket-order"}))
      assert :never_synced = Registers.fleet_pause(opts)

      remote!(store, pause_change("p1", 1_000, true))
      assert {:paused, "p1", paused_at, "dashboard:kevin"} = Registers.fleet_pause(opts)
      assert DateTime.to_unix(paused_at, :millisecond) == 1_000

      remote!(store, pause_change("u1", 2_000, false))
      assert :clear = Registers.fleet_pause(opts)
    end

    test "an executor unpause leaves a human pause; a human unpause clears an executor pause", %{store: store, opts: opts} do
      remote!(store, pause_change("h", 1_000, true, "human"))
      remote!(store, pause_change("e-clear", 2_000, false, "executor"))
      assert {:paused, "h", _, _} = Registers.fleet_pause(opts)

      remote!(store, pause_change("e", 3_000, true, "executor"))
      remote!(store, pause_change("h-clear", 4_000, false, "human"))
      assert :clear = Registers.fleet_pause(opts)
    end
  end

  describe "boot" do
    test "a gateway that was offline when pause-all was set boots fleet-paused and dispatches nothing", %{store: store, opts: opts} do
      # What an offline gateway holds after its first sync: the peer's fleet pause in the change cache.
      remote!(store, pause_change("p1", 1_000, true))

      assert GlobalPause.boot_fleet_paused(opts)

      state = %State{fleet_paused: true}
      assert Slots.available_slots(state) == 0
      assert %{globally_paused: true, fleet_paused: true, pause_scope: :fleet} = GlobalPause.global_pause_status(state)
    end

    test "a gateway that never saw a fleet pause boots unpaused", %{opts: opts} do
      refute GlobalPause.boot_fleet_paused(opts)
      assert Slots.available_slots(%State{fleet_paused: false}) > 0
    end
  end

  describe "running gateway" do
    test "a pause arriving by sync flips the fleet switch and the effective status", %{store: store, opts: opts} do
      state = %State{fleet_paused: false}
      assert {:noreply, ^state} = GlobalPause.fleet_pause_info(state, opts)

      remote!(store, pause_change("p1", 1_000, true))
      assert {:noreply, %State{fleet_paused: true} = paused} = GlobalPause.fleet_pause_info(state, opts)
      assert Slots.available_slots(paused) == 0
      assert %{pause_scope: :fleet, globally_paused: true} = GlobalPause.global_pause_status(paused)
    end
  end

  describe "status banner" do
    defp banner(status), do: capture_io(fn -> Diagnostics.print_global_pause_banner([global_pause_status: {:ok, status}], 100) end)

    test "names a fleet-only pause as paused (fleet) and the fleet hold alongside a local one" do
      assert banner(%{globally_paused: true, pause_scope: :fleet, paused_at: nil, source: nil}) =~ "paused (fleet)"
      both = banner(%{globally_paused: true, pause_scope: :both, paused_at: nil, source: "CLI"})
      assert both =~ "GLOBALLY PAUSED" and both =~ "paused (fleet)"
      assert banner(%{globally_paused: true, pause_scope: :local, paused_at: nil, source: "CLI"}) =~ "GLOBALLY PAUSED"
      assert banner(%{globally_paused: false, pause_scope: :none}) == ""
    end
  end

  test "local and fleet pause are reported independently" do
    assert %{pause_scope: :local, fleet_paused: false} = GlobalPause.global_pause_status(%State{globally_paused: true})
    assert %{pause_scope: :both} = GlobalPause.global_pause_status(%State{globally_paused: true, fleet_paused: true})
    assert %{pause_scope: :none, globally_paused: false} = GlobalPause.global_pause_status(%State{})
  end

  describe "apply_remote_change/2" do
    defp deliver(c, opts), do: capture_io(fn -> FleetPause.apply_remote_change(c |> Change.to_json() |> Jason.encode!(), opts) end)

    test "applies an executor pause once and reports a duplicate the second time", %{store: store, opts: opts} do
      c = pause_change("direct", 1_000, true, "executor")
      assert deliver(c, opts) =~ "applied"
      assert deliver(c, opts) =~ "duplicate"
      assert {:paused, "direct", _, _} = Registers.fleet_pause(opts)
      assert Store.outbox(store) == []
    end

    test "refuses anything that is not a fleet pause, and a remote human unpause", %{store: store, opts: opts} do
      assert deliver(change(%{change_id: "order"}), opts) =~ "__AIUR_CONTROL_EXIT__:1"
      assert deliver(pause_change("hu", 1_000, false, "human"), opts) =~ "__AIUR_CONTROL_EXIT__:1"
      assert Store.changes(store) == []
    end
  end
end
