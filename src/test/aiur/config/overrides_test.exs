defmodule Aiur.Config.OverridesTest do
  use Aiur.TestSupport

  alias Aiur.{AlertFeed, AlertLedger, BuildGate}
  alias Aiur.Config.Overrides
  alias Aiur.WorkflowStore.Reload

  setup do
    previous_instance = System.get_env("AIUR_INSTANCE_KEY")
    System.put_env("AIUR_INSTANCE_KEY", "overrides-test-#{System.unique_integer([:positive])}")
    {:ok, path} = Overrides.path()
    instance_dir = Path.dirname(path)

    on_exit(fn ->
      Aiur.TestCleanup.rm_rf!(instance_dir)
      restore_instance(previous_instance)
    end)

    %{override_path: path}
  end

  test "a validated override reloads into the build gate consumer", %{override_path: path} do
    ensure_workflow_store_running()
    write_workflow_file!(Workflow.workflow_file_path(), max_concurrent_builds: 4)

    assert {:ok, %{key: "agent.max_concurrent_builds", value: 2, applies: "live"}} =
             Overrides.set("agent.max_concurrent_builds", 2, "local:test")

    assert :ok = WorkflowStore.force_reload()

    assert %{capacity: 2, enabled?: true} =
             BuildGate.status(gate_dir: Path.join(Path.dirname(path), "build-gate"), strategy: :pid)

    document = path |> File.read!() |> Jason.decode!()
    assert document["version"] == 1
    assert document["revision"] == 1
    assert document["entries"]["agent.max_concurrent_builds"]["set_by"] == "local:test"
  end

  test "an unknown key is rejected before anything is stored", %{override_path: path} do
    assert {:error, {:unknown_setting, version}} =
             Overrides.set("agent.max_concurrent_buildz", 2, "local:test")

    assert is_binary(version)
    refute File.exists?(path)
  end

  test "a schema-invalid value is rejected without changing the active file", %{override_path: path} do
    assert {:ok, _entry} = Overrides.set("agent.max_concurrent_builds", 2, "local:test")
    before = File.read!(path)

    assert {:error, {:invalid_workflow_config, message}} =
             Overrides.set("agent.routing", %{"bad" => true}, "local:test")

    assert message =~ "agent.routing"
    assert File.read!(path) == before
  end

  test "list reports provenance and unset restores the YAML value" do
    ensure_workflow_store_running()
    write_workflow_file!(Workflow.workflow_file_path(), max_concurrent_builds: 3)

    assert {:ok, _entry} = Overrides.set("agent.max_concurrent_builds", 1, "token:pc-executor")
    assert :ok = WorkflowStore.force_reload()
    assert Config.max_concurrent_builds() == 1

    assert {:ok,
            [
              %{
                key: "agent.max_concurrent_builds",
                value: 1,
                source: "override",
                revision: 1,
                actor: "token:pc-executor",
                applies: "live"
              } = listed
            ]} = Overrides.list()

    assert is_binary(listed.set_at)
    assert is_binary(listed.build)

    assert {:ok, :removed} = Overrides.unset("agent.max_concurrent_builds", "local:test")
    assert :ok = WorkflowStore.force_reload()
    assert Config.max_concurrent_builds() == 3
    assert {:ok, []} = Overrides.list()
  end

  test "uncached settings and a fresh store init read the persisted layer" do
    assert {:ok, _entry} = Overrides.set("agent.max_concurrent_builds", 2, "local:test")
    assert {:ok, settings} = Config.settings_uncached()
    assert settings.agent.max_concurrent_builds == 2

    ensure_workflow_store_running()
    store = Process.whereis(WorkflowStore)
    :sys.suspend(store)

    on_exit(fn ->
      if Process.alive?(store), do: :sys.resume(store)
    end)

    assert {:ok, state} = WorkflowStore.init([])
    assert {:ok, restarted_settings} = Config.settings_from({:ok, state.workflow})
    assert restarted_settings.agent.max_concurrent_builds == 2
  end

  test "a set landing after apply remains visible to the next reload" do
    assert {:ok, _entry} = Overrides.set("agent.max_concurrent_builds", 1, "local:test")

    Process.put(:workflow_store_after_override_apply, fn ->
      Process.delete(:workflow_store_after_override_apply)
      assert {:ok, _entry} = Overrides.set("agent.max_concurrent_builds", 2, "local:test")
      :ok
    end)

    on_exit(fn -> Process.delete(:workflow_store_after_override_apply) end)

    assert {:ok, first_state} = Reload.load_state(Workflow.workflow_file_path())
    assert {:ok, first_settings} = Config.settings_from({:ok, first_state.workflow})
    assert first_settings.agent.max_concurrent_builds == 1

    assert {:ok, second_state} = Reload.reload_state(first_state)
    assert {:ok, second_settings} = Config.settings_from({:ok, second_state.workflow})
    assert second_settings.agent.max_concurrent_builds == 2
  end

  test "boot keeps accepted entries and quarantines rejected entries", %{override_path: path} do
    ensure_workflow_store_running()
    store = Process.whereis(WorkflowStore)
    :sys.suspend(store)

    on_exit(fn ->
      if Process.alive?(store), do: :sys.resume(store)
    end)

    write_override!(path, %{
      "agent.max_concurrent_builds" => entry(2, 1),
      "agent.max_concurrent_buildz" => entry(9, 2),
      "agent.routing" => entry(%{"bad" => true}, 3)
    })

    assert {:ok, state} = WorkflowStore.init([])
    assert {:ok, settings} = Config.settings_from({:ok, state.workflow})
    assert settings.agent.max_concurrent_builds == 2
    assert settings.agent.routing == %{}

    live = path |> File.read!() |> Jason.decode!()
    assert Map.keys(live["entries"]) == ["agent.max_concurrent_builds"]

    [rejected_path] = Path.wildcard(Path.join(Path.dirname(path), "config-overrides.rejected-*.json"))
    rejected = rejected_path |> File.read!() |> Jason.decode!()

    assert rejected["entries"] |> Map.keys() |> Enum.sort() == [
             "agent.max_concurrent_buildz",
             "agent.routing"
           ]

    assert Enum.any?(AlertFeed.list(ledger_paths: [AlertLedger.path()]), fn alert ->
             alert["topic"] == "config.override_rejected" and
               alert["needs_attention"] == true and
               alert["message"] =~ "agent.max_concurrent_buildz" and
               alert["message"] =~ "agent.routing"
           end)
  end

  test "missing instance identity disables boot overrides and names set refusal" do
    previous = System.get_env("AIUR_INSTANCE_KEY")

    try do
      System.delete_env("AIUR_INSTANCE_KEY")

      assert {:error, :instance_key_missing} =
               Overrides.set("agent.max_concurrent_builds", 2, "local:test")

      assert {:ok, workflow} = Workflow.load()
      assert {:ok, settings} = Config.settings_from({:ok, workflow})
      assert settings.agent.max_concurrent_builds == 4
    after
      System.put_env("AIUR_INSTANCE_KEY", previous)
    end
  end

  defp entry(value, revision) do
    %{
      "value" => value,
      "revision" => revision,
      "set_by" => "local:test",
      "set_at" => "2026-10-23T18:04:11Z",
      "build" => "0.0.0+test"
    }
  end

  defp write_override!(path, entries) do
    File.mkdir_p!(Path.dirname(path))

    File.write!(
      path,
      Jason.encode!(%{"version" => 1, "revision" => map_size(entries), "entries" => entries})
    )
  end

  defp restore_instance(nil), do: System.delete_env("AIUR_INSTANCE_KEY")
  defp restore_instance(value), do: System.put_env("AIUR_INSTANCE_KEY", value)
end
