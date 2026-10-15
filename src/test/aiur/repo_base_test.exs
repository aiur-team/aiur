defmodule Aiur.RepoBaseTest do
  use Aiur.RepoBaseCase

  describe "base_path/1" do
    test "puts the base clone at <owner>/<name>/latest under the base root" do
      assert RepoBase.base_path("https://github.com/foo/bar.git") |> Path.split() |> Enum.take(-3) ==
               ["foo", "bar", "latest"]

      assert RepoBase.base_path("git@github.com:foo/bar.git") |> Path.split() |> Enum.take(-3) ==
               ["foo", "bar", "latest"]
    end

    test "keeps the build store beside latest in the repository state node" do
      assert RepoBase.builds_path("https://github.com/foo/bar.git") |> Path.split() |> Enum.take(-3) ==
               ["foo", "bar", "builds"]
    end

    test "exposes sibling meta, analytics, and Executor state paths" do
      repo = "https://github.com/foo/bar.git"

      assert RepoBase.meta_path(repo) |> Path.split() |> Enum.take(-3) == ["foo", "bar", "meta"]
      assert RepoBase.findings_path(repo) |> Path.split() |> Enum.take(-4) == ["foo", "bar", "meta", "findings.ndjson"]
      assert RepoBase.retros_path(repo) |> Path.split() |> Enum.take(-4) == ["foo", "bar", "meta", "retros"]
      assert RepoBase.analytics_path(repo) |> Path.split() |> Enum.take(-3) == ["foo", "bar", "analytics"]
      assert RepoBase.executor_path(repo) |> Path.split() |> Enum.take(-3) == ["foo", "bar", "executor"]
      assert RepoBase.handoff_path(repo) |> Path.split() |> Enum.take(-4) == ["foo", "bar", "executor", "handoff.md"]
      assert RepoBase.repo_relative_path(repo) == ".aiur/repo/foo/bar"
    end

    test "rejects repo identities that would escape the state root", %{tmp: tmp} do
      previous_root = Application.get_env(:aiur, :repo_base_root)
      Application.put_env(:aiur, :repo_base_root, Path.join(tmp, "state"))

      on_exit(fn ->
        case previous_root do
          nil -> Application.delete_env(:aiur, :repo_base_root)
          root -> Application.put_env(:aiur, :repo_base_root, root)
        end
      end)

      # `..` landing in the final two slug segments would resolve outside the
      # state root; the CLI already rejects these, this guards the lib boundary.
      for malicious <- [
            "https://github.com/../escape",
            "https://github.com/owner/..",
            "owner/../project",
            "owner/project/.."
          ] do
        assert_raise ArgumentError, fn -> RepoBase.repo_path(malicious) end
        assert_raise ArgumentError, fn -> RepoBase.repo_relative_path(malicious) end
      end
    end
  end

  describe "setup_state/2" do
    test "creates the complete state tree and imports a legacy retrospective", %{tmp: tmp} do
      previous_root = Application.get_env(:aiur, :repo_base_root)
      state_root = Path.join(tmp, "state")
      source_root = Path.join(tmp, "source")
      File.mkdir_p!(Path.join([source_root, "docs", "executor"]))
      File.write!(Path.join([source_root, "docs", "executor", "hourly-retrospectives.md"]), "legacy notes\n")
      Application.put_env(:aiur, :repo_base_root, state_root)

      on_exit(fn ->
        case previous_root do
          nil -> Application.delete_env(:aiur, :repo_base_root)
          root -> Application.put_env(:aiur, :repo_base_root, root)
        end
      end)

      repo = "https://github.com/foo/bar.git"
      assert :ok = RepoBase.setup_state(repo, source_root)
      assert :ok = RepoBase.setup_state(repo, source_root)

      assert File.dir?(RepoBase.base_path(repo))
      assert File.dir?(RepoBase.builds_path(repo))
      assert File.dir?(RepoBase.analytics_path(repo))
      assert File.dir?(RepoBase.retros_path(repo))
      assert File.regular?(RepoBase.findings_path(repo))
      assert File.dir?(RepoBase.executor_path(repo))

      for sidecar <- [".aiur-hex", ".aiur-mix", ".aiur-npm-cache"] do
        assert File.dir?(Path.join(RepoBase.repo_path(repo), sidecar))
      end

      assert [imported] = Path.wildcard(Path.join(RepoBase.retros_path(repo), "legacy-*.md"))
      assert File.read!(imported) == "legacy notes\n"
    end

    test "refuses a state-tree symlink before creating a findings ledger", %{tmp: tmp} do
      previous_root = Application.get_env(:aiur, :repo_base_root)
      repo = "https://github.com/foo/bar.git"
      node = Path.join([tmp, "state", "foo", "bar"])
      outside = Path.join(tmp, "outside")
      File.mkdir_p!(node)
      File.mkdir_p!(outside)
      assert :ok = File.ln_s(outside, Path.join(node, "meta"))
      Application.put_env(:aiur, :repo_base_root, Path.join(tmp, "state"))

      on_exit(fn ->
        case previous_root do
          nil -> Application.delete_env(:aiur, :repo_base_root)
          root -> Application.put_env(:aiur, :repo_base_root, root)
        end
      end)

      assert {:error, {:repo_base_state_path_symlink, _}} = RepoBase.ensure_state_tree(repo)
      refute File.exists?(Path.join(outside, "findings.ndjson"))
    end
  end

  describe "base_branch/0" do
    # Pins the workflow config per test (same pattern as the "server state
    # machine" setup in repo_base/server_test.exs) so resolution never depends on ambient config.
    setup do
      tmp = Aiur.TestSupport.tmp_root!("rb_bb")
      File.mkdir_p!(tmp)
      cfg = Path.join(tmp, "config")
      prev_path = Application.get_env(:aiur, :workflow_file_path)

      on_exit(fn ->
        case prev_path do
          nil -> Aiur.Workflow.clear_workflow_file_path()
          p -> Aiur.Workflow.set_workflow_file_path(p)
        end

        Aiur.TestCleanup.rm_rf!(tmp)
      end)

      {:ok, cfg: cfg}
    end

    test "raises when tracker.base_branch is unset", %{cfg: cfg} do
      File.write!(cfg, "tracker:\n  kind: memory\n")
      Aiur.Workflow.set_workflow_file_path(cfg)

      assert_raise ArgumentError, ~r/tracker\.base_branch could not be resolved/, fn -> RepoBase.base_branch() end
    end

    test "returns the configured tracker.base_branch", %{cfg: cfg} do
      File.write!(cfg, "tracker:\n  kind: memory\n  base_branch: v2\n")
      Aiur.Workflow.set_workflow_file_path(cfg)

      assert RepoBase.base_branch() == "v2"
    end

    test "raises when tracker.base_branch is empty", %{cfg: cfg} do
      File.write!(cfg, ~s(tracker:\n  kind: memory\n  base_branch: ""\n))
      Aiur.Workflow.set_workflow_file_path(cfg)

      assert_raise ArgumentError, ~r/tracker\.base_branch could not be resolved/, fn -> RepoBase.base_branch() end
    end
  end

  describe "status/0" do
    test "returns a {phase, base_path} tuple" do
      assert {_phase, _base} = RepoBase.status()
    end
  end

  describe "git_auth_env/1" do
    test "injects the token as a per-host Authorization header via env config" do
      env = RepoBase.git_auth_env("ghp_secrettoken")
      assert {"GIT_CONFIG_COUNT", "1"} in env
      assert {"GIT_CONFIG_KEY_0", "http.https://github.com/.extraheader"} in env
      assert {"GIT_TERMINAL_PROMPT", "0"} in env

      {_k, value} = Enum.find(env, fn {k, _v} -> k == "GIT_CONFIG_VALUE_0" end)
      assert "AUTHORIZATION: basic " <> b64 = value
      assert Base.decode64!(b64) == "x-access-token:ghp_secrettoken"
    end

    test "carries the secret only in the env (base64-encoded), never in plaintext" do
      # The token rides in `env:` to System.cmd, never on argv, and even there it
      # only appears base64-encoded inside the Authorization header — so a raw
      # token string never lands in argv/`ps` or the env list verbatim.
      env = RepoBase.git_auth_env("ghp_secrettoken")
      refute inspect(env) =~ "ghp_secrettoken"

      {_k, value} = Enum.find(env, fn {k, _v} -> k == "GIT_CONFIG_VALUE_0" end)
      assert "AUTHORIZATION: basic " <> b64 = value
      assert Base.decode64!(b64) =~ "ghp_secrettoken"
    end

    test "with no token, disables the terminal prompt and injects no credential" do
      for token <- [nil, ""] do
        env = RepoBase.git_auth_env(token)
        assert env == [{"GIT_TERMINAL_PROMPT", "0"}]
        refute Enum.any?(env, fn {k, _v} -> String.starts_with?(k, "GIT_CONFIG") end)
      end
    end
  end
end
