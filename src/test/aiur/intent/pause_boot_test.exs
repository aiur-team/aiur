defmodule Aiur.Intent.PauseBootTest do
  # Not async: starts the default-named Intent.Store and an Orchestrator.
  use Aiur.TestSupport

  import Aiur.IntentFixtures

  alias Aiur.Intent.Store
  alias Aiur.Orchestrator
  alias Aiur.Orchestrator.Slots

  defp pause_change(id, wall) do
    change(%{change_id: id, entity_kind: "fleet", entity_key: "fleet", field: "pause", value_json: true, slot: "human", origin_gateway: "PEER", hlc_wall_ms: wall})
  end

  defp start_orchestrator! do
    name = Module.concat(__MODULE__, :"Orch#{System.unique_integer([:positive])}")
    {:ok, pid} = Orchestrator.start_link(name: name, initial_poll?: false)
    test_pid = self()

    on_exit(fn ->
      Aiur.TestSupport.stop_test_runners(test_pid)
      if Process.alive?(pid), do: Process.exit(pid, :kill)
    end)

    pid
  end

  setup do
    # Swap the app's default-named store for an empty one, and put the app's back afterwards.
    :ok = Supervisor.terminate_child(Aiur.Supervisor, Store)
    on_exit(fn -> Supervisor.restart_child(Aiur.Supervisor, Store) end)
    start_supervised!({Store, dir: tmp_dir("pause-boot")})
    :ok
  end

  test "an Orchestrator booting over a stored fleet pause starts paused and dispatches nothing" do
    assert {:ok, [_]} = Store.append_remote(Store, [pause_change("p1", System.os_time(:millisecond) - 1_000)])

    state = :sys.get_state(start_orchestrator!())
    assert state.fleet_paused
    assert Slots.available_slots(state) == 0
  end

  test "a pause that arrives by sync after boot reaches the running Orchestrator through handle_info" do
    pid = start_orchestrator!()
    refute :sys.get_state(pid).fleet_paused

    assert {:ok, [_]} = Store.append_remote(Store, [pause_change("p2", System.os_time(:millisecond) - 1_000)])
    send(pid, {:intent_register_changed, {"fleet", "fleet", "pause"}, true})

    assert %{fleet_paused: true} = :sys.get_state(pid)
  end
end
