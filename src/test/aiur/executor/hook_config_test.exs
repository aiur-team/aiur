defmodule Aiur.Executor.HookConfigTest do
  use ExUnit.Case, async: false
  alias Aiur.Executor.{HookConfig, HookSettingsBackup, HookToken}

  setup do
    root = Aiur.TestSupport.tmp_root!("executor hooks ' quoted")
    previous = Application.fetch_env(:aiur, :executor_state_dir)
    key = System.get_env("AIUR_INSTANCE_KEY")
    Application.put_env(:aiur, :executor_state_dir, Path.join(root, "state"))
    System.put_env("AIUR_INSTANCE_KEY", "hook-config-test")

    on_exit(fn ->
      if previous == :error, do: Application.delete_env(:aiur, :executor_state_dir), else: Application.put_env(:aiur, :executor_state_dir, elem(previous, 1))
      if key, do: System.put_env("AIUR_INSTANCE_KEY", key), else: System.delete_env("AIUR_INSTANCE_KEY")
      Aiur.TestCleanup.rm_rf!(root)
    end)

    %{root: root, path: Path.join([root, ".claude", "settings.local.json"])}
  end

  test "event sets, rendering and extra hooks match each harness" do
    extra = %{event: "Stop", command: "AIUR_EXECUTOR_HOOK=1 deliver", timeout: 5}
    claude = HookConfig.entries(:claude, [extra])
    assert Enum.sort(Map.keys(claude)) == Enum.sort(~w(SessionStart UserPromptSubmit PostToolUse Stop StopFailure SubagentStart SubagentStop Notification SessionEnd TaskCreated TaskCompleted))
    assert Enum.sort(Map.keys(HookConfig.entries(:codex))) == Enum.sort(~w(SessionStart UserPromptSubmit PostToolUse Stop SubagentStart SubagentStop SessionEnd))
    assert [_, %{"hooks" => [%{"command" => "AIUR_EXECUTOR_HOOK=1 deliver", "timeout" => 5}]}] = claude["Stop"]
    assert Jason.decode!(HookConfig.render(:claude, extra_entries: [extra])) == %{"hooks" => claude}
    codex = HookConfig.render(:codex)
    assert codex =~ "<repo>/.codex/hooks.json"
    assert codex =~ "trust"
    assert codex =~ "harness=codex"
    assert HookConfig.install(:codex, repo_root: "/unused") == {:error, :print_only}
  end

  test "command reads private paths at invocation, forwards stdin, stays silent and exits zero", %{root: root} do
    assert :ok = HookToken.ensure()
    {:ok, token} = HookToken.read()
    command = get_in(HookConfig.entries(:claude), ["Stop", Access.at(0), "hooks", Access.at(0), "command"])
    refute command =~ token
    assert command =~ "-H @"
    assert command =~ "-m 2"
    assert System.cmd("sh", ["-c", command], stderr_to_stdout: true) == {"", 0}
    bin = Path.join(root, "bin")
    File.mkdir_p!(bin)
    curl = Path.join(bin, "curl")
    capture = Path.join(root, "capture")
    File.write!(curl, "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$CAPTURE\"\ncat >> \"$CAPTURE\"\necho noisy\necho error >&2\nexit 7\n")
    File.chmod!(curl, 0o700)

    for port <- [12_345, 23_456] do
      assert :ok = HookConfig.write_url(port)
      assert Bitwise.band(File.stat!(HookConfig.url_path()).mode, 0o777) == 0o600
      assert System.cmd("sh", ["-c", "printf payload | " <> command], env: [{"PATH", bin <> ":" <> System.get_env("PATH")}, {"CAPTURE", capture}], stderr_to_stdout: true) == {"", 0}
      args = File.read!(capture)
      assert args =~ "http://127.0.0.1:#{port}/api/v1/executor/hook?harness=claude"
      assert args =~ "@" <> HookToken.headers_path()
      assert args =~ "payload"
    end
  end

  test "install twice preserves user settings, backs up bytes and supports later extra hooks", %{path: path, root: root} do
    user = %{"matcher" => "Bash", "hooks" => [%{"type" => "command", "command" => "echo user"}]}
    original = Jason.encode!(%{"permissions" => %{"allow" => ["Read"]}, "hooks" => %{"Stop" => [user]}})
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, original)
    assert :ok = HookConfig.install(:claude, repo_root: root)
    first = File.read!(path)
    assert :ok = HookConfig.install(:claude, repo_root: root)
    assert File.read!(path) == first
    assert [backup] = Path.wildcard(Path.join(HookSettingsBackup.backup_dir(), "settings.local.json.aiur-bak-*"))
    assert File.read!(backup) == original
    extra = %{event: "Stop", command: "AIUR_EXECUTOR_HOOK=1 deliver", timeout: 5}
    assert :ok = HookConfig.install(:claude, repo_root: root, extra_entries: [extra])
    assert :ok = HookConfig.install(:claude, repo_root: root, extra_entries: [extra])
    settings = Jason.decode!(File.read!(path))
    assert settings["permissions"] == %{"allow" => ["Read"]}
    assert [^user, _, %{"hooks" => [%{"command" => "AIUR_EXECUTOR_HOOK=1 deliver", "timeout" => 5, "type" => "command"}]}] = settings["hooks"]["Stop"]
    assert :ok = HookConfig.uninstall(repo_root: root)
    assert Jason.decode!(File.read!(path)) == Jason.decode!(original)
    assert File.read!(path) == original
    assert File.exists?(backup)
  end

  # Future-regression guard: scope preservation already works; this is not coverage for a production change in this rework.
  test "install and uninstall preserve user, shared-project and outside settings byte-for-byte", %{root: root} do
    home = Path.join(root, "home")
    project = Path.join(root, "project")
    previous_home = System.get_env("HOME")
    System.put_env("HOME", home)
    on_exit(fn -> if previous_home, do: System.put_env("HOME", previous_home), else: System.delete_env("HOME") end)

    untouched = [
      {Path.join([home, ".claude", "settings.json"]), "{ \"env\" : {\"USER_SETTING\":\"keep\"} }\n\n"},
      {Path.join([project, ".claude", "settings.json"]), "{\n  \"permissions\" : { \"allow\" : [\"Read\"] }\n}\n"},
      {Path.join(root, "outside.json"), "{\"outside\" : true}\n "}
    ]

    for {path, original} <- untouched do
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, original)
    end

    assert :ok = HookConfig.install(:claude, repo_root: project)
    local_path = Path.join([project, ".claude", "settings.local.json"])
    installed = Jason.decode!(File.read!(local_path))
    command = get_in(installed, ["hooks", "SessionStart", Access.at(0), "hooks", Access.at(0), "command"])
    assert String.starts_with?(command, "AIUR_EXECUTOR_HOOK=1")
    for {path, original} <- untouched, do: assert(File.read!(path) == original)

    assert :ok = HookConfig.uninstall(repo_root: project)
    assert Jason.decode!(File.read!(local_path)) == %{}
    for {path, original} <- untouched, do: assert(File.read!(path) == original)
  end

  test "uninstall removes individual marked commands while retaining mixed user groups", %{path: path, root: root} do
    user = %{"type" => "command", "command" => "echo AIUR_EXECUTOR_HOOK=1"}
    group = %{"matcher" => "*", "hooks" => [user, %{"command" => "AIUR_EXECUTOR_HOOK=1 sh -c true"}]}
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(%{"hooks" => %{"Stop" => [group], "SessionEnd" => [%{"hooks" => [%{"command" => "AIUR_EXECUTOR_HOOK=1 true"}]}]}}))
    assert :ok = HookConfig.uninstall(repo_root: root)
    assert Jason.decode!(File.read!(path)) == %{"hooks" => %{"Stop" => [%{"matcher" => "*", "hooks" => [user]}]}}
  end

  test "an existing ownership marker prevents duplicate lifecycle entries", %{path: path, root: root} do
    old = %{"hooks" => [%{"command" => "AIUR_EXECUTOR_HOOK=1 old-command"}]}
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(%{"hooks" => %{"Stop" => [old]}}))
    extra = %{event: "Stop", command: "AIUR_EXECUTOR_HOOK=1 deliver", timeout: 5}
    assert :ok = HookConfig.install(:claude, repo_root: root, extra_entries: [extra])
    assert [^old, %{"hooks" => [%{"command" => "AIUR_EXECUTOR_HOOK=1 deliver", "timeout" => 5, "type" => "command"}]}] = Jason.decode!(File.read!(path))["hooks"]["Stop"]
  end

  test "invalid JSON and hook shapes are never overwritten", %{path: path, root: root} do
    File.mkdir_p!(Path.dirname(path))

    for original <- ["{bad", "[]", ~s({"hooks":null}), ~s({"hooks":{"Stop":{}}})] do
      File.write!(path, original)
      assert HookConfig.install(:claude, repo_root: root) == {:error, :unparsable}
      assert HookConfig.uninstall(repo_root: root) == {:error, :unparsable}
      assert File.read!(path) == original
      assert Path.wildcard(Path.join(HookSettingsBackup.backup_dir(), "settings.local.json.aiur-bak-*")) == []
    end
  end

  test "absent settings and filesystem errors leave other files untouched", %{root: root, path: path} do
    assert :ok = HookConfig.uninstall(repo_root: root)
    refute File.exists?(path)
    assert :ok = HookConfig.install(:claude, repo_root: root)
    assert map_size(Jason.decode!(File.read!(path))["hooks"]) == 11
    assert :ok = HookConfig.uninstall(repo_root: root)
    assert Jason.decode!(File.read!(path)) == %{}
    bad_root = Path.join(root, "regular-file")
    File.write!(bad_root, "untouched")
    assert {:error, :enotdir} = HookConfig.install(:claude, repo_root: bad_root)
    assert File.read!(bad_root) == "untouched"
  end
end
