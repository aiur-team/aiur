defmodule Aiur.WorkspaceMaterializeTest do
  use ExUnit.Case, async: true

  alias Aiur.Workspace

  setup do
    tmp = Path.join(System.tmp_dir!(), "aiur_ws_#{System.unique_integer([:positive])}")
    base = Path.join(tmp, "base")
    File.mkdir_p!(base)

    git!(["init", "--quiet", "-b", "main", base])
    git!(["-C", base, "config", "user.email", "t@example.com"])
    git!(["-C", base, "config", "user.name", "T"])
    File.write!(Path.join(base, "README.md"), "v1\n")
    File.write!(Path.join(base, ".gitignore"), "_build/\n")
    git!(["-C", base, "add", "."])
    git!(["-C", base, "commit", "--quiet", "-m", "init"])

    # Warm build artifacts: gitignored, present in the working tree — these are
    # exactly what the copy must carry so the agent skips the recompile.
    File.mkdir_p!(Path.join(base, "_build"))
    File.write!(Path.join(base, "_build/sentinel"), "warm\n")

    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, tmp: tmp, base: base}
  end

  test "copies the warm base (incl. gitignored _build) and branches aiur/<id>", %{
    tmp: tmp,
    base: base
  } do
    workspace = Path.join(tmp, "123")

    assert :ok = Workspace.materialize_from_base(base, workspace)

    assert File.read!(Path.join(workspace, "README.md")) == "v1\n"

    assert File.exists?(Path.join(workspace, "_build/sentinel")),
           "warm _build artifacts were not carried"

    assert branch(workspace) == "aiur/123"
  end

  test "copies the warm base onto the generated ticket branch", %{tmp: tmp, base: base} do
    workspace = Path.join(tmp, "123")

    assert :ok =
             Workspace.materialize_from_base(base, workspace, "aiur/123-add-new-test-cases", nil)

    assert branch(workspace) == "aiur/123-add-new-test-cases"
  end

  # Characterization: pins the legacy 2-arity contract so the PR-anchored
  # variant below provably leaves it untouched. The branch MUST be `aiur/<id>`
  # and never the human-PR-style prefix the new path produces.
  test "legacy materialize_from_base/2 always branches aiur/<id> (no PR-anchored leakage)", %{
    tmp: tmp,
    base: base
  } do
    workspace = Path.join(tmp, "456")

    assert :ok = Workspace.materialize_from_base(base, workspace)

    assert branch(workspace) == "aiur/456"
    refute branch(workspace) =~ ~r{\Apr-}
  end

  test "PR-anchored materialize fetches + checks out the PR head ref (not aiur/<id>)", %{tmp: tmp} do
    # A bare origin holds the human PR's existing branch `feature/login`. The
    # PR-anchored materialize must fetch and check out THAT branch, not create
    # `aiur/<id>`.
    origin = Path.join(tmp, "origin.git")
    git!(["init", "--quiet", "--bare", "-b", "main", origin])

    seed = Path.join(tmp, "seed")
    git!(["clone", "--quiet", origin, seed])
    git!(["-C", seed, "config", "user.email", "t@example.com"])
    git!(["-C", seed, "config", "user.name", "T"])
    File.write!(Path.join(seed, "README.md"), "main\n")
    git!(["-C", seed, "add", "."])
    git!(["-C", seed, "commit", "--quiet", "-m", "main"])
    git!(["-C", seed, "push", "--quiet", "origin", "main"])

    # The human's PR branch, pushed to origin.
    git!(["-C", seed, "checkout", "--quiet", "-b", "feature/login"])
    File.write!(Path.join(seed, "login.txt"), "human work\n")
    git!(["-C", seed, "add", "."])
    git!(["-C", seed, "commit", "--quiet", "-m", "add login"])
    git!(["-C", seed, "push", "--quiet", "origin", "feature/login"])
    pr_tip = String.trim(git!(["-C", seed, "rev-parse", "HEAD"]))

    # Warm base = clone of origin (on main) with gitignored warm _build.
    base = Path.join(tmp, "prbase")
    git!(["clone", "--quiet", origin, base])
    File.mkdir_p!(Path.join(base, "_build"))
    File.write!(Path.join(base, "_build/sentinel"), "warm\n")

    workspace = Path.join(tmp, "pr-77")
    assert :ok = Workspace.materialize_from_base(base, workspace, "feature/login")

    assert branch(workspace) == "feature/login",
           "PR-anchored materialize did not check out the PR head ref"

    refute File.dir?(Path.join([workspace, ".git", "refs", "heads", "aiur"])),
           "PR-anchored materialize created an aiur/<id> branch"

    assert String.trim(git!(["-C", workspace, "rev-parse", "HEAD"])) == pr_tip,
           "workspace is not on the PR head tip"

    assert File.read!(Path.join(workspace, "login.txt")) == "human work\n"
    assert File.exists?(Path.join(workspace, "_build/sentinel")), "warm _build was not carried"
  end

  test "PR-anchored materialize falls back to a local branch when origin has no such ref", %{
    tmp: tmp,
    base: base
  } do
    # The base setup has no usable remote for `feature/x`; materialize still
    # succeeds on a local branch off the copied HEAD so the agent can work.
    workspace = Path.join(tmp, "pr-88")

    assert :ok = Workspace.materialize_from_base(base, workspace, "feature/x")

    assert branch(workspace) == "feature/x"
    refute branch(workspace) =~ ~r{\Aaiur/}
  end

  test "materialized workspaces expose writable git metadata and repair stale locks", %{
    tmp: tmp,
    base: base
  } do
    workspace = Path.join(tmp, "561")

    assert :ok = Workspace.materialize_from_base(base, workspace)

    stale_locks = [
      Path.join([workspace, ".git", "index.lock"]),
      Path.join([workspace, ".git", "FETCH_HEAD.lock"]),
      Path.join([workspace, ".git", "ORIG_HEAD.lock"]),
      Path.join([workspace, ".git", "refs", "remotes", "origin", "aiur", "561.lock"])
    ]

    Enum.each(stale_locks, fn lock ->
      File.mkdir_p!(Path.dirname(lock))
      File.write!(lock, "stale\n")
    end)

    assert :ok = Workspace.ensure_git_metadata_writable(workspace)
    assert Enum.all?(stale_locks, &(not File.exists?(&1)))
  end

  test "returns an error (cold-clone fallback) when the base is not copyable", %{tmp: tmp} do
    assert {:error, _} =
             Workspace.materialize_from_base(Path.join(tmp, "nope"), Path.join(tmp, "ws"))
  end

  test "branches off the live origin tip, not the stale warm-base HEAD (#567)", %{tmp: tmp} do
    # A bare origin advances to v2 AFTER the warm base was cloned at v1, mirroring
    # the staleness window where a merge lands but the warm base hasn't refetched.
    origin = Path.join(tmp, "origin.git")
    git!(["init", "--quiet", "--bare", "-b", "main", origin])

    seed = Path.join(tmp, "seed")
    git!(["clone", "--quiet", origin, seed])
    git!(["-C", seed, "config", "user.email", "t@example.com"])
    git!(["-C", seed, "config", "user.name", "T"])
    File.write!(Path.join(seed, "README.md"), "v1\n")
    git!(["-C", seed, "add", "."])
    git!(["-C", seed, "commit", "--quiet", "-m", "v1"])
    git!(["-C", seed, "push", "--quiet", "origin", "main"])

    # Warm base = clone of origin pinned at v1, with gitignored warm _build.
    base = Path.join(tmp, "freshbase")
    git!(["clone", "--quiet", origin, base])
    File.mkdir_p!(Path.join(base, "_build"))
    File.write!(Path.join(base, "_build/sentinel"), "warm\n")

    # origin advances to v2 — the merge the stale base never fetched.
    File.write!(Path.join(seed, "README.md"), "v2\n")
    git!(["-C", seed, "commit", "--quiet", "-am", "v2"])
    git!(["-C", seed, "push", "--quiet", "origin", "main"])
    v2 = String.trim(git!(["-C", seed, "rev-parse", "HEAD"]))

    workspace = Path.join(tmp, "777")
    assert :ok = Workspace.materialize_from_base(base, workspace)

    assert branch(workspace) == "aiur/777"

    assert String.trim(git!(["-C", workspace, "rev-parse", "HEAD"])) == v2,
           "workspace branched off the stale base HEAD instead of live origin/main (#567)"

    assert File.read!(Path.join(workspace, "README.md")) == "v2\n"
    assert File.exists?(Path.join(workspace, "_build/sentinel")), "warm _build was not carried"
  end

  defp git!(args) do
    {out, 0} = System.cmd("git", args, stderr_to_stdout: true)
    out
  end

  defp branch(workspace) do
    {out, 0} =
      System.cmd("git", ["-C", workspace, "rev-parse", "--abbrev-ref", "HEAD"], stderr_to_stdout: true)

    String.trim(out)
  end
end
