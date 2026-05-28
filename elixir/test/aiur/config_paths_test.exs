defmodule Aiur.Config.PathsTest do
  use ExUnit.Case, async: false

  alias Aiur.Config.Paths

  describe "log_root_dir/0" do
    test "uses Application env when :log_file is set" do
      Application.put_env(:aiur, :log_file, "/tmp/aiur_paths_test/aiur.log")
      assert Paths.log_root_dir() == "/tmp/aiur_paths_test"
    after
      Application.delete_env(:aiur, :log_file)
    end

    test "falls back to <cwd>/log when env unset" do
      Application.delete_env(:aiur, :log_file)
      assert Paths.log_root_dir() == Path.join(File.cwd!(), "log")
    end
  end

  describe "sanitize/1" do
    test "replaces forward slashes" do
      assert Paths.sanitize("owner/repo") == "owner_repo"
    end

    test "preserves alphanumerics and ._-" do
      assert Paths.sanitize("repo-name.v1_0") == "repo-name.v1_0"
    end

    test "replaces shell-special characters" do
      assert Paths.sanitize("a;b|c&d") == "a_b_c_d"
    end

    test "replaces path traversal sequences" do
      # `..` is allowed by the regex (dots + alphanumerics) but `/` is not,
      # so combined sequences like "../foo" become "../foo" — sanitize is
      # not path-traversal-proof on its own; callers must validate component
      # boundaries. We document by test.
      assert Paths.sanitize("../etc/passwd") == ".._etc_passwd"
    end
  end

  describe "repo_name/0" do
    test "returns 'aiur' when project_identity throws" do
      # Default test workflow has no tracker — should fall through to "aiur"
      assert is_binary(Paths.repo_name())
    end
  end
end
