defmodule Aiur.RepoBase.RefreshTest do
  use Aiur.RepoBaseCase

  describe "refresh/3" do
    test "clones and builds on first refresh, writing a SHA-keyed base record beside latest", %{origin: origin, node: node, base: base} do
      assert {:ok, ^base} = RepoBase.refresh(base, origin, "touch built_ran")

      assert File.exists?(Path.join(base, "built_ran")), "base_build command did not run"
      assert {:ok, record_body} = File.read(Path.join(node, "base-record.json"))
      assert {:ok, record} = Jason.decode(record_body)
      assert record["clone_head"] == head(origin)
      assert is_binary(record["prewarm_script_hash"])
      assert is_binary(record["built_at"])
      refute File.exists?(Path.join(base, ".aiur-base-built"))
      assert head(base) == head(origin)
    end

    test "rebuilds when the prewarm script changes without a new commit", %{origin: origin, base: base} do
      assert {:ok, ^base} = RepoBase.refresh(base, origin, "touch first_build")
      assert {:ok, ^base} = RepoBase.refresh(base, origin, "touch second_build")

      assert File.exists?(Path.join(base, "second_build"))
    end

    test "is idempotent when main has not advanced", %{origin: origin, base: base} do
      assert {:ok, ^base} = RepoBase.refresh(base, origin, "touch built_ran")
      File.rm!(Path.join(base, "built_ran"))

      assert {:ok, ^base} = RepoBase.refresh(base, origin, "touch built_ran")

      refute File.exists?(Path.join(base, "built_ran")),
             "base_build re-ran even though main did not advance"
    end

    test "rebuilds when main advances", %{origin: origin, base: base} do
      assert {:ok, ^base} = RepoBase.refresh(base, origin, "touch built_ran")
      File.rm!(Path.join(base, "built_ran"))

      File.write!(Path.join(origin, "README.md"), "v2\n")
      git!(["-C", origin, "commit", "--quiet", "-am", "advance"])

      assert {:ok, ^base} = RepoBase.refresh(base, origin, "touch built_ran")

      assert File.exists?(Path.join(base, "built_ran")), "base_build did not re-run after advance"
      assert head(base) == head(origin)
    end

    test "tracks configured v2 and ignores a main-only advance", %{origin: origin, base: base, tmp: tmp} do
      git!(["-C", origin, "checkout", "-b", "v2"])
      File.write!(Path.join(origin, "README.md"), "v2 initial\n")
      git!(["-C", origin, "commit", "--quiet", "-am", "v2 initial"])
      v2_initial = head(origin)

      config = Path.join(tmp, "v2config.yaml")
      previous_config = Application.get_env(:aiur, :workflow_file_path)
      File.write!(config, "tracker:\n  kind: memory\n  base_branch: v2\n")
      Aiur.Workflow.set_workflow_file_path(config)

      on_exit(fn ->
        case previous_config do
          nil -> Aiur.Workflow.clear_workflow_file_path()
          path -> Aiur.Workflow.set_workflow_file_path(path)
        end
      end)

      assert {:ok, ^base} = RepoBase.refresh(base, origin, "touch built_ran")
      assert head(base) == v2_initial
      File.rm!(Path.join(base, "built_ran"))

      git!(["-C", origin, "checkout", "main"])
      File.write!(Path.join(origin, "README.md"), "main only\n")
      git!(["-C", origin, "commit", "--quiet", "-am", "main only"])

      assert {:ok, ^base} = RepoBase.refresh(base, origin, "touch built_ran")
      assert head(base) == v2_initial
      refute File.exists?(Path.join(base, "built_ran"))

      git!(["-C", origin, "checkout", "v2"])
      File.write!(Path.join(origin, "README.md"), "v2 advanced\n")
      git!(["-C", origin, "commit", "--quiet", "-am", "v2 advanced"])
      v2_advanced = head(origin)

      assert {:ok, ^base} = RepoBase.refresh(base, origin, "touch built_ran")
      assert head(base) == v2_advanced
      assert File.exists?(Path.join(base, "built_ran"))
    end

    test "returns an error and skips the marker when base_build fails", %{origin: origin, base: base} do
      assert {:error, {:base_build_failed, status, _out}} = RepoBase.refresh(base, origin, "exit 3")
      assert status == 3
      refute File.exists?(Path.join(Path.dirname(base), "base-record.json"))
    end

    test "runs base_build with the base mise.toml trusted", %{origin: origin, base: base} do
      # base_build records the trust path it actually ran with; proves base_env/1
      # reached the build shell (regression for the untrusted-base prewarm hang).
      assert {:ok, ^base} =
               RepoBase.refresh(base, origin, ~s(printf '%s' "$MISE_TRUSTED_CONFIG_PATHS" > trust_path))

      assert File.read!(Path.join(base, "trust_path")) =~ base
    end

    test "prewarm build starts mise OTP and Hex with release launcher environment", %{
      tmp: tmp,
      origin: origin,
      node: node,
      base: base
    } do
      release_root = Path.join(tmp, "release")
      release_erts_bin = Path.join([release_root, "erts-16.4", "bin"])
      release_bin = Path.join(release_root, "bin")
      user_bin = Path.join(tmp, "toolchain/bin")
      expected_erl = System.find_executable("erl")
      File.mkdir_p!(release_erts_bin)
      File.mkdir_p!(release_bin)
      File.mkdir_p!(user_bin)
      File.write!(Path.join(release_erts_bin, "erl"), "#!/bin/sh\necho poisoned-release-erl\nexit 86\n")
      File.chmod!(Path.join(release_erts_bin, "erl"), 0o755)

      File.write!(
        Path.join(origin, "mix.exs"),
        """
        defmodule PrewarmFixture.MixProject do
          use Mix.Project

          def project, do: [app: :prewarm_fixture, version: "0.1.0"]
          def application, do: [extra_applications: [:inets]]
        end
        """
      )

      File.cp!(Path.expand("../../../../mise.toml", __DIR__), Path.join(origin, "mise.toml"))

      git!(["-C", origin, "add", "mix.exs", "mise.toml"])
      git!(["-C", origin, "commit", "--quiet", "-m", "add prewarm fixture"])

      hex_archive =
        Mix.path_for(:archives)
        |> File.ls!()
        |> Enum.find(&String.starts_with?(&1, "hex-"))

      assert is_binary(hex_archive), "expected the test toolchain to provide a Hex archive"

      archive_dir = Path.join([node, ".aiur-mix", "archives"])
      File.mkdir_p!(archive_dir)

      File.cp_r!(
        Path.join(Mix.path_for(:archives), hex_archive),
        Path.join(archive_dir, hex_archive)
      )

      release_env = [
        {"AIUR_RELEASE_DIR", release_root},
        {"ROOTDIR", release_root},
        {"BINDIR", release_erts_bin},
        {"EMU", "beam"},
        {"PROGNAME", "erl"},
        {"PATH", Enum.join([release_erts_bin, release_bin, user_bin, System.fetch_env!("PATH")], ":")}
      ]

      previous_env =
        Map.new(release_env, fn {name, _value} ->
          {name, System.get_env(name)}
        end)

      Enum.each(release_env, fn {name, value} -> System.put_env(name, value) end)

      on_exit(fn ->
        Enum.each(previous_env, fn {name, value} ->
          if value, do: System.put_env(name, value), else: System.delete_env(name)
        end)
      end)

      assert {:ok, ^base} =
               RepoBase.refresh(
                 base,
                 origin,
                 ~S"""
                 mise exec -- mix hex.config >/dev/null && mise exec -- mix run --no-start -e '{:ok, _} = Application.ensure_all_started(:inets); erl = System.find_executable("erl"); inets = :code.lib_dir(:inets); if not is_binary(erl) or not is_list(inets), do: System.halt(41); File.write!("release_env_scrubbed", IO.iodata_to_binary([erl, "\n", inets, "\nhex-started"]))'
                 """
               )

      proof = File.read!(Path.join(base, "release_env_scrubbed"))
      assert proof =~ to_string(:code.lib_dir(:inets))
      assert [erl_path, _inets_path, "hex-started"] = String.split(proof, "\n")
      assert erl_path == expected_erl
    end

    test "keeps package-manager caches beside latest rather than in the clone", %{origin: origin, node: node, base: base} do
      command =
        ~s(printf '%s\n%s\n%s\n' "$HEX_HOME" "$MIX_HOME" "$npm_config_cache" > package_manager_env; ) <>
          ~s(mkdir -p "$HEX_HOME" "$MIX_HOME" "$npm_config_cache"; touch "$HEX_HOME/hex" "$MIX_HOME/mix" "$npm_config_cache/npm")

      assert {:ok, ^base} = RepoBase.refresh(base, origin, command)

      daemon_cache_root = Path.join([node, "executor", "package-manager-cache"])

      assert Path.join(base, "package_manager_env") |> File.read!() |> String.split("\n", trim: true) == [
               Path.join(daemon_cache_root, ".aiur-hex"),
               Path.join(daemon_cache_root, ".aiur-mix"),
               Path.join(daemon_cache_root, ".aiur-npm-cache")
             ]

      for cache <- [".aiur-hex/hex", ".aiur-mix/mix", ".aiur-npm-cache/npm"] do
        assert File.exists?(Path.join(daemon_cache_root, cache))
        refute File.exists?(Path.join(node, cache))
        refute File.exists?(Path.join(base, cache))
      end
    end

    test "logs base_build failures at error with the captured output", %{origin: origin, base: base} do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, {:base_build_failed, 3, _}} =
                   RepoBase.refresh(base, origin, "echo boom 1>&2; exit 3")
        end)

      assert log =~ "prewarm base unavailable"
      assert log =~ "boom"
    end

    test "does not log a prewarm error on a successful base_build", %{origin: origin, base: base} do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, ^base} = RepoBase.refresh(base, origin, "true")
        end)

      refute log =~ "prewarm base unavailable"
    end

    test "never persists the auth header into the cloned repo's git config", %{origin: origin, base: base} do
      # The token rides in env-config (GIT_CONFIG_*), so it must never be written
      # into the cloned repo's own config the way a token-in-URL or `-c` would.
      assert {:ok, ^base} = RepoBase.refresh(base, origin, "true")

      config = File.read!(Path.join(base, ".git/config"))
      refute config =~ "extraheader"
      refute config =~ "Authorization"
      refute config =~ "x-access-token"
    end

    test "emits ordered phase events", %{origin: origin, base: base} do
      Phoenix.PubSub.subscribe(Aiur.PubSub, "prewarm:phase")

      assert {:ok, ^base} = RepoBase.refresh(base, origin, "true")

      assert_receive {:prewarm_phase, :cloning}, 5_000
      assert_receive {:prewarm_phase, :fetching}, 5_000
      assert_receive {:prewarm_phase, :building}, 5_000
      assert_receive {:prewarm_phase, :ready}, 5_000
    end
  end
end
