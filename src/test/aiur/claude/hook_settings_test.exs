defmodule Aiur.Claude.HookSettingsTest do
  use ExUnit.Case, async: true

  alias Aiur.Claude.HookSettings

  describe "settings/2" do
    test "wires all four lifecycle hooks to the agent's endpoint" do
      settings = HookSettings.settings("101", "http://127.0.0.1:4000")

      assert settings["hooks"] |> Map.keys() |> Enum.sort() ==
               ["PostToolUse", "Stop", "StopFailure", "UserPromptSubmit"]

      command =
        settings["hooks"]["StopFailure"]
        |> hd()
        |> Map.fetch!("hooks")
        |> hd()
        |> Map.fetch!("command")

      assert command =~ "http://127.0.0.1:4000/api/v1/101/claude-hook"
    end
  end

  describe "hook_command/2" do
    test "is stdout-silent, fast, and always exits 0 (claude-safe invariants)" do
      command = HookSettings.hook_command("MT-9", "http://127.0.0.1:4000/")

      assert command =~ "-o /dev/null"
      assert command =~ ">/dev/null 2>&1"
      assert command =~ "-m 2"
      assert String.ends_with?(command, "; exit 0")
      assert command =~ "X-Aiur-Request: 1"
      # trailing slash on the base url is normalized (no `//api/v1`)
      assert command =~ "/api/v1/MT-9/claude-hook"
      refute command =~ "//api/v1"
    end
  end

  describe "write/2" do
    test "writes valid JSON with the hooks and returns the path" do
      {:ok, path} = HookSettings.write("WRITE-TEST", "http://127.0.0.1:4321")
      on_exit(fn -> File.rm(path) end)

      assert File.exists?(path)

      command =
        path
        |> File.read!()
        |> Jason.decode!()
        |> get_in(["hooks", "UserPromptSubmit"])
        |> hd()
        |> Map.fetch!("hooks")
        |> hd()
        |> Map.fetch!("command")

      assert command =~ "WRITE-TEST"
    end
  end
end
