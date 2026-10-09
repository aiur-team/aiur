defmodule Aiur.EpicCLITest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO
  alias Aiur.BuildOrder.EpicOverrides, as: Store
  alias Aiur.EpicCLI

  setup do
    dir = Aiur.TestSupport.tmp_root!("epic-cli")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, config} = Agent.start_link(fn -> {:ok, %{build_order: %{general_epics: [%{key: "bugs", label: "Bugs"}, %{key: "docs", label: "Docs"}]}}} end)
    name = Module.concat(__MODULE__, "S#{System.unique_integer([:positive])}")
    opts = [name: name, repository: "acme/app", state_dir: dir, settings_fun: fn -> Agent.get(config, & &1) end]
    %{opts: opts, server: [server: name], path: Path.join(dir, "epic-overrides.json"), config: config}
  end

  defp run(opts, code) do
    capture_io(fn -> assert EpicCLI.run(Keyword.put(opts, :error_fun, &IO.puts/1)) == code end)
  end

  test "V-21 unavailable show text and JSON never imply no override", c do
    File.write!(c.path, "{bad")
    start_supervised!({Store, c.opts})
    text = run(c.server ++ [action: :show, ids: [12]], 1)
    assert text =~ "unavailable (epic_overrides_corrupt)"
    refute text =~ "no override"
    json = capture_io(fn -> assert EpicCLI.run(c.server ++ [action: :show, json: true, error_fun: fn _ -> :ok end]) == 1 end) |> Jason.decode!()
    assert json["ok"] == false
    assert json["health"]["failure"] == "epic_overrides_corrupt"
    refute Map.has_key?(json, "overrides")
  end

  test "V-22 V-22b removed and unreadable catalog retain truthful known status", c do
    start_supervised!({Store, c.opts})
    Store.set("docs", [12], %{actor: "cli:kevin", source: "cli:kevin"}, c.server)
    Agent.update(c.config, fn _ -> {:ok, %{build_order: %{general_epics: [%{key: "bugs", label: "Bugs"}]}}} end)
    assert run(c.server ++ [action: :show], 0) =~ "docs (not a configured epic; ignored)"
    assert [row] = run(c.server ++ [action: :show, json: true], 0) |> Jason.decode!() |> Map.fetch!("overrides")
    assert row["epic_known"] == false
    Agent.update(c.config, fn _ -> {:error, :boom} end)
    assert run(c.server ++ [action: :show], 0) =~ "epic config unavailable"
    assert [row] = run(c.server ++ [action: :show, json: true], 0) |> Jason.decode!() |> Map.fetch!("overrides")
    assert Map.has_key?(row, "epic_known") and row["epic_known"] == nil
  end

  test "V-23 set JSON includes unchanged and previous actor", c do
    start_supervised!({Store, c.opts})
    Store.set("docs", [12], %{actor: "agent:2790", source: "backfill-agent"}, c.server)
    opts = c.server ++ [action: :set, epic: "bugs", ids: [12, 13], who: "kevin", json: true]
    json = run(opts, 0) |> Jason.decode!()
    assert json["generation"] == 3
    assert [%{"status" => "changed", "previous" => %{"actor" => "agent:2790", "confirmed" => false}}, %{"previous" => nil}] = json["results"]
    assert Enum.map(Jason.decode!(run(opts, 0))["results"], & &1["status"]) == ["unchanged", "unchanged"]
    assert run(c.server ++ [action: :show, ids: [12, 14]], 0) =~ "#14  no override"
    assert run(c.server ++ [action: :clear, ids: [12], who: "kevin"], 0) =~ "#12 was bugs by cli:kevin"
  end

  test "V-24 CLI refuses agent identity sources and invalid actors", c do
    start_supervised!({Store, c.opts})

    for {who, source} <- [{"kevin", "agent:5"}, {"", :cli}, {"a b", :cli}] do
      assert run(c.server ++ [action: :set, epic: "bugs", ids: [12], who: who, source: source], 1) =~ "invalid_epic_arguments"
    end

    refute File.exists?(c.path)
  end

  test "V-33 list uses configured keys in order and no fallback on config error", c do
    start_supervised!({Store, c.opts})
    Agent.update(c.config, fn _ -> {:ok, %{build_order: %{general_epics: [%{key: "ops", label: "Ops"}]}}} end)
    assert run(c.server ++ [action: :list], 0) == "ops  Ops\n"
    assert Jason.decode!(run(c.server ++ [action: :list, json: true], 0))["epics"] == [%{"key" => "ops", "label" => "Ops"}]
    Agent.update(c.config, fn _ -> {:error, :boom} end)
    text = run(c.server ++ [action: :list], 1)
    assert text =~ "epic config unavailable"
    refute text =~ "bugs"
  end
end
