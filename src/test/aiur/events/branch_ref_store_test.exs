defmodule Aiur.Events.BranchRefStoreTest do
  use ExUnit.Case, async: true

  alias Aiur.Events.BranchRefStore

  test "reloads the latest validated refs before consumers start" do
    path = Path.join(System.tmp_dir!(), "branch-refs-#{System.unique_integer([:positive])}.json")
    ref = "refs/heads/aiur/99-dependency"
    sha = String.duplicate("a", 40)

    on_exit(fn -> File.rm(path) end)

    {:ok, first} = BranchRefStore.start_link(name: nil, path: path)
    assert :ok = BranchRefStore.record(ref, sha, first)
    GenServer.stop(first)

    {:ok, restarted} = BranchRefStore.start_link(name: nil, path: path)
    assert BranchRefStore.latest("99", restarted) == %{ref: ref, sha: sha}

    GenServer.stop(restarted)
  end
end
