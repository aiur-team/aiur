defmodule Aiur.LaneCLITest do
  @moduledoc """
  `aiur lane …` is the canonical spelling of the lane override commands. It
  reads and writes the same store as the deprecated `aiur epic set|clear|confirm`
  spelling, and its `show --json` output is the one that spelling has always
  printed.
  """
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO
  alias Aiur.BuildOrder.EpicOverrides, as: Store
  alias Aiur.EpicCLI
  alias Aiur.LaneCLI

  setup do
    dir = Aiur.TestSupport.tmp_root!("lane-cli")
    File.mkdir_p!(dir)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)
    settings = fn -> {:ok, %{build_order: %{lanes: [%{key: "ui", label: "UI"}, %{key: "infra", label: "Infra"}]}}} end
    name = Module.concat(__MODULE__, "S#{System.unique_integer([:positive])}")
    opts = [name: name, repository: "acme/app", state_dir: dir, settings_fun: settings]
    %{opts: opts, server: [server: name], lane: [server: name, name: name, repository: "acme/app", state_dir: dir, settings_fun: settings]}
  end

  defp run(cli, opts, code) do
    capture_io(fn -> assert cli.run(Keyword.put(opts, :error_fun, &IO.puts/1)) == code end)
  end

  test "lane set ui 812 writes the lane override and exits 0", c do
    start_supervised!({Store, c.opts})
    assert run(LaneCLI, c.lane ++ [action: :set, epic: "ui", ids: [812], who: "kevin"], 0) =~ "set ui: #812 changed"
    assert {:ok, %{812 => %{epic: "ui", actor: "cli:kevin", source: "cli:kevin", confirmed: true}}, _} = Store.all(c.server)
  end

  test "aiur epic set has the same effect as aiur lane set", c do
    start_supervised!({Store, c.opts})
    assert run(EpicCLI, c.lane ++ [action: :set, epic: "ui", ids: [812], who: "kevin"], 0) =~ "set ui: #812 changed"
    assert {:ok, %{812 => %{epic: "ui", actor: "cli:kevin"}}, _} = Store.all(c.server)
    assert run(LaneCLI, c.lane ++ [action: :show, ids: [812]], 0) =~ "#812  ui  cli:kevin"
  end

  test "aiur lane show --json equals aiur epic show --json for the same store", c do
    start_supervised!({Store, c.opts})
    run(LaneCLI, c.server ++ [action: :set, epic: "ui", ids: [812, 813], who: "kevin"], 0)
    run(LaneCLI, c.server ++ [action: :set, epic: "infra", ids: [813], who: "kevin"], 0)

    lane = run(LaneCLI, c.lane ++ [action: :show, json: true], 0)
    epic = run(EpicCLI, c.lane ++ [action: :show, json: true], 0)
    assert lane == epic

    decoded = Jason.decode!(lane)
    assert decoded["ok"] == true
    assert Enum.map(decoded["overrides"], & &1["number"]) == [812, 813]
    assert Enum.map(decoded["overrides"], & &1["epic"]) == ["ui", "infra"]
    assert Enum.all?(decoded["overrides"], &(&1["epic_known"] == true))
  end

  test "lane show and epic show print the same text row", c do
    start_supervised!({Store, c.opts})
    run(LaneCLI, c.server ++ [action: :set, epic: "ui", ids: [812], who: "kevin"], 0)

    lane = run(LaneCLI, c.lane ++ [action: :show], 0)
    assert lane =~ "#812  ui  cli:kevin  cli:kevin  confirmed"
    assert run(EpicCLI, c.lane ++ [action: :show], 0) == lane
  end
end
