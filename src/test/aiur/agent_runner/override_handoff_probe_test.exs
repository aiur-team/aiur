defmodule Aiur.AgentRunner.OverrideHandoffProbeTest do
  use ExUnit.Case, async: true

  alias Aiur.AgentRunner.OverrideHandoff
  alias Aiur.TestGit

  test "reads the pushed checkout head, upstream and commit date in an escaped path" do
    root = Aiur.TestSupport.tmp_root!("worker handoff's checkout")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)
    origin = Path.join(root, "origin")
    checkout = Path.join(root, "checkout space")
    File.mkdir_p!(origin)
    File.mkdir_p!(checkout)
    git!(origin, ["init", "--bare"])
    git!(checkout, ["init", "-b", "work"])
    git!(checkout, ["config", "user.name", "Fixture"])
    git!(checkout, ["config", "user.email", "fixture@example.test"])
    git!(checkout, ["commit", "--allow-empty", "-m", "Worker change"])
    git!(checkout, ["remote", "add", "origin", origin])
    git!(checkout, ["push", "--set-upstream", "origin", "work"])
    head = git!(checkout, ["rev-parse", "HEAD"])
    {:ok, at, _} = checkout |> git!(["log", "-1", "--format=%cI", head]) |> DateTime.from_iso8601()
    assert {:ok, %{head_sha: ^head, upstream_sha: ^head, committed_at: ^at}} = OverrideHandoff.read_head(checkout, nil)
    git!(checkout, ["commit", "--allow-empty", "-m", "Not pushed"])
    unpushed = git!(checkout, ["rev-parse", "HEAD"])
    assert {:ok, %{head_sha: ^unpushed, upstream_sha: ^head}} = OverrideHandoff.read_head(checkout, nil)
  end

  defp git!(workspace, args) do
    {output, status} = TestGit.cmd(["-C", workspace | args])
    assert status == 0, output
    String.trim(output)
  end
end
