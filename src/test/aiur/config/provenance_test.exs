defmodule Aiur.Config.ProvenanceTest do
  use ExUnit.Case, async: true

  alias Aiur.Config.Provenance
  alias Aiur.Machine.Settings

  @project "/repo/.aiur/config"
  @user "/home/u/.aiur/config"

  defp files(map) do
    fn path ->
      case Map.fetch(map, path) do
        {:ok, config} -> {:ok, config}
        :error -> :missing
      end
    end
  end

  defp opts(extra) do
    Keyword.merge(
      [
        candidates: [@project, @user],
        machine_fun: fn -> {:ok, %Settings{}} end,
        overrides_fun: fn -> {:ok, []} end,
        session_cap_fun: fn -> nil end,
        load_fun: files(%{}),
        now: ~U[2026-11-06 16:00:00Z]
      ],
      extra
    )
  end

  test "session cap (L5) beats the project file and lists L3 as overridden" do
    {:ok, r} =
      Provenance.explain(
        "agent.max_concurrent_agents",
        opts(load_fun: files(%{@project => %{"agent" => %{"max_concurrent_agents" => 8}}}), session_cap_fun: fn -> 4 end)
      )

    assert %{value: 4, layer: "L5", overridden: [%{layer: "L3", value: 8, source: @project}]} = r
  end

  test "a key set nowhere prints the default with L0" do
    {:ok, r} = Provenance.explain("max_vertical_panes", opts([]))
    assert %{value: 3, layer: "L0", overridden: []} = r
  end

  test "override beats file; unavailable layers are named, never unset" do
    {:ok, r} =
      Provenance.explain(
        "agent.priority",
        opts(
          load_fun: files(%{@project => %{"agent" => %{"priority" => "a"}}}),
          overrides_fun: fn -> {:ok, [%{key: "agent.priority", value: "b"}]} end
        )
      )

    assert %{value: "b", layer: "L5", overridden: [%{layer: "L3", value: "a"}]} = r
    assert [%{layer: "L4", reason: "intent_store_not_implemented"}, %{layer: "L6"}] = r.unavailable
  end

  test "project file with the user file also present: L2 is unused, not overridden" do
    both = %{@project => %{"max_vertical_panes" => 5}, @user => %{"max_vertical_panes" => 7}}
    {:ok, r} = Provenance.explain("max_vertical_panes", opts(load_fun: files(both)))
    assert %{layer: "L3", value: 5, overridden: []} = r
  end

  test "user file owns the key when there is no project file" do
    {:ok, r} = Provenance.explain("max_vertical_panes", opts(load_fun: files(%{@user => %{"max_vertical_panes" => 7}})))
    assert %{layer: "L2", value: 7} = r
  end

  test "machine project cap wins over a higher file value" do
    machine = %Settings{projects: [%{repo: "o/a", config: @project, max_agents: 3}]}

    {:ok, r} =
      Provenance.explain(
        "agent.max_concurrent_agents",
        opts(
          project: "O/A",
          machine_fun: fn -> {:ok, machine} end,
          load_fun: files(%{@project => %{"agent" => %{"max_concurrent_agents" => 8}}})
        )
      )

    assert %{value: 3, layer: "L1", capped_by: "L1", overridden: [%{layer: "L3", value: 8}]} = r
  end

  test "secret keys print <redacted> in value and overridden" do
    sentinel = "sentinel-secret-value"

    {:ok, r} =
      Provenance.explain(
        "tracker.linear.api_key",
        opts(
          load_fun: files(%{@project => %{"tracker" => %{"linear" => %{"api_key" => sentinel}}}}),
          overrides_fun: fn -> {:ok, [%{key: "tracker.linear.api_key", value: sentinel <> "2"}]} end
        )
      )

    assert %{value: "<redacted>", overridden: [%{value: "<redacted>"}]} = r
    Aiur.TestSupport.refute_leak(r, sentinel)
  end

  test "unknown key suggests the near miss; unknown project lists configured ones" do
    assert {:error, {:unknown_key, _, ["agent.max_concurrent_agents" | _]}} =
             Provenance.explain("agent.max_concurent_agents", opts([]))

    machine = %Settings{projects: [%{repo: "o/a", config: @project, max_agents: nil}]}
    assert {:error, {:unknown_project, "o/zzz", ["o/a"]}} = Provenance.explain("max_vertical_panes", opts(project: "o/zzz", machine_fun: fn -> {:ok, machine} end))
  end

  test "a parent key redacts secret-named keys at any depth" do
    sentinel = "sentinel-parent-secret"
    file = %{"tracker" => %{"linear" => %{"api_key" => sentinel, "team" => "ENG"}}}

    {:ok, r} = Provenance.explain("tracker.linear", opts(load_fun: files(%{@project => file})))

    assert %{"api_key" => "<redacted>", "team" => "ENG"} = r.value
    Aiur.TestSupport.refute_leak(r, sentinel)
    {:ok, whole} = Provenance.explain("tracker", opts(load_fun: files(%{@project => file})))
    Aiur.TestSupport.refute_leak(whole, sentinel)
  end

  test "projects mode requires --project instead of reading the daemon cwd file" do
    machine = %Settings{projects: [%{repo: "o/a", config: "/a/config", max_agents: nil}, %{repo: "o/b", config: "/b/config", max_agents: nil}]}
    cwd_file = files(%{@project => %{"max_vertical_panes" => 9}})

    assert {:error, {:project_required, ["o/a", "o/b"]}} =
             Provenance.explain("max_vertical_panes", opts(machine_fun: fn -> {:ok, machine} end, load_fun: cwd_file))
  end

  test "--project selects that project's file and cap among several" do
    machine = %Settings{projects: [%{repo: "o/a", config: "/a/config", max_agents: 2}, %{repo: "o/b", config: "/b/config", max_agents: 3}]}

    loaded =
      files(%{
        "/a/config" => %{"agent" => %{"max_concurrent_agents" => 8}},
        "/b/config" => %{"agent" => %{"max_concurrent_agents" => 6}}
      })

    {:ok, r} = Provenance.explain("agent.max_concurrent_agents", opts(project: "o/b", machine_fun: fn -> {:ok, machine} end, load_fun: loaded))

    assert %{project: "o/b", value: 3, layer: "L1", overridden: [%{layer: "L3", value: 6, source: "/b/config"}]} = r
  end
end
