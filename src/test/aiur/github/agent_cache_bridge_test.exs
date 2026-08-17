defmodule Aiur.GitHub.AgentCacheBridgeTest do
  use Aiur.TestSupport
  @moduletag :tmp_dir

  alias Aiur.GitHub.{AgentCache, AgentCacheBridge, ResourceStore}

  setup %{tmp_dir: root} do
    state_dir = Path.join(root, "budget-state")
    File.mkdir_p!(state_dir)
    start_supervised!({AgentCacheBridge, name: :"bridge_#{System.unique_integer([:positive])}", state_dir: state_dir})

    {:ok, state_dir: state_dir}
  end

  defp marker(state_dir, key), do: Path.join(AgentCache.resource_dir(key, state_dir: state_dir), ".invalidated")

  defp await_marker(path, attempts \\ 100) do
    cond do
      File.exists?(path) -> true
      attempts <= 0 -> false
      true -> Process.sleep(10) && await_marker(path, attempts - 1)
    end
  end

  test "a resource deposited in the store retires the agents' copies of it", %{state_dir: state_dir} do
    key = ResourceStore.key(:pull_request, "owner", "repo", 1670)

    # The free pipe: something the daemon learned without an agent paying for it.
    :ok = ResourceStore.put_resource(key, %{"number" => 1670}, source: :webhook, version: "2026-08-17T00:00:00Z")

    assert await_marker(marker(state_dir, key))
  end

  test "a comment retires the repository's collections, since its parent is not derivable", %{state_dir: state_dir} do
    key = ResourceStore.key(:issue_comment, "owner", "repo", 99_001)
    :ok = ResourceStore.put_resource(key, %{"id" => 99_001}, source: :webhook, version: "2026-08-17T00:00:00Z")

    collections = Path.join([state_dir, "state-cache/v1/owner/repo", ".collections-invalidated"])
    assert await_marker(collections)
  end

  test "a repository spelled with capitals lands on the wrapper's one directory", %{state_dir: state_dir} do
    key = ResourceStore.key(:issue, "OWNER", "Repo", 42)
    :ok = ResourceStore.put_resource(key, %{"number" => 42}, source: :mutation, version: "2026-08-17T00:00:00Z")

    assert await_marker(Path.join([state_dir, "state-cache/v1/owner/repo/issue/42", ".invalidated"]))
  end

  test "an unwritable store leaves the daemon working", %{state_dir: state_dir} do
    File.rm_rf!(state_dir)
    File.write!(state_dir, "not a directory")

    key = ResourceStore.key(:pull_request, "owner", "repo", 1671)
    assert :ok = ResourceStore.put_resource(key, %{"number" => 1671}, source: :webhook, version: "v1")

    # The write still happened and nothing crashed; only the agents' hint is lost.
    assert {:ok, %{data: %{"number" => 1671}}} = ResourceStore.fetch(key)
  end
end
