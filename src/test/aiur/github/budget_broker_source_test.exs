defmodule Aiur.GitHub.BudgetBrokerSourceTest do
  use ExUnit.Case, async: true

  alias Aiur.AgentGitHubGuard
  alias Aiur.GitHub.{Budget, BudgetBrokerSource}

  @moduletag :tmp_dir

  test "assembled broker equals the pre-split github_budget.py", %{tmp_dir: root} do
    # Pinned to the broker blob at main 61b3b853f002a2211fd3720849407954e3d9b63c.
    assert Base.encode16(:crypto.hash(:sha256, BudgetBrokerSource.text()), case: :lower) ==
             "abad07c169ebbb2363d3c7dae009d6ebd41fe3e971278a21a66d08db490e6ad1"

    assert :ok = AgentGitHubGuard.install(root)
    assert File.read!(AgentGitHubGuard.budget_broker_path(root)) == BudgetBrokerSource.text()
    path = BudgetBrokerSource.install!(root)
    assert {"", 0} = System.cmd("python3", ["-m", "py_compile", path])
  end

  test "daemon broker runs from installed priv, independently of writable state", %{tmp_dir: root} do
    path = Budget.broker_path(state_dir: root)
    assert path == Application.app_dir(:aiur, "priv/github_budget.py")
    assert File.read!(path) == BudgetBrokerSource.text()
    refute File.exists?(Path.join(root, "bin"))
    File.mkdir_p!(Path.join(root, "bin"))
    File.write!(Path.join([root, "bin", "github_budget_metrics.py"]), "raise RuntimeError('agent-written code')")

    # Exercise the build artifact and its installed metrics dependency.
    assert {output, 0} = System.cmd("python3", [path, "snapshot", "--db", Path.join(root, "budget.sqlite3"), "--token-key", "test"])
    assert Jason.decode!(output) == %{"cooldown_until_ms" => 0, "inflight" => %{}, "admissions" => []}
  end

  test "build installation preserves identical artifacts", %{tmp_dir: root} do
    path = BudgetBrokerSource.install!(root)
    assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o755
    File.touch!(path, {{2000, 1, 1}, {0, 0, 0}})
    before = File.stat!(path)
    assert BudgetBrokerSource.install!(root) == path
    assert File.stat!(path).mtime == before.mtime
    assert File.stat!(path).inode == before.inode
  end

  test "concurrent installs replace stale bytes atomically", %{tmp_dir: root} do
    path = BudgetBrokerSource.install!(root)
    File.write!(path, "stale")
    previous = Path.join(root, "previous-broker")
    File.ln!(path, previous)

    results = 1..8 |> Task.async_stream(fn _ -> BudgetBrokerSource.install!(root) end, max_concurrency: 4) |> Enum.to_list()
    assert results == List.duplicate({:ok, path}, 8)
    assert File.read!(previous) == "stale"
    assert File.read!(path) == BudgetBrokerSource.text()
    assert Enum.sort(File.ls!(root)) == ["github_budget.py", "previous-broker"]
  end

  test "unavailable build destination fails assembly", %{tmp_dir: root} do
    File.mkdir_p!(root)
    file = Path.join(root, "not-a-directory")
    File.write!(file, "occupied")
    assert_raise File.Error, fn -> BudgetBrokerSource.install!(file) end
  end
end
