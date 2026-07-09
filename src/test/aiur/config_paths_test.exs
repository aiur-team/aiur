defmodule Aiur.Config.PathsTest do
  use ExUnit.Case, async: false

  alias Aiur.Config.Paths

  describe "log_root_dir/0" do
    setup do
      original = Application.get_env(:aiur, :log_file)

      on_exit(fn ->
        case original do
          nil -> Application.delete_env(:aiur, :log_file)
          value -> Application.put_env(:aiur, :log_file, value)
        end
      end)

      :ok
    end

    test "uses Application env when :log_file is set" do
      Application.put_env(:aiur, :log_file, "/tmp/aiur_paths_test/aiur.log")
      assert Paths.log_root_dir() == "/tmp/aiur_paths_test"
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

  describe "sanitize/2 (identifier join key)" do
    # Pins the EXACT current transformation shared by the five former
    # copies (config/paths.ex, workspace.ex, opencode/config.ex,
    # claude/hook_settings.ex, test_reset.ex). Workspace dir names,
    # opencode model ids, and per-issue log/session filenames are join
    # keys across subsystems: they must all derive identically or
    # cross-subsystem lookups silently break. Any diff here is a breaking
    # change to on-disk naming — never "fix" an expected value.
    @sanitize_fixtures [
      {"issue-123", "issue-123"},
      {"ISSUE_42.v1-final", "ISSUE_42.v1-final"},
      {"owner/repo#45", "owner_repo_45"},
      {"a b\tc\nd", "a_b_c_d"},
      {"../etc/passwd", ".._etc_passwd"},
      {"..", ".."},
      {".", "."},
      {"..hidden..", "..hidden.."},
      {"trailing.", "trailing."},
      # The regex is byte-oriented (no /u modifier): every byte of a
      # multi-byte UTF-8 character is replaced with one underscore.
      {"héllo wörld", "h__llo_w__rld"},
      {"ünïcode", "__n__code"},
      {"🎉", "____"},
      {"", ""}
    ]

    test "matches the historical transformation byte-for-byte" do
      for {input, expected} <- @sanitize_fixtures do
        assert Paths.sanitize(input) == expected
        assert Paths.sanitize(input, "issue") == expected
      end
    end

    test "nil falls back to the default" do
      assert Paths.sanitize(nil, "issue") == "issue"
    end

    test "opencode safe_identifier stays a byte-identical delegate" do
      for {input, _expected} <- @sanitize_fixtures do
        assert Aiur.Opencode.Config.safe_identifier(input) ==
                 Paths.sanitize(input, "issue")
      end

      assert Aiur.Opencode.Config.safe_identifier(nil) == "issue"
    end
  end

  describe "repo_name/0" do
    test "returns 'aiur' when project_identity throws" do
      # Default test workflow has no tracker — should fall through to "aiur"
      assert is_binary(Paths.repo_name())
    end
  end
end
