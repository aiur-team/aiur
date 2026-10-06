defmodule Aiur.Workspace.LayoutTest do
  use Aiur.TestSupport

  alias Aiur.AlertFeed
  alias Aiur.Workspace.Layout

  test "origin-resolved GitHub repository namespaces omitted-repo workspaces" do
    root = tmp_path("layout-global-root")
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: nil, workspace_root: root)
    cache_origin_repo("owner/repo")

    assert Layout.issue_workspace_path(root, "17") == Path.join([root, "owner", "repo", "17"])
    assert Layout.issue_workspace_path(Path.join([root, "owner", "repo"]), "17") == Path.join([root, "owner", "repo", "17"])
  end

  test "origin-resolved alert backfill excludes sibling repositories including same-number tickets" do
    root = tmp_path("layout-global-alerts")
    ledger = Path.join(root, "current.alerts.ndjson")
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: nil, workspace_root: root)
    cache_origin_repo("owner/repo")

    for {repo, ticket, message} <- [{"repo", "17", "current repository"}, {"other", "1674", "foreign ticket"}, {"other", "17", "foreign same-number ticket"}] do
      path = Path.join([root, "owner", repo, ticket, "logs", "agent.ndjson"])
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, Jason.encode!(%{event: "alert", topic: "ticket.#{ticket}.agent.paused", message: message, needs_attention: true}) <> "\n")
    end

    project_root = root |> Layout.issue_workspace_path("__aiur_attention_probe__") |> Path.dirname()
    assert :ok = AlertFeed.backfill(roots: [project_root], log_roots: [], ledger_path: ledger)
    assert [alert] = AlertFeed.list(ledger_paths: [ledger], needs_attention: true)
    assert alert["source_ticket_id"] == "17"
    assert alert["message"] == "current repository"
  end

  test "issue_workspace_path nests the github owner repo segment" do
    root = tmp_path("layout-github-root")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "owner/repo",
      workspace_root: root
    )

    assert Layout.issue_workspace_path(root, "123") == Path.join([root, "owner", "repo", "123"])
  end

  test "issue_workspace_path does not append an already present repo segment" do
    root = tmp_path("layout-github-root")
    namespaced_root = Path.join([root, "owner", "repo"])

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "owner/repo",
      workspace_root: namespaced_root
    )

    assert Layout.issue_workspace_path(namespaced_root, "123") == Path.join(namespaced_root, "123")
  end

  test "issue_workspace_path is flat for memory tracker" do
    root = tmp_path("layout-memory-root")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: root
    )

    assert Layout.issue_workspace_path(root, "123") == Path.join(root, "123")
  end

  test "safe_identifier maps disallowed characters and nil" do
    assert Layout.safe_identifier("a/b c:@") == "a_b_c__"
    assert Layout.safe_identifier(nil) == "issue"
  end

  test "local validate_workspace_path rejects root itself and paths outside root" do
    root = tmp_path("layout-validate-root")
    outside = tmp_path("layout-outside")
    File.mkdir_p!(root)
    File.mkdir_p!(outside)

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: root)

    assert {:error, {:workspace_equals_root, _, _}} = Layout.validate_workspace_path(root, nil)
    assert {:error, {:workspace_outside_root, _, _}} = Layout.validate_workspace_path(outside, nil)
  end

  test "remote validate_workspace_path rejects empty and invalid characters" do
    assert {:error, {:workspace_path_unreadable, "", :empty}} =
             Layout.validate_workspace_path("", "worker")

    assert {:error, {:workspace_path_unreadable, "bad\npath", :invalid_characters}} =
             Layout.validate_workspace_path("bad\npath", "worker")

    assert {:error, {:workspace_path_unreadable, "bad" <> <<0>> <> "path", :invalid_characters}} =
             Layout.validate_workspace_path("bad" <> <<0>> <> "path", "worker")
  end

  test "pr_anchored_workspace? only accepts pr prefixed leaves" do
    assert Layout.pr_anchored_workspace?("/tmp/workspaces/pr-77")
    refute Layout.pr_anchored_workspace?("/tmp/workspaces/77")
    refute Layout.pr_anchored_workspace?("/tmp/workspaces/not-pr-77")
  end

  defp tmp_path(name) do
    Aiur.TestSupport.tmp_root!("#{name}")
  end

  defp cache_origin_repo(repo) do
    key = {Aiur.GitHub.Config, :resolved_origin_repo}
    previous = :persistent_term.get(key, :not_cached)
    :persistent_term.put(key, repo)

    on_exit(fn ->
      if previous == :not_cached, do: :persistent_term.erase(key), else: :persistent_term.put(key, previous)
    end)
  end
end
