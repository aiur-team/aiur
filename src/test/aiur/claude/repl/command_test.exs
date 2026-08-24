defmodule Aiur.Claude.Repl.CommandTest do
  use ExUnit.Case, async: true

  alias Aiur.Claude.RemoteControl
  alias Aiur.Claude.Repl.Command

  describe "build_command/7" do
    test "composes cd, token scrub, environment export, and exec in one success chain" do
      cmd = Command.build_command("/ws/foo", nil, nil, false, "rc-name", nil, nil)
      assert String.starts_with?(cmd, "cd '/ws/foo' && {")
      assert cmd =~ "${HEX_HOME#\\~/}"
      assert cmd =~ "AIUR_CI_READINESS_TOKEN"
      # Assert the glob arms individually: the case arm grows as credential
      # families are added, so matching its whole literal makes every future
      # addition look like a regression here.
      assert cmd =~ "*_API_KEY|"
      # #2356: the raw GitHub credential families join the case arm after the
      # App prefix; assert each arm individually so future families stay covered.
      assert cmd =~ "GITHUB_APP_*|"
      assert cmd =~ "GITHUB_TOKEN|GH_TOKEN|GH_ENTERPRISE_TOKEN|GITHUB_ENTERPRISE_TOKEN|MISE_GITHUB_TOKEN) unset "
      assert cmd =~ "export HEX_HOME"
      assert cmd =~ "AIUR_BUILD_GATE_BIN='/ws/foo/.aiur-runtime/build-bin'"
      assert cmd =~ "BASH_ENV="
      assert cmd =~ "AIUR_BUILD_GATE_SLOTS='2'"
      assert cmd =~ " && exec claude"

      {scrub_pos, _len} = :binary.match(cmd, "unset ")
      {exec_pos, _len} = :binary.match(cmd, "exec claude")
      assert scrub_pos < exec_pos
    end

    test "a failed workspace cd cannot launch Claude or retain the operator token" do
      root = Aiur.TestSupport.tmp_root!("aiur-claude-command")
      bin = Path.join(root, "bin")
      missing_workspace = Path.join(root, "missing")
      File.mkdir_p!(bin)

      claude = Path.join(bin, "claude")

      File.write!(
        claude,
        "#!/usr/bin/env bash\nprintf 'CLAUDE_RAN token=%s\\n' \"${AIUR_CI_READINESS_TOKEN-unset}\"\n"
      )

      File.chmod!(claude, 0o755)
      on_exit(fn -> File.rm_rf!(root) end)

      command = Command.build_command(missing_workspace, nil, nil, false, "rc-name", nil, nil)

      {output, status} =
        System.cmd("bash", ["-c", command],
          env: [
            {"PATH", bin <> ":" <> System.get_env("PATH", "")},
            {"AIUR_CI_READINESS_TOKEN", "operator-only"}
          ],
          stderr_to_stdout: true
        )

      assert status != 0
      refute output =~ "CLAUDE_RAN"
      refute output =~ "operator-only"
    end

    test "scrubs inherited provider credentials before launching the agent" do
      cmd = Command.build_command("/ws/foo", nil, nil, false, "rc-name", nil, nil)

      assert cmd =~ "OPENROUTER_MANAGEMENT_KEY"
      # Assert the glob arms individually: the case arm grows as credential
      # families are added, so matching its whole literal makes every future
      # addition look like a regression here.
      assert cmd =~ "*_API_KEY|"
      # #2356: the raw GitHub credential families join the case arm after the
      # App prefix; assert each arm individually so future families stay covered.
      assert cmd =~ "GITHUB_APP_*|"
      assert cmd =~ "GITHUB_TOKEN|GH_TOKEN|GH_ENTERPRISE_TOKEN|GITHUB_ENTERPRISE_TOKEN|MISE_GITHUB_TOKEN) unset "

      {scrub_pos, _len} = :binary.match(cmd, "unset ")
      {exec_pos, _len} = :binary.match(cmd, "exec claude")
      assert scrub_pos < exec_pos
    end

    test "exports the authoritative base branch into the tmux-backed process" do
      cmd = Command.build_command("/ws/foo", nil, nil, false, "rc-name", nil, nil, base_branch: "integration")

      assert cmd =~ "AIUR_BASE_BRANCH='integration'"
      assert cmd =~ " && exec claude"
    end

    test "flag order: --remote-control, --resume, --permission-mode (always), --model, --effort, --settings" do
      cmd = Command.build_command("/ws", "claude-opus-4-8", "max", true, "rc", "/tmp/s.json", "sess-abc")

      rc_pos = :binary.match(cmd, "--remote-control") |> elem(0)
      resume_pos = :binary.match(cmd, "--resume") |> elem(0)
      perm_pos = :binary.match(cmd, "--permission-mode") |> elem(0)
      model_pos = :binary.match(cmd, "--model") |> elem(0)
      effort_pos = :binary.match(cmd, "--effort") |> elem(0)
      settings_pos = :binary.match(cmd, "--settings") |> elem(0)

      assert rc_pos < resume_pos
      assert resume_pos < perm_pos
      assert perm_pos < model_pos
      assert model_pos < effort_pos
      assert effort_pos < settings_pos
    end

    test "--permission-mode always present even without model/effort/rc" do
      cmd = Command.build_command("/ws", nil, nil, false, "rc", nil, nil)
      assert String.contains?(cmd, "--permission-mode")
      refute String.contains?(cmd, "--model")
      refute String.contains?(cmd, "--effort")
      refute String.contains?(cmd, "--remote-control")
      refute String.contains?(cmd, "--resume")
      refute String.contains?(cmd, "--settings")
    end

    test "single-quote shell escaping of a value containing a single quote" do
      cmd = Command.build_command("/tmp/foo's path", nil, nil, false, "rc", nil, nil)
      assert String.contains?(cmd, "'/tmp/foo'\\''s path'")
    end

    test "single-quote shell escaping of the configured base branch" do
      cmd = Command.build_command("/ws", nil, nil, false, "rc", nil, nil, base_branch: "release's-next")
      assert cmd =~ "AIUR_BASE_BRANCH='release'\"'\"'s-next'"
    end

    test "omits --model when nil" do
      cmd = Command.build_command("/ws", nil, nil, false, "rc", nil, nil)
      refute String.contains?(cmd, "--model")
    end
  end

  describe "resume_session_id/2" do
    setup do
      dir = Aiur.TestSupport.tmp_root!("cmd-resume")
      on_exit(fn -> File.rm_rf(dir) end)
      %{projects_dir: dir, workspace: "/ws/aiur/613"}
    end

    test "returns the id when its transcript exists on disk", %{projects_dir: dir, workspace: ws} do
      sid = "sess-xyz"
      slug_dir = Path.join(dir, RemoteControl.workspace_slug(ws))
      File.mkdir_p!(slug_dir)
      File.write!(Path.join(slug_dir, sid <> ".jsonl"), "{}\n")

      assert Command.resume_session_id([resume_thread_id: sid, projects_dir: dir], ws) == sid
    end

    test "returns nil when the transcript is gone", %{projects_dir: dir, workspace: ws} do
      assert Command.resume_session_id([resume_thread_id: "gone", projects_dir: dir], ws) == nil
    end

    test "returns nil with blank handle", %{projects_dir: dir, workspace: ws} do
      assert Command.resume_session_id([resume_thread_id: "", projects_dir: dir], ws) == nil
    end

    test "returns nil with nil handle", %{projects_dir: dir, workspace: ws} do
      assert Command.resume_session_id([resume_thread_id: nil, projects_dir: dir], ws) == nil
    end

    test "returns nil with no resume_thread_id key", %{projects_dir: dir, workspace: ws} do
      assert Command.resume_session_id([projects_dir: dir], ws) == nil
    end
  end

  describe "maybe_hook_settings/2" do
    test "returns nil for non-RC (false)" do
      assert Command.maybe_hook_settings(false, "some-identifier") == nil
    end

    test "returns nil for RC with nil identifier" do
      assert Command.maybe_hook_settings(true, nil) == nil
    end

    test "does not raise regardless of whether the dashboard is running" do
      # dashboard_url may or may not return a URL depending on the test environment.
      # The function must degrade gracefully either way — no exception.
      result = Command.maybe_hook_settings(true, "test-identifier")
      assert is_nil(result) or is_binary(result)
    end
  end
end
