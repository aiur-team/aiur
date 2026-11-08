defmodule Aiur.Executor.DeliveryHookConfigTest do
  use ExUnit.Case, async: false
  alias Aiur.Executor.{DeliverHookCommand, HookConfig, HookSettingsBackup, HookToken}

  setup do
    root = Aiur.TestSupport.tmp_root!("delivery hooks ' quoted")
    previous = Application.fetch_env(:aiur, :executor_state_dir)
    key = System.get_env("AIUR_INSTANCE_KEY")
    Application.put_env(:aiur, :executor_state_dir, Path.join(root, "state"))
    System.put_env("AIUR_INSTANCE_KEY", "delivery-config-test")

    on_exit(fn ->
      if previous == :error, do: Application.delete_env(:aiur, :executor_state_dir), else: Application.put_env(:aiur, :executor_state_dir, elem(previous, 1))
      if key, do: System.put_env("AIUR_INSTANCE_KEY", key), else: System.delete_env("AIUR_INSTANCE_KEY")
      Aiur.TestCleanup.rm_rf!(root)
    end)

    %{root: root, path: Path.join([root, ".claude", "settings.local.json"])}
  end

  test "both harnesses generate delivery at exactly three events and print it without writing", %{root: root} do
    for harness <- [:claude, :codex] do
      entries = HookConfig.entries(harness)
      delivery = for {event, groups} <- entries, group <- groups, hook <- group["hooks"], hook["command"] =~ "/hook/deliver?", do: {event, hook}
      assert Enum.sort(Enum.map(delivery, &elem(&1, 0))) == ~w(PostToolUse Stop UserPromptSubmit)

      for {_event, hook} <- delivery do
        assert hook["timeout"] == 10
        assert hook["command"] =~ "harness=#{harness}"
        assert hook["command"] =~ "curl -sS -f -m 3"
      end

      assert HookConfig.render(harness) =~ "/hook/deliver?"
    end

    assert HookConfig.install(:codex, repo_root: root) == {:error, :print_only}
    refute File.exists?(Path.join(root, ".codex"))
    refute File.exists?(Path.join(root, ".claude"))
  end

  test "install twice adds delivery once and uninstall preserves user bytes", %{root: root, path: path} do
    user = %{"matcher" => "*", "hooks" => [%{"type" => "command", "command" => "khala deliver"}, %{"type" => "command", "command" => "echo user"}]}
    original = Jason.encode!(%{"permissions" => %{"allow" => ["Read"]}, "hooks" => %{"Stop" => [user]}}) <> "\n\n"
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, original)
    assert :ok = HookConfig.install(:claude, repo_root: root)
    first = File.read!(path)
    assert :ok = HookConfig.install(:claude, repo_root: root)
    assert File.read!(path) == first
    assert [^user, _, %{"hooks" => [%{"command" => command}]}] = Jason.decode!(first)["hooks"]["Stop"]
    assert command =~ "/hook/deliver?"
    assert :ok = HookConfig.uninstall(repo_root: root)
    assert File.read!(path) == original
    assert [backup] = Path.wildcard(Path.join(HookSettingsBackup.backup_dir(), "settings.local.json.aiur-bak-*"))
    assert File.read!(backup) == original
  end

  test "pure merge removes old-port delivery commands individually and keeps unrelated handlers" do
    user = %{"type" => "command", "command" => "echo curl -sS -f -m 3 /api/v1/executor/hook/deliver?"}
    old = %{"type" => "command", "command" => DeliverHookCommand.command(:claude, "http://127.0.0.1:1234", "/old/token")}
    legacy = %{"command" => "curl -sS -f -m 3 http://127.0.0.1:9999/api/v1/executor/hook/deliver"}
    config = %{"other" => true, "hooks" => %{"Stop" => [%{"matcher" => "*", "hooks" => [old, legacy, user]}]}}
    assert {:ok, result} = HookConfig.merge(config, :uninstall, HookConfig.entries(:claude))
    assert result == %{"other" => true, "hooks" => %{"Stop" => [%{"matcher" => "*", "hooks" => [user]}]}}
    assert {:ok, installed} = HookConfig.merge(result, :install, HookConfig.entries(:claude))
    assert {:ok, ^installed} = HookConfig.merge(installed, :install, HookConfig.entries(:claude))
  end

  test "merge appends only missing commands from mixed fragment groups" do
    user = %{"type" => "command", "command" => "user"}
    delivery = %{"type" => "command", "command" => "delivery"}
    config = %{"hooks" => %{"Stop" => [%{"hooks" => [user]}]}}
    fragment = %{"Stop" => [%{"matcher" => "*", "hooks" => [user, delivery]}, %{"hooks" => [delivery]}]}
    assert {:ok, result} = HookConfig.merge(config, :install, fragment)
    assert result == %{"hooks" => %{"Stop" => [%{"hooks" => [user]}, %{"matcher" => "*", "hooks" => [delivery]}]}}
  end

  test "pure merge rejects malformed settings and fragments" do
    for config <- [%{"hooks" => nil}, %{"hooks" => %{"Stop" => [%{}]}}, [], %{"hooks" => []}] do
      assert HookConfig.merge(config, :install, %{}) == {:error, :invalid_hooks_config}
    end

    assert HookConfig.merge(%{}, :install, %{"Stop" => false}) == {:error, :invalid_hooks_config}
  end

  test "generated delivery command reads changed ports, forwards stdin and prints the envelope", %{root: root} do
    assert :ok = HookToken.ensure()
    bin = Path.join(root, "bin")
    File.mkdir_p!(bin)
    capture = Path.join(root, "capture")
    File.write!(Path.join(bin, "curl"), "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$CAPTURE\"\ncat >> \"$CAPTURE\"\nprintf '{\"decision\":\"block\"}'\n")
    File.chmod!(Path.join(bin, "curl"), 0o700)
    [_, %{"hooks" => [%{"command" => command}]}] = HookConfig.entries(:claude)["Stop"]
    assert System.cmd("sh", ["-c", command]) == {"", 0}

    for port <- [12_345, 23_456] do
      assert :ok = HookConfig.write_url(port)
      assert System.cmd("sh", ["-c", "printf payload | " <> command], env: [{"PATH", bin <> ":" <> System.get_env("PATH")}, {"CAPTURE", capture}]) == {~s({"decision":"block"}), 0}
      assert File.read!(capture) =~ "http://127.0.0.1:#{port}/api/v1/executor/hook/deliver?harness=claude"
      assert File.read!(capture) =~ "payload"
    end
  end
end
