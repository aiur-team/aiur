defmodule Aiur.Executor.HookSettingsBackupTest do
  use ExUnit.Case, async: false

  alias Aiur.Executor.{HookConfig, HookSettingsBackup}

  setup do
    root = Aiur.TestSupport.tmp_root!("executor-hook-backup")
    previous_dir = Application.fetch_env(:aiur, :executor_state_dir)
    previous_key = System.get_env("AIUR_INSTANCE_KEY")
    Application.put_env(:aiur, :executor_state_dir, Path.join(root, "state"))
    System.put_env("AIUR_INSTANCE_KEY", "hook-settings-backup-test")

    on_exit(fn ->
      if previous_dir == :error, do: Application.delete_env(:aiur, :executor_state_dir), else: Application.put_env(:aiur, :executor_state_dir, elem(previous_dir, 1))
      if previous_key, do: System.put_env("AIUR_INSTANCE_KEY", previous_key), else: System.delete_env("AIUR_INSTANCE_KEY")
      Aiur.TestCleanup.rm_rf!(root)
    end)

    %{root: root}
  end

  test "install keeps its backup private and out of git status", %{root: root} do
    repo = init_repo(root)
    settings_path = Path.join([repo, ".claude", "settings.local.json"])
    File.mkdir_p!(Path.dirname(settings_path))
    File.write!(settings_path, ~s({"permissions":{"allow":["Read"]}}))

    assert :ok = HookConfig.install(:claude, repo_root: repo)
    assert {"", 0} = System.cmd("git", ["status", "--porcelain"], cd: repo)

    backup_dir = HookSettingsBackup.backup_dir()
    assert {:ok, %{type: :directory, mode: mode}} = File.stat(backup_dir)
    assert Bitwise.band(mode, 0o777) == 0o700
    assert [backup] = Path.wildcard(Path.join(backup_dir, "settings.local.json.aiur-bak-*"))
    assert {:ok, %{type: :regular, mode: backup_mode}} = File.stat(backup)
    assert Bitwise.band(backup_mode, 0o777) == 0o600
    assert File.read!(backup) == ~s({"permissions":{"allow":["Read"]}})
  end

  test "uninstall migrates a legacy backup and removes it only after verification", %{root: root} do
    repo = init_repo(root)
    legacy = Path.join([repo, ".claude", "settings.local.json.aiur-bak-123"])
    File.mkdir_p!(Path.dirname(legacy))
    File.write!(legacy, "legacy settings\n")

    assert :ok = HookConfig.uninstall(repo_root: repo)
    refute File.exists?(legacy)
    destination = Path.join(HookSettingsBackup.backup_dir(), Path.basename(legacy))
    assert File.read!(destination) == "legacy settings\n"
    assert {:ok, %{mode: mode}} = File.stat(destination)
    assert Bitwise.band(mode, 0o777) == 0o600
  end

  # Future-regression guard: uninstall must not restore over edits made after install.
  test "uninstall preserves settings edited after installation", %{root: root} do
    repo = init_repo(root)
    settings_path = Path.join([repo, ".claude", "settings.local.json"])
    File.mkdir_p!(Path.dirname(settings_path))
    File.write!(settings_path, ~s({"permissions":{"allow":["Read"]}}))
    assert :ok = HookConfig.install(:claude, repo_root: repo)

    edited = Jason.decode!(File.read!(settings_path)) |> Map.put("env", %{"KEEP" => "this edit"})
    File.write!(settings_path, Jason.encode!(edited))
    assert :ok = HookConfig.uninstall(repo_root: repo)

    restored = Jason.decode!(File.read!(settings_path))
    assert restored["env"] == %{"KEEP" => "this edit"}
    assert restored["permissions"] == %{"allow" => ["Read"]}
    refute Map.has_key?(restored, "hooks")
  end

  test "a conflicting private copy preserves the legacy file", %{root: root} do
    repo = init_repo(root)
    legacy = Path.join([repo, ".claude", "settings.local.json.aiur-bak-456"])
    File.mkdir_p!(Path.dirname(legacy))
    File.write!(legacy, "legacy settings\n")
    private = Path.join(HookSettingsBackup.backup_dir(), Path.basename(legacy))
    File.mkdir_p!(Path.dirname(private))
    File.write!(private, "different bytes")

    assert {:error, :backup_destination_conflict} = HookConfig.uninstall(repo_root: repo)
    assert File.read!(legacy) == "legacy settings\n"
    assert File.read!(private) == "different bytes"
  end

  defp init_repo(root) do
    repo = Path.join(root, "repo")
    File.mkdir_p!(repo)
    assert {_, 0} = System.cmd("git", ["init", "-q"], cd: repo)
    assert {_, 0} = System.cmd("git", ["config", "user.name", "Aiur Test"], cd: repo)
    assert {_, 0} = System.cmd("git", ["config", "user.email", "aiur-test@example.invalid"], cd: repo)
    File.write!(Path.join(repo, ".gitignore"), ".claude/settings.local.json\n")
    assert {_, 0} = System.cmd("git", ["add", ".gitignore"], cd: repo)
    assert {_, 0} = System.cmd("git", ["commit", "-qm", "add local settings ignore"], cd: repo)
    repo
  end
end
