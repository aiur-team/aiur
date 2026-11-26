defmodule Aiur.Orchestrator.ProjectPauseTest do
  use Aiur.TwoProjectsCase, async: false

  alias Aiur.Gateway
  alias Aiur.Project.Pause

  defp flag_file(%Project{state_root: root}), do: Path.join(root, "global-pause.json")

  test "pausing project A leaves project B dispatching", %{a: a, b: b} do
    refute dispatch_paused?(a)
    refute dispatch_paused?(b)

    assert {:ok, %{globally_paused: true}} = Pause.set("O/A", true, "test")

    assert dispatch_paused?(a)
    refute dispatch_paused?(b)
    assert {:ok, %{"globally_paused" => true}} = Aiur.JsonStore.read(flag_file(a))
    refute File.exists?(flag_file(b))
  end

  test "a project pause survives its orchestrator restarting, and resume clears only that project", %{a: a, b: b} do
    {:ok, _} = Pause.set("o/a", true, "test")
    {:ok, _} = Pause.set("o/b", true, "test")
    old = orchestrator(a)
    Process.exit(old, :kill)
    eventually(fn -> (pid = orchestrator(a)) && pid != old && is_pid(pid) end)
    assert dispatch_paused?(a)

    assert {:ok, %{globally_paused: false}} = Pause.set("o/a", false, "test")
    refute dispatch_paused?(a)
    assert dispatch_paused?(b)
  end

  test "unknown projects are refused" do
    assert {:error, {:unknown_project, "o/zzz"}} = Pause.set("O/ZZZ", true, "test")
  end

  test "a gateway pause stops every project, persists, and leaves project flags alone", %{a: a, b: b} do
    {:ok, _} = Pause.set("o/b", true, "test")
    assert {:ok, _} = Gateway.Pause.set(true, "test")

    eventually(fn -> orchestrator_state(a).gateway_paused and orchestrator_state(b).gateway_paused end)
    assert dispatch_paused?(a)
    assert dispatch_paused?(b)
    assert {:ok, path} = Gateway.Pause.path()
    assert {:ok, %{"globally_paused" => true}} = Aiur.JsonStore.read(path)
    refute File.exists?(flag_file(a))

    assert {:ok, _} = Gateway.Pause.set(false, "test")
    eventually(fn -> not dispatch_paused?(a) end)
    # B's own pause is still on: resuming the gateway did not clear it.
    assert dispatch_paused?(b)
  end

  test "a gateway pause holds across a restart, and an unreadable file holds paused", %{a: a} do
    {:ok, _} = Gateway.Pause.set(true, "test")
    restart(a)
    assert orchestrator_state(a).gateway_paused

    {:ok, _} = Gateway.Pause.set(false, "test")
    {:ok, path} = Gateway.Pause.path()
    File.write!(path, "{")
    restart(a)
    assert orchestrator_state(a).gateway_paused
  end

  test "with no gateway file a project is not paused", %{a: a} do
    refute orchestrator_state(a).gateway_paused
  end

  defp restart(project) do
    old = orchestrator(project)
    Process.exit(old, :kill)
    eventually(fn -> (pid = orchestrator(project)) && pid != old && is_pid(pid) end)
    # Wait for init to finish.
    orchestrator_state(project)
  end
end
