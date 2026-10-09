defmodule Aiur.GitHub.TrackerBlockedByTest do
  use Aiur.TestSupport
  alias Aiur.GitHub.{ResourceStore, Tracker}

  @token_key {Aiur.GitHub.Config, :resolved_token}

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo")
    previous = :persistent_term.get(@token_key, :unset)
    :persistent_term.put(@token_key, nil)
    ResourceStore.reset()

    on_exit(fn ->
      ResourceStore.reset()
      if previous == :unset, do: :persistent_term.erase(@token_key), else: :persistent_term.put(@token_key, previous)
    end)

    :ok
  end

  test "fresh held edges succeed without credentials or a request" do
    put_blockers([%{"number" => 3, "state" => "open", "repository_url" => "https://api.github.com/repos/owner/repo"}])
    assert Tracker.blocked_by("77") == {:ok, ["3"]}
    assert Aiur.Tracker.blocked_by("77") == {:ok, ["3"]}
    assert Tracker.blocked_by("unheld") == {:error, :missing_github_token}
  end

  test "external and malformed edges cannot become local issue numbers" do
    put_blockers([%{"number" => 3, "state" => "open", "repository_url" => "https://api.github.com/repos/other/repo"}])
    assert Tracker.blocked_by("77") == {:error, :external_edge}
    put_blockers([%{"number" => 3, "state" => "open"}])
    assert Tracker.blocked_by("77") == {:error, :invalid_native_edge}
  end

  test "empty edge lists succeed and unsupported tracker facade fails closed" do
    put_blockers([])
    assert Tracker.blocked_by("77") == {:ok, []}
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear")
    assert Aiur.Tracker.blocked_by("77") == {:error, :unsupported}
  end

  defp put_blockers(blockers) do
    ResourceStore.put_resource(ResourceStore.key(:issue_blocked_by, "owner", "repo", "77"), blockers, source: :fetch)

    for blocker <- blockers do
      repo = if blocker["repository_url"] == "https://api.github.com/repos/other/repo", do: "other", else: "owner"
      ResourceStore.put_resource(ResourceStore.key(:issue, repo, "repo", "3"), blocker, source: :fetch)
    end
  end
end
