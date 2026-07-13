defmodule Aiur.Workspace.ProvisionerTest do
  use Aiur.TestSupport

  alias Aiur.Workflow
  alias Aiur.Workspace.Provisioner

  test "remote workers receive the bundled agent skill install script" do
    parent = self()

    runner = fn host, script, timeout ->
      send(parent, {:remote_install, host, script, timeout})
      {:ok, {"", 0}}
    end

    assert :ok = Provisioner.maybe_install_agent_skills("/remote/workspace", "worker-1", runner)
    assert_received {:remote_install, "worker-1", script, timeout}
    assert is_integer(timeout) and timeout > 0
    assert script =~ ".claude/skills/design-import"
    assert script =~ "agents/openai.yaml"
    assert script =~ ".codex/skills/design-import"
  end

  test "parse_remote_workspace_output/1 with valid marker line returns ok tuple" do
    noise = "some\npreamble\n"
    marker_line = "__AIUR_WORKSPACE__\t1\t/resolved/path\n"
    output = noise <> marker_line <> "more noise\n"

    assert {:ok, "/resolved/path", true} = Provisioner.parse_remote_workspace_output(output)
  end

  test "parse_remote_workspace_output/1 with created=0 returns created? false" do
    output = "noise\n__AIUR_WORKSPACE__\t0\t/some/path\nmore\n"

    assert {:ok, "/some/path", false} = Provisioner.parse_remote_workspace_output(output)
  end

  test "parse_remote_workspace_output/1 with malformed output returns error" do
    bad = "no marker here at all\nfoo\nbar\n"

    assert {:error, {:workspace_prepare_failed, :invalid_output, _}} =
             Provisioner.parse_remote_workspace_output(bad)
  end

  test "parse_remote_workspace_output/1 with wrong field count returns error" do
    # Only 2 fields instead of 3
    bad = "__AIUR_WORKSPACE__\t1\n"

    assert {:error, {:workspace_prepare_failed, :invalid_output, _}} =
             Provisioner.parse_remote_workspace_output(bad)
  end

  test "ensure_workspace/2 on an existing directory returns false and preserves contents" do
    tmp = Path.join(System.tmp_dir!(), "prov_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    sentinel = Path.join(tmp, "sentinel.txt")
    File.write!(sentinel, "wip")

    on_exit(fn -> File.rm_rf!(tmp) end)

    assert {:ok, ^tmp, false} = Provisioner.ensure_workspace(tmp, nil)
    assert File.read!(sentinel) == "wip"
  end

  test "ensure_workspace/2 on a stale plain file replaces it and returns created? true" do
    test_root = Path.join(System.tmp_dir!(), "prov_stale_#{System.unique_integer([:positive])}")
    workspace_root = Path.join(test_root, "workspaces")
    File.mkdir_p!(workspace_root)

    on_exit(fn -> File.rm_rf!(test_root) end)

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    # Put a plain file where a workspace directory is expected
    workspace = Path.join(workspace_root, "stale-file-ws")
    File.write!(workspace, "stale data")

    assert {:ok, ^workspace, true} = Provisioner.ensure_workspace(workspace, nil)
    assert File.dir?(workspace)
  end

  test "resolve_branch_name/3 resumes the checked-out branch after a title edit" do
    root = Path.join(System.tmp_dir!(), "provisioner-branch-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "123")
    File.mkdir_p!(root)
    init_repo!(workspace)
    git!(["-C", workspace, "checkout", "--quiet", "-b", "aiur/123-fix-login"])

    on_exit(fn -> File.rm_rf!(root) end)

    context = ticket_context("aiur/123-fix-login-and-signup")

    assert Provisioner.resolve_branch_name(workspace, context, fn _ticket_id ->
             flunk("a checked-out ticket branch must win over a fresh title slug")
           end) == "aiur/123-fix-login"
  end

  test "resolve_branch_name/3 resumes an open PR head after a deleted workspace" do
    workspace = Path.join(System.tmp_dir!(), "missing-#{System.unique_integer([:positive])}")
    context = ticket_context("aiur/123-fix-login-and-signup")

    assert Provisioner.resolve_branch_name(workspace, context, fn ticket_id ->
             assert ticket_id == "123"
             {:ok, %{"head" => %{"ref" => "aiur/123-fix-login"}}}
           end) == "aiur/123-fix-login"
  end

  defp ticket_context(branch_name) do
    %{
      issue_id: "issue-123",
      issue_identifier: "123",
      issue_state: "rework",
      issue_labels: ["agent:rework"],
      pr_head_ref: nil,
      branch_name: branch_name
    }
  end

  defp init_repo!(repo) do
    File.mkdir_p!(repo)
    git!(["init", "--quiet", "-b", "main", repo])
    git!(["-C", repo, "config", "user.email", "t@example.com"])
    git!(["-C", repo, "config", "user.name", "T"])
    File.write!(Path.join(repo, "README.md"), "initial\n")
    git!(["-C", repo, "add", "."])
    git!(["-C", repo, "commit", "--quiet", "-m", "initial"])
  end

  defp git!(args) do
    {out, 0} = System.cmd("git", args, stderr_to_stdout: true)
    out
  end
end
