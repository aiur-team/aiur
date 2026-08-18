defmodule Aiur.GitHub.AgentCacheTest do
  use ExUnit.Case, async: true
  @moduletag :tmp_dir

  alias Aiur.GitHub.AgentCache

  setup %{tmp_dir: root} do
    {:ok, opts: [state_dir: root], root: Path.join(root, "state-cache/v1")}
  end

  test "the root matches the path the gh wrapper derives", %{opts: opts, root: root} do
    # The wrapper computes `$AIUR_GITHUB_BUDGET_ROOT/state-cache/v1`. If these
    # two ever drift the daemon marks resources no agent is reading, and the
    # cache silently stops honouring free webhook writes.
    assert AgentCache.root(opts) == root
  end

  test "invalidating a resource marks both number spaces and the collections", %{opts: opts, root: root} do
    assert :ok = AgentCache.invalidate("aiur-team/aiur", 2073, opts)

    assert File.exists?(Path.join(root, "aiur-team/aiur/pr/2073/.invalidated"))
    assert File.exists?(Path.join(root, "aiur-team/aiur/issue/2073/.invalidated"))
    assert File.exists?(Path.join(root, "aiur-team/aiur/.collections-invalidated"))
  end

  test "a marker holds a unix second an entry can be compared against", %{opts: opts, root: root} do
    before = System.system_time(:second)
    assert :ok = AgentCache.invalidate("aiur-team/aiur", "2073", opts)

    marked =
      Path.join(root, "aiur-team/aiur/pr/2073/.invalidated")
      |> File.read!()
      |> String.trim()
      |> String.to_integer()

    assert marked >= before
    assert marked <= System.system_time(:second)
  end

  test "collection invalidation leaves individual resources alone", %{opts: opts, root: root} do
    assert :ok = AgentCache.invalidate_collections("aiur-team/aiur", opts)

    assert File.exists?(Path.join(root, "aiur-team/aiur/.collections-invalidated"))
    refute File.exists?(Path.join(root, "aiur-team/aiur/pr"))
  end

  test "repository invalidation retires every read of the repo", %{opts: opts, root: root} do
    assert :ok = AgentCache.invalidate_repo("aiur-team/aiur", opts)

    assert File.exists?(Path.join(root, "aiur-team/aiur/.invalidated"))
  end

  # Owner and repo segments arrive from webhook payloads, so they are
  # attacker-influenced input to a filesystem write.
  test "a traversal or malformed identity writes nothing", %{opts: opts, root: root} do
    assert :ok = AgentCache.invalidate("../..", 1, opts)
    assert :ok = AgentCache.invalidate("aiur-team/../../escape", 1, opts)
    assert :ok = AgentCache.invalidate("aiur-team/", 1, opts)
    assert :ok = AgentCache.invalidate("aiur", 1, opts)
    assert :ok = AgentCache.invalidate_repo("a/b/c", opts)

    refute File.exists?(root)
  end

  test "a number that is not a positive integer writes nothing", %{opts: opts, root: root} do
    assert :ok = AgentCache.invalidate("aiur-team/aiur", "not-a-number", opts)
    assert :ok = AgentCache.invalidate("aiur-team/aiur", 0, opts)
    assert :ok = AgentCache.invalidate("aiur-team/aiur", "12abc", opts)

    refute File.exists?(Path.join(root, "aiur-team/aiur/pr"))
  end

  test "an unwritable store never fails the caller", %{opts: opts} do
    blocked = Path.join(Keyword.fetch!(opts, :state_dir), "blocked")
    File.write!(blocked, "not a directory")

    assert :ok = AgentCache.invalidate("aiur-team/aiur", 2073, state_dir: blocked)
    assert :ok = AgentCache.invalidate_repo("aiur-team/aiur", state_dir: blocked)
  end
end
