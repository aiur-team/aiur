defmodule Aiur.GitTest do
  use ExUnit.Case, async: true

  alias Aiur.Git

  describe "ls_remote/3" do
    test "parses ls-remote output into a ref => sha map" do
      stub_output =
        "abc123\trefs/heads/main\n" <>
          "def456\trefs/heads/feature\n"

      cmd_fun = fn {_git, _args} -> {stub_output, 0} end

      {:ok, refs} =
        Git.ls_remote("origin", ["refs/heads/main", "refs/heads/feature"], cmd_fun: cmd_fun)

      assert refs == %{
               "refs/heads/main" => "abc123",
               "refs/heads/feature" => "def456"
             }
    end

    test "returns empty map when refs argument is empty" do
      assert {:ok, %{}} = Git.ls_remote("origin", [])
    end

    test "returns empty map when remote has no matching refs" do
      cmd_fun = fn {_git, _args} -> {"", 0} end
      assert {:ok, %{}} = Git.ls_remote("origin", ["refs/heads/nope"], cmd_fun: cmd_fun)
    end

    test "returns error when git exits non-zero" do
      cmd_fun = fn {_git, _args} -> {"fatal: remote 'bogus' not found\n", 128} end

      assert {:error, {:git_ls_remote_failed, 128, "fatal: remote 'bogus' not found"}} =
               Git.ls_remote("bogus", ["refs/heads/main"], cmd_fun: cmd_fun)
    end

    test "tolerates tabs and multiple spaces as separator" do
      stub_output = "abc\t\trefs/heads/main\n"
      cmd_fun = fn {_git, _args} -> {stub_output, 0} end

      assert {:ok, %{"refs/heads/main" => "abc"}} =
               Git.ls_remote("origin", ["refs/heads/main"], cmd_fun: cmd_fun)
    end

    test "skips malformed lines without erroring" do
      stub_output = "abc123\trefs/heads/ok\nmalformed_line_no_separator\n"
      cmd_fun = fn {_git, _args} -> {stub_output, 0} end

      assert {:ok, refs} =
               Git.ls_remote("origin", ["refs/heads/ok"], cmd_fun: cmd_fun)

      assert refs == %{"refs/heads/ok" => "abc123"}
    end
  end
end
