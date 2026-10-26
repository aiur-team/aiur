defmodule Aiur.Events.Export.WiringTest do
  use ExUnit.Case, async: false
  alias Aiur.Events.{Catalog, Export}
  alias Aiur.Events.Export.Exporter

  test "exporter is last in every run shape and disabled adds no child" do
    for interactive? <- [false, true], dashboard? <- [false, true] do
      opts = [interactive_cli?: interactive?, headless?: not interactive?, dashboard?: dashboard?]
      disabled = Aiur.Application.child_specs(opts ++ [export_enabled?: false])
      enabled = Aiur.Application.child_specs(opts ++ [export_enabled?: true])
      assert {Exporter, callbacks} = List.last(enabled)
      assert is_function(callbacks[:on_unavailable], 1)
      assert is_function(callbacks[:on_appended], 2)
      assert Enum.drop(enabled, -1) == disabled
      refute Enum.any?(disabled, &match?({Exporter, _}, &1))
    end
  end

  test "export segment is an id floor file, ordered numerically" do
    root = Path.join(System.tmp_dir!(), "export-floor-#{System.unique_integer([:positive])}")
    previous = Application.get_env(:aiur, :runtime_state_dir)
    Application.put_env(:aiur, :runtime_state_dir, root)

    on_exit(fn ->
      Application.put_env(:aiur, :runtime_state_dir, previous)
      Aiur.TestCleanup.rm_rf!(root)
    end)

    assert Export.floor_files() == []
    refute File.exists?(root)
    dir = Path.join(root, "events/export")
    File.mkdir_p!(dir)
    for seq <- [9, 10], do: File.write!(Path.join(dir, "seg.#{seq}.ndjson"), "")
    assert Path.join(dir, "seg.10.ndjson") in Aiur.IdFloorSources.floor_files()
    refute Path.join(dir, "seg.9.ndjson") in Aiur.IdFloorSources.floor_files()
  end

  test "disabled facade does not create a directory or process" do
    :persistent_term.erase({Export, :status})
    assert Export.status() == %{state: :disabled, reason: nil, instance: nil, epoch: nil, head_seq: nil, oldest_seq: nil}
    refute Export.enabled?()
    assert Export.read(0, 1, ["#"]) == {:error, :events_unavailable}
    assert Process.whereis(Exporter) == nil
  end

  test "export failure is cataloged but never exported" do
    entry = Catalog.lookup("system.events.export_unavailable")
    assert entry.class == :logged
    refute entry.export?
  end
end
