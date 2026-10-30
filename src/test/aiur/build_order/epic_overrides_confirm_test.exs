defmodule Aiur.BuildOrder.EpicOverridesConfirmTest do
  use ExUnit.Case, async: false
  alias Aiur.BuildOrder.Epic
  alias Aiur.BuildOrder.EpicOverrides, as: Store
  alias Aiur.BuildOrder.EpicOverrides.Override
  @guess %{actor: "agent:2790", source: "backfill-agent"}
  @cli %{actor: "cli:kevin", source: "cli:kevin"}
  @now ~U[2026-10-08 10:00:00Z]

  setup do
    dir = Aiur.TestSupport.tmp_root!("epic-confirm")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)
    config = start_supervised!({Agent, fn -> settings(["bugs", "infra", "design"]) end})
    name = Module.concat(__MODULE__, "S#{System.unique_integer([:positive])}")
    opts = [name: name, repository: "acme/app", state_dir: dir, settings_fun: fn -> Agent.get(config, & &1) end]
    pid = start_supervised!({Store, opts})
    write = [server: name, now: @now]
    assert {:ok, _} = Store.set("infra", [12, 14], @guess, write)
    %{write: write, config: config, path: Path.join(dir, "epic-overrides.json"), pid: pid, opts: opts}
  end

  test "confirmation persists acceptance with original epic and old journal format", c do
    at = DateTime.add(@now, 60)

    assert {:ok, %{results: [%{number: 12, status: :changed, epic: "infra", previous: %{confirmed: false, source: "backfill-agent"}}]}} =
             Store.confirm([12, 12], @cli, Keyword.put(c.write, :now, at))

    assert {:ok, %{12 => %{epic: "infra", confirmed: true, actor: "cli:kevin", source: "cli:kevin", at: ^at}}, _} = Store.get_many([12], c.write)
    assert {:ok, [guess, accepted]} = Store.journal([12], c.write)
    assert guess.source == "backfill-agent"
    assert accepted.op == "set"
    assert {:ok, %{value: %{confirmed: true, epic: "infra"}}} = accepted |> Jason.encode!() |> Jason.decode!() |> Override.from_entry()
    stop_supervised!(Store)
    start_supervised!({Store, c.opts})
    assert {:ok, %{12 => %{confirmed: true, source: "cli:kevin"}}, _} = Store.get_many([12], c.write)
  end

  test "repeated confirmation does not write or broadcast, including other accepted sources", c do
    assert {:ok, _} = Store.confirm([12], @cli, c.write)
    assert {:ok, _} = Store.set("bugs", [13], %{actor: "agent:42", source: "agent:42"}, c.write)
    before = File.read!(c.path)
    :ok = Store.subscribe()
    assert {:ok, %{results: [%{status: :unchanged}, %{status: :unchanged}]}} = Store.confirm([12, 13], @cli, c.write)
    assert File.read!(c.path) == before
    refute_receive {:epic_overrides_changed, _}, 50
    assert {:ok, %{13 => %{source: "agent:42"}}, _} = Store.get_many([13], c.write)
  end

  test "whole batch collects missing and changed failures before any write", c do
    assert {:ok, _} = Store.set("design", [14], @guess, c.write)
    before = File.read!(c.path)

    assert {:error, {:confirm_refused, [{:no_override, 15}, {:epic_changed, 14, "design"}]}} =
             Store.confirm([12, 15, 14], @cli, c.write ++ [expect_epic: "infra"])

    assert File.read!(c.path) == before
    assert {:ok, %{12 => %{confirmed: false}}, _} = Store.get_many([12], c.write)
    assert {:ok, %{results: [%{epic: "design"}]}} = Store.confirm([14], @cli, c.write)
  end

  test "removed catalog key and unreadable settings refuse rather than assume defaults", c do
    before = File.read!(c.path)
    Agent.update(c.config, fn _ -> settings(["bugs"]) end)
    assert {:error, {:confirm_refused, [{:not_a_configured_epic, 12, "infra"}]}} = Store.confirm([12], @cli, c.write)
    Agent.update(c.config, fn _ -> {:error, :invalid} end)
    assert {:error, :epic_config_unavailable} = Store.confirm([12], @cli, c.write)
    assert File.read!(c.path) == before
  end

  test "confirm validates batch and provenance and refuses unavailable writer", c do
    assert {:error, {:too_many_ids, 200}} = Store.confirm(Enum.to_list(1..201), @cli, c.write)
    assert {:error, :invalid_epic_arguments} = Store.confirm([12], @guess, c.write)
    assert {:error, :invalid_epic_arguments} = Store.confirm([], @cli, c.write)
    stop_supervised!(Store)
    assert {:error, :epic_overrides_not_running} = Store.confirm([12], @cli, c.write)
    File.write!(c.path, "corrupt")
    start_supervised!({Store, c.opts})
    assert {:error, :epic_overrides_unavailable} = Store.confirm([12], @cli, c.write)
    assert File.read!(c.path) == "corrupt"
  end

  test "confirmation makes a stored override outrank the ticket type label", c do
    context = %{general: [%{key: "bugs", labels: ["bug"]}, %{key: "infra", labels: ["infra"]}], features: %{}}
    {:ok, before, _} = Store.get_many([12], c.write)
    assert %{key: "bugs"} = Epic.resolve(%{labels: ["bug", "refactor"], override: before[12]}, context)
    assert {:ok, _} = Store.confirm([12], @cli, c.write)
    {:ok, after_confirm, _} = Store.get_many([12], c.write)
    assert %{key: "infra", source: "override:cli:kevin"} = Epic.resolve(%{labels: ["bug", "refactor"], override: after_confirm[12]}, context)
  end

  test "acceptance protects the value against later backfill", c do
    assert {:ok, _} = Store.confirm([12], @cli, c.write)
    assert {:ok, %{results: [%{status: :kept_existing}]}} = Store.set("design", [12], @guess, c.write)
    assert {:ok, %{12 => %{epic: "infra", confirmed: true, source: "cli:kevin"}}, _} = Store.get_many([12], c.write)
  end

  defp settings(keys), do: {:ok, %{build_order: %{general_epics: Enum.map(keys, &%{key: &1, label: &1})}}}
end
