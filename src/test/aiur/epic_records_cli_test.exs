defmodule Aiur.EpicRecordsCLITest do
  @moduledoc """
  `aiur epic create|edit|add|remove|show|list` over the epic journal.

  The deprecated `aiur epic set|clear|confirm` spellings and the lane override
  store they reach stay in `Aiur.EpicCLITest` and `Aiur.LaneCLITest`.
  """
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO

  alias Aiur.BuildOrder.Features
  alias Aiur.EpicCLI

  setup do
    dir = Aiur.TestSupport.tmp_root!("epic-records-cli")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)
    name = Module.concat(__MODULE__, "S#{System.unique_integer([:positive])}")

    start_supervised!({Features, name: name, state_dir: dir, filesystem_sync_fun: fn -> :ok end, general_epics: [%{key: "bugs", hue: 38}], alert_fun: fn _, _, _ -> :ok end})

    %{server: [server: name], opts: [server: name, who: "kevin", error_fun: &IO.puts/1]}
  end

  test "create writes a record and list and show read it back", c do
    created = run(c.opts ++ [action: :create, slug: "combat-pack", label: "Combat pack", hue: 120, json: true], 0)
    assert %{"command" => "epic create", "changed" => ["epic.created"], "epic" => %{"slug" => "combat-pack", "label" => "Combat pack", "hue" => 120}} = Jason.decode!(created)

    assert {:ok, _} = Features.create("khala-srv", %{label: "Khala"}, source: "cli:kevin", actor: "kevin", server: c.server[:server])
    run(c.opts ++ [action: :add, slug: "combat-pack", features: ["khala-srv"]], 0)

    assert [%{"slug" => "combat-pack", "features" => ["khala-srv"]}] = c.opts |> Keyword.put(:action, :list) |> Keyword.put(:json, true) |> then(&run(&1, 0)) |> Jason.decode!() |> Map.fetch!("epics")

    shown = c.opts ++ [action: :show, slug: "combat-pack", json: true]
    assert %{"command" => "epic show", "epic" => %{"slug" => "combat-pack"}, "features" => %{"khala-srv" => %{"label" => "Khala"}}} = Jason.decode!(run(shown, 0))
    assert run(c.opts ++ [action: :show, slug: "combat-pack"], 0) =~ "features khala-srv (Khala)"
  end

  test "a repeated add changes nothing and a second epic refuses the same feature", c do
    assert {:ok, _} = Features.create("khala-srv", %{label: "Khala"}, source: "cli:kevin", actor: "kevin", server: c.server[:server])
    run(c.opts ++ [action: :create, slug: "combat-pack", label: "Combat pack"], 0)
    run(c.opts ++ [action: :create, slug: "infra", label: "Infra"], 0)
    run(c.opts ++ [action: :add, slug: "combat-pack", features: ["khala-srv"]], 0)

    assert run(c.opts ++ [action: :add, slug: "combat-pack", features: ["khala-srv"]], 0) =~ "epic add combat-pack unchanged"
    assert run(c.opts ++ [action: :add, slug: "infra", features: ["khala-srv"]], 1) =~ "feature khala-srv already belongs to epic combat-pack"
    assert run(c.opts ++ [action: :remove, slug: "infra", features: ["khala-srv"]], 1) =~ "not in this epic: khala-srv"
    assert {:ok, %{features: []}} = Features.epic("infra", server: c.server[:server])
  end

  test "edit changes a label and refuses an unknown epic", c do
    run(c.opts ++ [action: :create, slug: "combat-pack", label: "Combat pack"], 0)
    assert run(c.opts ++ [action: :edit, slug: "combat-pack", label: "Combat"], 0) =~ "updated epic combat-pack"
    assert {:ok, %{label: "Combat", label_source: :operator}} = Features.epic("combat-pack", server: c.server[:server])
    assert run(c.opts ++ [action: :edit, slug: "missing", label: "Nope"], 1) =~ "unknown epic missing"
  end

  @tag :future_regression
  test "future regression guard: usage failures exit 64 before the registry", c do
    for opts <- [
          [action: :create, slug: "combat-pack"],
          [action: :create, slug: "Combat", label: "Combat"],
          [action: :create, slug: "combat-pack", label: "Combat", hue: 400],
          [action: :create, slug: "combat-pack", label: "Combat", icon: "bug ant"],
          [action: :edit, slug: "combat-pack"],
          [action: :add, slug: "combat-pack"],
          [action: :add, slug: "combat-pack", features: ["Combat"]]
        ] do
      text = run(c.opts ++ opts, 64)
      assert text =~ "aiur: epic:"
    end

    text = run(Keyword.delete(c.opts, :who) ++ [action: :create, slug: "combat-pack", label: "Combat"], 64)
    assert text =~ "valid --as or USER"
  end

  defp run(opts, code) do
    capture_io(fn -> assert EpicCLI.run(Keyword.put(opts, :error_fun, &IO.puts/1)) == code end)
  end
end
