defmodule Aiur.GitHub.AgentCacheBridgeTest do
  use Aiur.TestSupport
  @moduletag :tmp_dir

  alias Aiur.Events.Exchange
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

  # A comment is deposited alongside the issue or pull request it hangs off — see
  # `Aiur.Events.GithubWebhook.Deposit.bodies/2`, where every comment and review
  # branch also deposits its parent. So the parent is retired by its own key, and
  # acting on the comment as well would only retire the repository's collection
  # queries on top. A busy repository sees a comment every few seconds, so that
  # would flush every cached `pr list` continuously to duplicate work already
  # done.
  test "a comment alone retires nothing, because its parent is deposited with it", %{state_dir: state_dir} do
    comment = ResourceStore.key(:issue_comment, "owner", "repo", 99_001)
    :ok = ResourceStore.put_resource(comment, %{"id" => 99_001}, source: :webhook, version: "v1")

    Process.sleep(120)
    refute File.exists?(Path.join([state_dir, "state-cache/v1/owner/repo", ".collections-invalidated"]))

    # The same delivery's issue deposit is what does the retiring.
    issue = ResourceStore.key(:issue, "owner", "repo", 1670)
    :ok = ResourceStore.put_resource(issue, %{"number" => 1670}, source: :webhook, version: "v1")

    assert await_marker(marker(state_dir, issue))
  end

  test "a check run retires nothing, because a verdict is never served", %{state_dir: state_dir} do
    key = ResourceStore.key(:check_run, "owner", "repo", 55_501)
    :ok = ResourceStore.put_resource(key, %{"id" => 55_501, "conclusion" => "success"}, source: :webhook, version: "v1")

    Process.sleep(120)
    refute File.exists?(Path.join([state_dir, "state-cache/v1/owner/repo", ".collections-invalidated"]))
    refute File.exists?(Path.join([state_dir, "state-cache/v1/owner/repo", ".invalidated"]))
  end

  test "a validator re-recorded by a poll retires nothing", %{state_dir: state_dir} do
    # These publish twice a dispatch tick. Nobody's answer is wrong because an
    # `ETag` moved.
    for type <- [:repo_issue_comment_stream, :repo_review_comment_stream, :issue_comments] do
      :ok = ResourceStore.put_etag(ResourceStore.key(type, "owner", "repo", "stream"), "etag-#{type}")
    end

    Process.sleep(120)
    refute File.exists?(Path.join([state_dir, "state-cache/v1/owner/repo", ".collections-invalidated"]))
  end

  test "a label set retires the number it belongs to", %{state_dir: state_dir} do
    key = ResourceStore.key(:issue_labels, "owner", "repo", 1670)
    :ok = ResourceStore.put_resource(key, [%{"name" => "agent:todo"}], source: :webhook, version: "v1")

    assert await_marker(Path.join([state_dir, "state-cache/v1/owner/repo/issue/1670", ".invalidated"]))
    assert await_marker(Path.join([state_dir, "state-cache/v1/owner/repo/pr/1670", ".invalidated"]))
  end

  # The change event a deposit publishes is the one wake channel that does not
  # pass through `Aiur.Events.Publisher`'s bot filter. This process is the only
  # subscriber, so this is the assertion that keeps it from becoming a new door
  # into the `bot_account` self-loop: it writes marker files and publishes
  # nothing at all.
  test "handling a deposit never publishes an event", %{state_dir: state_dir} do
    :ok = Exchange.subscribe("ticket.*")
    :ok = Exchange.subscribe("system.*")

    key = ResourceStore.key(:pull_request, "owner", "repo", 1670)
    :ok = ResourceStore.put_resource(key, %{"number" => 1670}, source: :webhook, version: "v1")

    assert await_marker(marker(state_dir, key))
    refute_receive {:event, _event}, 200
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
