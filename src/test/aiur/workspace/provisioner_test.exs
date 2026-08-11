defmodule Aiur.Workspace.ProvisionerTest do
  use Aiur.TestSupport

  alias Aiur.{Workflow, Workspace}
  alias Aiur.Workspace.Provisioner

  test "remote workers receive the bundled agent skill install script" do
    parent = self()

    runner = fn host, script, timeout ->
      send(parent, {:remote_install, host, script, timeout})
      {:ok, {"", 0}}
    end

    assert :ok = Provisioner.maybe_install_agent_support("/remote/workspace", "worker-1", runner)
    assert_received {:remote_install, "worker-1", script, timeout}
    assert is_integer(timeout) and timeout > 0
    assert script =~ ".claude/skills/design-import"
    assert script =~ "agents/openai.yaml"
    assert script =~ ".codex/skills/design-import"
    assert script =~ ~s(bin="$workspace/.aiur-runtime/bin")
    assert script =~ "for command_name in 'gh'"
    assert script =~ ~s(target="$bin/$command_name")
    assert script =~ "chmod 755"
    # Without a workspace-private scratch dir, remote agents fall back to the
    # worker's shared /tmp and clobber each other's staged files (#1763).
    assert script =~ ".aiur-runtime/tmp"
  end

  test "local workspaces get command guards and a private scratch directory" do
    workspace = Path.join(System.tmp_dir!(), "aiur-provision-scratch-#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(workspace) end)

    assert :ok = Provisioner.maybe_install_agent_support(workspace, nil)
    assert File.dir?(Path.join(workspace, ".aiur-runtime/tmp"))

    elixir_wrapper = Path.join(workspace, ".aiur-runtime/build-bin/elixir")
    mix_wrapper = Path.join(workspace, ".aiur-runtime/build-bin/mix")
    mise_wrapper = Path.join(workspace, ".aiur-runtime/build-bin/mise")
    assert File.regular?(elixir_wrapper)
    assert File.regular?(mix_wrapper)
    assert File.regular?(mise_wrapper)

    mix_inode = File.stat!(mix_wrapper).inode
    assert :ok = Provisioner.maybe_install_agent_support(workspace, nil)
    assert File.stat!(mix_wrapper).inode == mix_inode
  end

  test "remote support installation failures stop workspace preparation" do
    runner = fn _host, _script, _timeout -> {:ok, {"unsafe support path", 73}} end

    assert {:error, {:remote_agent_support_install_failed, {:ok, {"unsafe support path", 73}}}} =
             Provisioner.maybe_install_agent_support("/remote/workspace", "worker-1", runner)
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

  test "ensure_workspace/2 on a valid existing checkout returns false and preserves contents" do
    tmp = Path.join(System.tmp_dir!(), "prov_#{System.unique_integer([:positive])}")
    init_repo!(tmp)
    sentinel = Path.join(tmp, "sentinel.txt")
    File.write!(sentinel, "wip")

    on_exit(fn -> File.rm_rf!(tmp) end)

    assert {:ok, ^tmp, false} = Provisioner.ensure_workspace(tmp, nil)
    assert File.read!(sentinel) == "wip"
  end

  test "reports interrupted Git initialization as existing but refuses it for use" do
    workspace = Path.join(System.tmp_dir!(), "prov_unborn_#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)
    {_output, 0} = System.cmd("git", ["init", "--quiet", workspace], stderr_to_stdout: true)
    notes = Path.join(workspace, "notes.txt")
    File.write!(notes, "do not discard\n")

    on_exit(fn -> File.rm_rf!(workspace) end)

    assert {:ok, ^workspace, false} = Provisioner.ensure_workspace(workspace, nil)

    assert {:error, {:workspace_ambiguous, ^workspace, :invalid_git_checkout}} =
             Provisioner.ensure_workspace_usable(workspace, nil, false)

    assert File.read!(notes) == "do not discard\n"
  end

  test "refuses unproven non-Git contents without deleting them" do
    workspace = Path.join(System.tmp_dir!(), "prov_unproven_#{System.unique_integer([:positive])}")
    notes = Path.join(workspace, "notes.txt")
    File.mkdir_p!(workspace)
    File.write!(notes, "agent WIP\n")

    on_exit(fn -> File.rm_rf!(workspace) end)

    assert {:error, {:workspace_ambiguous, ^workspace, :unproven_contents}} =
             Provisioner.ensure_workspace(workspace, nil)

    assert File.read!(notes) == "agent WIP\n"
  end

  test "completion proof makes an intentionally non-Git workspace reusable" do
    workspace = Path.join(System.tmp_dir!(), "prov_ready_#{System.unique_integer([:positive])}")
    notes = Path.join(workspace, "notes.txt")
    File.mkdir_p!(workspace)
    File.write!(notes, "intentional non-git workspace\n")

    on_exit(fn -> File.rm_rf!(workspace) end)

    assert :ok = Provisioner.mark_workspace_ready(workspace, nil)
    assert {:ok, ^workspace, false} = Provisioner.ensure_workspace(workspace, nil)
    refute Provisioner.bootstrap_required?(workspace, nil, false)
    assert File.read!(notes) == "intentional non-git workspace\n"
  end

  test "partial agent-skill installation is not a non-Git completion proof" do
    workspace = Path.join(System.tmp_dir!(), "prov_partial_skills_#{System.unique_integer([:positive])}")
    skill = Path.join([workspace, ".claude", "skills", "using-aiur", "SKILL.md"])
    notes = Path.join(workspace, "notes.txt")
    File.mkdir_p!(Path.dirname(skill))
    File.write!(skill, "partial bootstrap\\n")
    File.write!(notes, "preserve this work\\n")

    on_exit(fn -> File.rm_rf!(workspace) end)

    assert {:error, {:workspace_ambiguous, ^workspace, :unproven_contents}} =
             Provisioner.ensure_workspace(workspace, nil)

    assert File.read!(skill) == "partial bootstrap\\n"
    assert File.read!(notes) == "preserve this work\\n"
  end

  test "refuses an after_create hook that leaves a logs-only workspace non-Git, then self-heals on retry" do
    test_root = Path.join(System.tmp_dir!(), "prov_completion_#{System.unique_integer([:positive])}")
    workspace_root = Path.join(test_root, "workspaces")

    on_exit(fn -> File.rm_rf!(test_root) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      hook_after_create: "printf initialized > README.md"
    )

    workspace = Workspace.workspace_path_under(workspace_root, "PROOF-1")
    log_path = Path.join([workspace, "logs", "agent.ndjson"])
    File.mkdir_p!(Path.dirname(log_path))
    File.write!(log_path, "{\"event\":\"startup\"}\n")

    assert {:error, {:workspace_ambiguous, ^workspace, :unproven_contents}} =
             Workspace.create_for_issue("PROOF-1")

    # #1317: a hook that exits 0 without producing a real checkout must not
    # leave a permanently stuck workspace behind for the next dispatch to
    # inherit — the failed attempt is torn down so a later provision can
    # start clean instead of hitting the same ambiguity forever.
    refute File.exists?(workspace)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      hook_after_create: """
      git init --quiet -b main .
      git config user.email test@example.com
      git config user.name "Test User"
      printf initialized > README.md
      git add README.md
      git commit --quiet -m init
      """
    )

    assert {:ok, ^workspace} = Workspace.create_for_issue("PROOF-1")
    assert File.exists?(Path.join(workspace, ".git"))
  end

  test "ensure_workspace/5 marks a logs-only directory for initial provisioning" do
    workspace = Path.join(System.tmp_dir!(), "prov_logs_only_#{System.unique_integer([:positive])}")
    log_path = Path.join([workspace, "logs", "agent.md"])
    File.mkdir_p!(Path.dirname(log_path))
    File.write!(log_path, "preserve this transcript\n")

    on_exit(fn -> File.rm_rf!(workspace) end)

    assert {:ok, ^workspace, true} =
             Provisioner.ensure_workspace(workspace, nil, nil, "aiur/123-workspace-recovery", nil)

    assert File.read!(log_path) == "preserve this transcript\n"
  end

  test "remote setup refuses a logs-only workspace before a provider can receive its cwd" do
    test_root = Path.join(System.tmp_dir!(), "prov_remote_logs_#{System.unique_integer([:positive])}")
    workspace = Path.join(test_root, "workspace")
    log_path = Path.join([workspace, "logs", "agent.md"])
    fake_ssh = Path.join(test_root, "ssh")
    previous_path = System.get_env("PATH")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      File.rm_rf!(test_root)
    end)

    File.mkdir_p!(Path.dirname(log_path))
    File.write!(log_path, "preserve this transcript\n")
    File.write!(fake_ssh, "#!/bin/sh\nshift 2\nexec sh -lc \"$1\"\n")
    File.chmod!(fake_ssh, 0o755)
    System.put_env("PATH", test_root <> ":" <> (previous_path || ""))

    assert {:error, {:workspace_prepare_failed, "worker-1", 65, _output}} =
             Provisioner.ensure_workspace(workspace, "worker-1")

    assert File.read!(log_path) == "preserve this transcript\n"
  end

  test "refuses a logs-only workspace whose logs node is not a safe directory" do
    workspace = Path.join(System.tmp_dir!(), "prov_invalid_logs_#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)
    File.write!(Path.join(workspace, "logs"), "not a directory")

    on_exit(fn -> File.rm_rf!(workspace) end)

    assert {:error, {:workspace_ambiguous, ^workspace, :unproven_contents}} =
             Provisioner.ensure_workspace(workspace, nil, nil, "aiur/invalid-logs", nil)
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
