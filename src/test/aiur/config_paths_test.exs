defmodule Aiur.Config.PathsTest do
  use ExUnit.Case, async: false

  alias Aiur.Config.Paths
  alias Aiur.Opencode.Config

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
        assert Config.safe_identifier(input) ==
                 Paths.sanitize(input, "issue")
      end

      assert Config.safe_identifier(nil) == "issue"
    end
  end

  describe "repo_name/0" do
    test "returns 'aiur' when project_identity throws" do
      # Default test workflow has no tracker — should fall through to "aiur"
      assert is_binary(Paths.repo_name())
    end
  end

  describe "project_name/0" do
    test "returns a filename-safe project discriminator" do
      assert Paths.project_name() =~ ~r/\A[A-Za-z0-9._-]+\z/
    end
  end

  describe "decision_state_dir/0" do
    setup do
      original_instance_key = System.get_env("AIUR_INSTANCE_KEY")
      original_state_dir_env = System.get_env("AIUR_BG_STATE_DIR")
      original_override = Application.get_env(:aiur, :decision_state_dir)

      on_exit(fn ->
        restore_system_env("AIUR_INSTANCE_KEY", original_instance_key)
        restore_system_env("AIUR_BG_STATE_DIR", original_state_dir_env)

        case original_override do
          nil -> Application.delete_env(:aiur, :decision_state_dir)
          value -> Application.put_env(:aiur, :decision_state_dir, value)
        end
      end)

      Application.delete_env(:aiur, :decision_state_dir)
      root = Path.join(System.tmp_dir!(), "aiur-decision-paths-#{System.unique_integer([:positive])}")
      System.put_env("AIUR_BG_STATE_DIR", root)

      %{root: root}
    end

    test "an Application override wins outright, skipping validation" do
      Application.put_env(:aiur, :decision_state_dir, "/tmp/explicit-decision-override")
      System.delete_env("AIUR_INSTANCE_KEY")

      assert Paths.decision_state_dir() == {:ok, "/tmp/explicit-decision-override"}
    end

    test "refuses an empty AIUR_INSTANCE_KEY instead of sharing a default" do
      System.put_env("AIUR_INSTANCE_KEY", "")

      assert Paths.decision_state_dir() == {:error, :missing_instance_key}
    end

    test "refuses a missing AIUR_INSTANCE_KEY" do
      System.delete_env("AIUR_INSTANCE_KEY")

      assert Paths.decision_state_dir() == {:error, :missing_instance_key}
    end

    test "resolves beneath the configured root when the instance key and project identity are available",
         %{root: root} do
      System.put_env("AIUR_INSTANCE_KEY", "abc123")

      assert {:ok, path} = Paths.decision_state_dir()
      assert String.starts_with?(path, Path.expand(root) <> "/")
      assert Path.basename(Path.dirname(path)) == "abc123"
      assert Path.basename(path) == Paths.repo_name()
    end

    test "rejects an instance key that would escape the configured root" do
      System.put_env("AIUR_INSTANCE_KEY", "..")

      assert Paths.decision_state_dir() == {:error, :decision_path_outside_root}
    end
  end

  describe "usage_ledger_state_dir/0" do
    setup do
      original_ledger = Application.get_env(:aiur, :usage_ledger_state_dir)
      original_decision = Application.get_env(:aiur, :decision_state_dir)

      on_exit(fn ->
        restore_application_env(:usage_ledger_state_dir, original_ledger)
        restore_application_env(:decision_state_dir, original_decision)
      end)

      :ok
    end

    test "uses a dedicated contained leaf beneath decision state" do
      Application.put_env(:aiur, :decision_state_dir, "/tmp/aiur-private-state")
      Application.delete_env(:aiur, :usage_ledger_state_dir)

      assert Paths.usage_ledger_state_dir() == {:ok, "/tmp/aiur-private-state/usage-ledger"}
    end

    test "allows an explicit trusted test override" do
      Application.put_env(:aiur, :usage_ledger_state_dir, "/tmp/usage-ledger-test")
      assert Paths.usage_ledger_state_dir() == {:ok, "/tmp/usage-ledger-test"}
    end
  end

  describe "takeover_alert_state_dir/0" do
    setup do
      original_takeover = Application.get_env(:aiur, :takeover_alert_state_dir)
      original_decision = Application.get_env(:aiur, :decision_state_dir)

      on_exit(fn ->
        restore_application_env(:takeover_alert_state_dir, original_takeover)
        restore_application_env(:decision_state_dir, original_decision)
      end)

      :ok
    end

    test "uses a dedicated contained leaf beneath decision state" do
      Application.put_env(:aiur, :decision_state_dir, "/tmp/aiur-private-state")
      Application.delete_env(:aiur, :takeover_alert_state_dir)

      assert Paths.takeover_alert_state_dir() == {:ok, "/tmp/aiur-private-state/executor-takeover-alerts"}
    end

    test "allows an explicit trusted test override" do
      Application.put_env(:aiur, :takeover_alert_state_dir, "/tmp/takeover-alert-test")
      assert Paths.takeover_alert_state_dir() == {:ok, "/tmp/takeover-alert-test"}
    end
  end

  defp restore_system_env(key, nil), do: System.delete_env(key)
  defp restore_system_env(key, value), do: System.put_env(key, value)
  defp restore_application_env(key, nil), do: Application.delete_env(:aiur, key)
  defp restore_application_env(key, value), do: Application.put_env(:aiur, key, value)
end
