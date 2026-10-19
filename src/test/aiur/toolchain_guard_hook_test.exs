defmodule Aiur.ToolchainGuardHookTest do
  use ExUnit.Case, async: true

  @hook_path Path.expand("../../../.claude/hooks/toolchain-guard.py", __DIR__)

  test "commands that change the shared mise toolchain are refused" do
    for command <- [
          "mise prune",
          "mise upgrade erlang",
          "mise up",
          "mise install erlang@28.5",
          "mise uninstall erlang@28.4",
          "mise use -g erlang@27",
          "cd src && mise -C . prune --yes",
          "env FOO=1 /usr/bin/mise upgrade",
          "mise exec -- mise prune",
          "bash -c 'mise upgrade'",
          "echo $(mise prune)"
        ] do
      assert {output, 2} = run_hook(command), command
      assert output =~ "aiur: refusing `mise", command
    end
  end

  test "read-only and exec mise commands pass" do
    for command <- [
          "mise exec -- mix test --max-cases 4",
          "mise ls --current",
          "mise which erl",
          "mise trust",
          "echo mise prune",
          "rg -n 'mise upgrade' docs"
        ] do
      assert {"", 0} = run_hook(command), command
    end
  end

  test "temporary path cleanup guard blocks protected X11 paths and tmp sweeps" do
    for command <- [
          "rm -f /tmp/.X11-unix/X0",
          "rm -rf /tmp/.ICE-unix",
          "find /tmp -name '.X*-lock' -delete",
          "rm -rf /tmp/*",
          "find /tmp -name '.*' -delete",
          "find /tmp -mindepth 1 -mtime +1 -delete",
          "find /tmp -maxdepth 1 -user everdred -mmin +1440 -exec rm -rf {} +",
          "find /tmp/ -type d -mtime +1 -exec rm -rf {} +",
          "find /tmp/. -type f -delete",
          "systemd-tmpfiles --clean",
          "systemd-tmpfiles --remove",
          "tmpwatch 24h /tmp",
          "tmpreaper 24h /tmp"
        ] do
      assert {output, 2} = run_tmp_cleanup_hook(command), command
      assert output =~ "aiur: refusing", command
    end
  end

  test "temporary path cleanup guard permits exact unrelated paths" do
    for command <- [
          "rm -f /tmp/aiur-test-123",
          "find /tmp/aiur-test-123 -type f -delete",
          "rm -f /tmp/.Xauthority",
          "find /tmp -maxdepth 1 -type f -print",
          "find /tmp/aiur-test-123 -type f -exec rm -f {} +"
        ] do
      assert {"", 0} = run_tmp_cleanup_hook(command), command
    end
  end

  defp run_hook(command) do
    python = System.find_executable("python3") || flunk("python3 is required")
    payload = Jason.encode!(%{"tool_name" => "Bash", "tool_input" => %{"command" => command}})

    System.cmd("sh", ["-c", ~s(printf '%s' "$2" | "$1" "$3"), "sh", python, payload, @hook_path], stderr_to_stdout: true)
  end

  defp run_tmp_cleanup_hook(command) do
    python = System.find_executable("python3") || flunk("python3 is required")
    hook_path = Path.expand("../../../.claude/hooks/tmp-cleanup-guard.py", __DIR__)
    payload = Jason.encode!(%{"tool_name" => "Bash", "tool_input" => %{"command" => command}})

    System.cmd("sh", ["-c", ~s(printf '%s' "$2" | "$1" "$3"), "sh", python, payload, hook_path], stderr_to_stdout: true)
  end
end
