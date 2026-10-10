defmodule Aiur.TestResetTest do
  use ExUnit.Case, async: false

  alias Aiur.TestReset
  alias ExUnit.CaptureIO
  alias Mix.Tasks.Aiur.Test.Reset, as: ResetTask

  setup do
    tmp_dir = Aiur.TestSupport.tmp_root!("aiur_test_reset")
    File.mkdir_p!(tmp_dir)

    previous_agent_workspace = System.get_env("AIUR_AGENT_WORKSPACE")
    previous_agent_ir_sandbox = System.get_env("AIUR_AGENT_IR_SANDBOX")
    System.delete_env("AIUR_AGENT_WORKSPACE")
    System.delete_env("AIUR_AGENT_IR_SANDBOX")

    on_exit(fn ->
      File.rm_rf!(tmp_dir)
      restore_system_env("AIUR_AGENT_WORKSPACE", previous_agent_workspace)
      restore_system_env("AIUR_AGENT_IR_SANDBOX", previous_agent_ir_sandbox)
    end)

    %{tmp_dir: tmp_dir}
  end

  defp with_env(overrides, fun) do
    previous = Map.new(overrides, fn {key, _value} -> {key, System.get_env(key)} end)

    Enum.each(overrides, fn
      {key, nil} -> System.delete_env(key)
      {key, value} -> System.put_env(key, value)
    end)

    try do
      fun.()
    after
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end
  end

  defp restore_system_env(key, nil), do: System.delete_env(key)
  defp restore_system_env(key, value), do: System.put_env(key, value)

  defp write_reset_fixture!(tmp, tickets \\ [101, 102, 103]) do
    File.mkdir_p!(Path.join(tmp, "src/lib/aiur/sandbox"))

    {_, 0} = System.cmd("git", ["init"], cd: tmp, stderr_to_stdout: true)
    {_, 0} = System.cmd("git", ["config", "user.email", "t@example.com"], cd: tmp)
    {_, 0} = System.cmd("git", ["config", "user.name", "Test"], cd: tmp)

    for name <- [
          "event_flow_demo.ex",
          "event_flow_unrelated_1.ex",
          "event_flow_unrelated_2.ex",
          "event_flow_unrelated_3.ex"
        ] do
      File.write!(Path.join([tmp, "src/lib/aiur/sandbox", name]), "defmodule X do\nend\n")
    end

    File.write!(Path.join(tmp, ".aiur-test-tickets.json"), Jason.encode!(%{"tickets" => tickets}))

    {_, 0} = System.cmd("git", ["add", "."], cd: tmp)
    {_, 0} = System.cmd("git", ["commit", "-m", "baseline"], cd: tmp)
  end

  test "Mix reset from src uses repo-local config for workspace layout", %{tmp_dir: tmp_dir} do
    write_reset_fixture!(tmp_dir, [2897])
    repo_config = Path.join([tmp_dir, ".aiur", "config"])
    global_config = Path.join(tmp_dir, "global-config")
    local_root = Path.join(tmp_dir, "local-workspaces")
    global_root = Path.join(tmp_dir, "global-workspaces")
    File.mkdir_p!(Path.dirname(repo_config))

    Aiur.TestSupport.write_workflow_file!(repo_config,
      tracker_kind: "github",
      tracker_repo: "aiur-team/aiur",
      workspace_root: local_root
    )

    Aiur.TestSupport.write_workflow_file!(global_config,
      tracker_kind: "github",
      tracker_repo: "other/repo",
      workspace_root: global_root
    )

    previous_config = Aiur.Workflow.workflow_file_path()

    try do
      Aiur.Workflow.set_workflow_file_path(global_config)

      output =
        File.cd!(Path.join(tmp_dir, "src"), fn ->
          CaptureIO.capture_io(:stderr, fn ->
            assert :ok = ResetTask.run(["--force", "--allow-remote"])
          end)
        end)

      assert output =~ "--test DRY-RUN"
      assert output =~ "2897"
      assert Aiur.Workflow.workflow_file_path() == repo_config
      assert Aiur.Config.workspace_root() == local_root
    after
      Aiur.Workflow.set_workflow_file_path(previous_config)
    end
  end

  test "reset removes the repo-namespaced workspace for the ticket", %{tmp_dir: tmp_dir} do
    root = Path.join(tmp_dir, "workspaces")
    config_path = Path.join(tmp_dir, "config")
    previous_config_path = Aiur.Workflow.workflow_file_path()

    Aiur.TestSupport.write_workflow_file!(config_path,
      tracker_kind: "github",
      tracker_repo: "owner/repo",
      workspace_root: root
    )

    Aiur.Workflow.set_workflow_file_path(config_path)

    ticket_workspace = Path.join([root, "owner", "repo", "2897"])
    other_workspace = Path.join([root, "owner", "repo", "2898"])
    old_layout_workspace = Path.join(root, "2897")

    try do
      for path <- [ticket_workspace, other_workspace, old_layout_workspace] do
        File.mkdir_p!(path)
        File.write!(Path.join(path, "agent-edit.txt"), "uncommitted work")
      end

      TestReset.remove_workspace(2897, root)

      refute File.exists?(ticket_workspace)
      assert File.exists?(Path.join(other_workspace, "agent-edit.txt"))
      assert File.exists?(Path.join(old_layout_workspace, "agent-edit.txt"))
    after
      Aiur.Workflow.set_workflow_file_path(previous_config_path)
    end
  end

  test "reset falls back to a flat workspace path with invalid config", %{tmp_dir: tmp_dir} do
    root = Path.join(tmp_dir, "workspaces")
    workspace = Path.join(root, "2897")
    invalid_config_path = Path.join(tmp_dir, "invalid-config")
    previous_config_path = Aiur.Workflow.workflow_file_path()
    File.mkdir_p!(workspace)
    File.write!(Path.join(workspace, "agent-edit.txt"), "uncommitted work")
    File.write!(invalid_config_path, "tracker: [not valid yaml")

    try do
      Aiur.Workflow.set_workflow_file_path(invalid_config_path)
      assert_raise ArgumentError, fn -> Aiur.Config.settings!() end
      TestReset.remove_workspace(2897, root)
      refute File.exists?(workspace)
    after
      Aiur.Workflow.set_workflow_file_path(previous_config_path)
    end
  end

  describe "guards" do
    test "ABORT: tickets file missing", %{tmp_dir: tmp_dir} do
      assert {:error, :tickets_file_missing} =
               TestReset.run(%{repo_root: tmp_dir, confirm: false})
    end

    test "ABORT: tickets file with empty tickets list", %{tmp_dir: tmp_dir} do
      File.write!(
        Path.join(tmp_dir, ".aiur-test-tickets.json"),
        ~s({"tickets": [], "expected_remote": "x"})
      )

      assert {:error, :no_tickets_pinned} =
               TestReset.run(%{repo_root: tmp_dir, confirm: false})
    end

    test "ABORT: non-integer ticket ids", %{tmp_dir: tmp_dir} do
      File.write!(
        Path.join(tmp_dir, ".aiur-test-tickets.json"),
        ~s({"tickets": ["../etc/passwd"], "expected_remote": "x"})
      )

      assert {:error, {:invalid_ticket_ids, _}} =
               TestReset.run(%{repo_root: tmp_dir, confirm: false})
    end

    test "ABORT: dirty working tree without --force" do
      # Use a temp git repo with uncommitted changes
      tmp = Aiur.TestSupport.tmp_root!("aiur_test_repo")
      File.mkdir_p!(tmp)

      {_, 0} = System.cmd("git", ["init"], cd: tmp, stderr_to_stdout: true)
      {_, 0} = System.cmd("git", ["config", "user.email", "t@example.com"], cd: tmp)
      {_, 0} = System.cmd("git", ["config", "user.name", "Test"], cd: tmp)
      File.write!(Path.join(tmp, "README.md"), "stub\n")
      {_, 0} = System.cmd("git", ["add", "."], cd: tmp)
      {_, 0} = System.cmd("git", ["commit", "-m", "init"], cd: tmp)

      # Make working tree dirty
      File.write!(Path.join(tmp, "README.md"), "changed\n")

      File.write!(
        Path.join(tmp, ".aiur-test-tickets.json"),
        ~s({"tickets": [101]})
      )

      original_cwd = File.cwd!()
      File.cd!(tmp)

      try do
        assert {:error, :dirty_working_tree} = TestReset.run(%{repo_root: tmp, confirm: false})
      after
        File.cd!(original_cwd)
        File.rm_rf!(tmp)
      end
    end

    test "ABORT: direct reset from agent workspace env marker remains blocked", %{tmp_dir: tmp_dir} do
      write_reset_fixture!(tmp_dir)

      with_env(
        [
          {"AIUR_AGENT_WORKSPACE", "/tmp/aiur-workspaces/repo/334"},
          {"AIUR_AGENT_IR_SANDBOX", nil}
        ],
        fn ->
          assert {:error, :agent_workspace_blocked} =
                   TestReset.run(%{repo_root: tmp_dir, confirm: false, allow_remote: true})
        end
      )
    end

    test "agent IR sandbox marker allows reset guard to proceed", %{tmp_dir: tmp_dir} do
      write_reset_fixture!(tmp_dir)

      with_env(
        [
          {"AIUR_AGENT_WORKSPACE", "/tmp/aiur-workspaces/repo/334"},
          {"AIUR_AGENT_IR_SANDBOX", "1"}
        ],
        fn ->
          assert :ok = TestReset.run(%{repo_root: tmp_dir, confirm: false, allow_remote: true})
        end
      )
    end

    test "ABORT: direct reset from aiur-workspaces repo path remains blocked" do
      tmp =
        Path.join([
          System.tmp_dir!(),
          "aiur-workspaces",
          "repo",
          Aiur.TestSupport.tmp_root!("direct-reset")
        ])

      File.mkdir_p!(tmp)
      write_reset_fixture!(tmp)

      try do
        with_env(
          [
            {"AIUR_AGENT_WORKSPACE", nil},
            {"AIUR_AGENT_IR_SANDBOX", nil}
          ],
          fn ->
            assert {:error, :agent_workspace_blocked} =
                     TestReset.run(%{repo_root: tmp, confirm: false, allow_remote: true})
          end
        )
      after
        File.rm_rf!(Path.join(System.tmp_dir!(), "aiur-workspaces"))
      end
    end
  end

  describe "dry-run output" do
    test "dry-run with valid tickets returns :ok, no side effects" do
      # Synthesize a fully-baked repo: git-init, commit sandbox baselines,
      # write tickets file, then run dry-run.
      tmp = Aiur.TestSupport.tmp_root!("aiur_dry")
      File.mkdir_p!(Path.join(tmp, "src/lib/aiur/sandbox"))

      {_, 0} = System.cmd("git", ["init"], cd: tmp, stderr_to_stdout: true)
      {_, 0} = System.cmd("git", ["config", "user.email", "t@example.com"], cd: tmp)
      {_, 0} = System.cmd("git", ["config", "user.name", "Test"], cd: tmp)

      for name <- [
            "event_flow_demo.ex",
            "event_flow_unrelated_1.ex",
            "event_flow_unrelated_2.ex",
            "event_flow_unrelated_3.ex"
          ] do
        File.write!(Path.join([tmp, "src/lib/aiur/sandbox", name]), "defmodule X do\nend\n")
      end

      File.write!(
        Path.join(tmp, ".aiur-test-tickets.json"),
        ~s({"tickets": [101, 102, 103]})
      )

      {_, 0} = System.cmd("git", ["add", "."], cd: tmp)
      {_, 0} = System.cmd("git", ["commit", "-m", "baseline"], cd: tmp)

      try do
        assert :ok =
                 TestReset.run(%{
                   repo_root: tmp,
                   confirm: false,
                   allow_remote: true
                 })
      after
        File.rm_rf!(tmp)
      end
    end

    test "single dry-run returns :ok and resets only the first ticket, no side effects" do
      tmp = Aiur.TestSupport.tmp_root!("aiur_single")
      File.mkdir_p!(Path.join(tmp, "src/lib/aiur/sandbox"))

      {_, 0} = System.cmd("git", ["init"], cd: tmp, stderr_to_stdout: true)
      {_, 0} = System.cmd("git", ["config", "user.email", "t@example.com"], cd: tmp)
      {_, 0} = System.cmd("git", ["config", "user.name", "Test"], cd: tmp)

      for name <- [
            "event_flow_demo.ex",
            "event_flow_unrelated_1.ex",
            "event_flow_unrelated_2.ex",
            "event_flow_unrelated_3.ex"
          ] do
        File.write!(Path.join([tmp, "src/lib/aiur/sandbox", name]), "defmodule X do\nend\n")
      end

      File.write!(Path.join(tmp, ".aiur-test-tickets.json"), ~s({"tickets": [99, 100, 101]}))

      {_, 0} = System.cmd("git", ["add", "."], cd: tmp)
      {_, 0} = System.cmd("git", ["commit", "-m", "baseline"], cd: tmp)

      try do
        output =
          ExUnit.CaptureIO.capture_io(:stderr, fn ->
            assert :ok =
                     TestReset.run(%{
                       repo_root: tmp,
                       confirm: false,
                       single: true,
                       allow_remote: true
                     })
          end)

        assert output =~ "--test DRY-RUN"
        # Single mode narrows the blocker chain to the first ticket only.
        assert output =~ "- 99"
        refute output =~ "- 100"
        refute output =~ "- 101"
      after
        File.rm_rf!(tmp)
      end
    end
  end
end
