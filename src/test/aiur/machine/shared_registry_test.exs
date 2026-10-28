defmodule Aiur.Machine.SharedRegistryTest do
  use ExUnit.Case, async: false
  import Bitwise
  alias Aiur.{Accounts, Machine.Settings}

  setup do
    home = Path.join(System.tmp_dir!(), "shared-machine-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    previous_home = System.get_env("HOME")
    previous_path = Application.get_env(:aiur, :machine_settings_path)
    System.put_env("HOME", home)
    Application.delete_env(:aiur, :machine_settings_path)
    path = Path.join(home, ".aiur/machine")

    on_exit(fn ->
      if previous_home, do: System.put_env("HOME", previous_home), else: System.delete_env("HOME")
      if previous_path, do: Application.put_env(:aiur, :machine_settings_path, previous_path), else: Application.delete_env(:aiur, :machine_settings_path)
      Aiur.TestCleanup.rm_rf!(home)
    end)

    %{path: path}
  end

  test "settings and accounts resolve the same HOME file and preserve each other's data", %{path: path} do
    assert Settings.path() == path

    settings = %{
      "mobile" => %{"enabled" => true},
      "gateway" => %{"host" => "localhost", "port" => 5000, "endpoints" => ["https://example.com"]},
      "pairing" => %{"secret_ttl_seconds" => 120, "max_devices" => 30, "pin_rotation_grace_seconds" => 7200},
      "transport" => %{
        "allow_cleartext_overlay" => true,
        "cleartext_overlay_cidrs" => ["10.0.0.0/8"],
        "tls" => %{"bind_host" => "127.0.0.1", "advertise_host" => "example.com", "cert_file" => "/tmp/cert", "key_file" => "/tmp/key"}
      },
      "relay" => %{"future" => [true, nil, %{"1" => "one"}]}
    }

    assert :ok = Settings.write(settings)
    assert :ok = Accounts.register("claude", "primary")
    assert {:ok, registered} = Aiur.Yaml.read_from_file(path)
    assert Map.delete(registered, "accounts") == settings
    account = %{"harness" => "claude", "profile_dir" => Path.join(Path.dirname(path), "accounts/claude/primary")}
    assert registered["accounts"] == %{"claude:primary" => account}

    assert :ok = Settings.write(%{gateway: %{port: 5001}})
    assert {:ok, updated} = Aiur.Yaml.read_from_file(path)
    assert updated["accounts"] == registered["accounts"]
    assert updated == put_in(registered, ["gateway", "port"], 5001)
    assert Enum.any?(Accounts.list("claude"), &(&1.name == "primary" and &1.profile_dir == account["profile_dir"]))

    assert :ok = Accounts.logout("claude", "primary", false)
    assert {:ok, logged_out} = Aiur.Yaml.read_from_file(path)
    assert logged_out == Map.put(Map.delete(updated, "accounts"), "accounts", %{})
    refute Enum.any?(Accounts.list("claude"), &(&1.name == "primary"))
  end

  test "account writes preserve parseable settings without validating them or coercing future map keys", %{path: path} do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "mobile: {enabled: typo}\nrelay: {1: one}\n")
    assert :ok = Accounts.register("claude", "primary")
    assert {:ok, raw} = Aiur.Yaml.read_from_file(path)
    assert raw["mobile"] == %{"enabled" => "typo"}
    assert raw["relay"] == %{1 => "one"}
    assert :ok = Accounts.logout("claude", "primary", false)
    assert {:ok, logged_out} = Aiur.Yaml.read_from_file(path)
    assert logged_out == Map.put(raw, "accounts", %{})
  end

  test "account registration and logout replace the file atomically with private permissions", %{path: path} do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "mobile: {enabled: true}\n")
    File.chmod!(path, 0o644)
    before_register = File.stat!(path).inode
    assert :ok = Accounts.register("claude", "primary")
    assert File.stat!(path).inode != before_register
    assert band(File.stat!(path).mode, 0o777) == 0o600
    File.chmod!(path, 0o644)
    before_logout = File.stat!(path).inode
    assert :ok = Accounts.logout("claude", "primary", false)
    assert File.stat!(path).inode != before_logout
    assert band(File.stat!(path).mode, 0o777) == 0o600
  end

  test "accounts refuse malformed and nonmapping files without changing bytes or inode", %{path: path} do
    File.mkdir_p!(Path.dirname(path))

    for contents <- ["mobile: [", "[1, 2]", "plain scalar"] do
      File.write!(path, contents)
      before = File.stat!(path)
      assert {:error, _reason} = Accounts.register("claude", "primary")
      assert File.read!(path) == contents
      assert File.stat!(path).inode == before.inode
    end
  end

  test "future regression guard: accounts refuse unreadable files without replacing the existing directory", %{path: path} do
    File.mkdir_p!(path)
    before = File.stat!(path)
    assert {:error, _reason} = Accounts.register("claude", "primary")
    assert File.dir?(path)
    assert File.stat!(path).inode == before.inode
  end

  test "future regression guard: accounts accept missing and empty machine files", %{path: path} do
    assert :ok = Accounts.register("claude", "primary")
    assert {:ok, %{"accounts" => %{"claude:primary" => %{"harness" => "claude"}}}} = Aiur.Yaml.read_from_file(path)
    File.write!(path, "")
    assert :ok = Accounts.register("claude", "secondary")
    assert {:ok, %{"accounts" => %{"claude:secondary" => %{"harness" => "claude"}}}} = Aiur.Yaml.read_from_file(path)
  end
end
