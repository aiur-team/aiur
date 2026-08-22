defmodule Aiur.Regression.InstanceIdentityTest do
  @moduledoc """
  Regression for #431 — a second aiur instance for the same user reaped the live
  one because the node name, tmux session, and socket were keyed only by `$USER`.

  A sandboxed inner aiur (an agent running `aiurdev` in its workspace) couldn't see
  the outer's tmux session, so the startup reaper `kill_beams_matching -name
  $AIUR_RELEASE_NODE` killed the live outer BEAM. Identity is now keyed by the aiur
  project root, so two instances launched from different roots get distinct
  identities and coexist. The engine resolution is shared by launch AND the control
  commands, so `status`/`pause`/`stop` derive the same identity as the launch.

  #443 extends this to global-config users (no repo-local `.aiur/config`): the
  walk-up stops at `$HOME` (the global `~/.aiur/config` is never a repo root) and
  falls back to `realpath($PWD)`, so each such project gets a distinct identity
  instead of colliding on an empty key or `$HOME`. The cwd-derived key has no repo
  root to converge on, so for a global-config run control commands must be invoked
  from the same directory the run was launched from (repo-local runs keep the
  walk-up and resolve from any subdir).
  """

  use ExUnit.Case, async: true

  @engine Path.expand("../../../../packaging/npm/aiur-cli/libexec/aiur-engine.sh", __DIR__)

  # Run the engine's `__identity` command and parse its KEY=VALUE printout.
  defp identity(root) do
    {out, 0} =
      System.cmd("bash", [@engine, "__identity"],
        # Reset the identity vars the engine exports — a key/node inherited from a
        # parent aiur (this suite dogfoods aiur) would otherwise subvert derivation.
        env: [
          {"AIUR_REPO_ROOT", root},
          {"AIUR_INSTANCE_KEY", nil},
          {"AIUR_RELEASE_NODE", nil},
          {"USER", "tester"}
        ],
        stderr_to_stdout: true
      )

    out
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case String.split(line, "=", parts: 2) do
        [k, v] -> [{k, v}]
        _ -> []
      end
    end)
    |> Map.new()
  end

  describe "per-instance identity derivation" do
    test "different project roots get different node names + keys (success criterion 1: no cross-reap)" do
      a = identity("/proj/alpha")
      b = identity("/proj/beta")

      assert a["AIUR_INSTANCE_KEY"] != ""
      assert b["AIUR_INSTANCE_KEY"] != ""
      refute a["AIUR_INSTANCE_KEY"] == b["AIUR_INSTANCE_KEY"]
      refute a["AIUR_RELEASE_NODE"] == b["AIUR_RELEASE_NODE"]
    end

    test "same project root is stable (success criterion 2: control resolves the launch identity)" do
      a1 = identity("/proj/alpha")
      a2 = identity("/proj/alpha")
      assert a1["AIUR_INSTANCE_KEY"] == a2["AIUR_INSTANCE_KEY"]
      assert a1["AIUR_RELEASE_NODE"] == a2["AIUR_RELEASE_NODE"]
    end

    test "the key is a short, node-name-legal lowercase-hex segment" do
      assert identity("/proj/alpha")["AIUR_INSTANCE_KEY"] =~ ~r/\A[0-9a-f]{1,12}\z/
    end

    test "no repo-local config keys by realpath($PWD), never the legacy empty key (#443)" do
      # #443 (bug case 1): a run with no repo-local `.aiur/config` anywhere up-tree
      # used to fall back to an empty key → the shared legacy node
      # `aiur-$USER@127.0.0.1`, so two such projects collided and reaped each other.
      # The project the BEAM serves is $PWD, so each now gets a distinct,
      # realpath-derived key. HOME is pinned to a sibling temp dir that holds no
      # config and is not an ancestor of the projects, so this genuinely exercises
      # the not-under-$HOME variant regardless of the runner's real $HOME/TMPDIR.
      base = Path.join(System.tmp_dir!(), "aiur-noconfig-#{System.pid()}-#{System.unique_integer([:positive])}")
      home = Path.join(base, "home")
      proj_a = Path.join(base, "alpha")
      proj_b = Path.join(base, "beta")
      File.mkdir_p!(home)
      File.mkdir_p!(proj_a)
      File.mkdir_p!(proj_b)
      on_exit(fn -> File.rm_rf!(base) end)

      id = fn cd ->
        {out, 0} =
          System.cmd("bash", [@engine, "__identity"],
            env: [
              {"HOME", home},
              {"AIUR_REPO_ROOT", ""},
              {"AIUR_INSTANCE_KEY", nil},
              {"AIUR_RELEASE_NODE", nil},
              {"USER", "tester"}
            ],
            cd: cd,
            stderr_to_stdout: true
          )

        out
        |> String.split("\n", trim: true)
        |> Enum.flat_map(fn line ->
          case String.split(line, "=", parts: 2) do
            [k, v] -> [{k, v}]
            _ -> []
          end
        end)
        |> Map.new()
      end

      a = id.(proj_a)
      b = id.(proj_b)

      # A real, node-name-legal key — not the empty/legacy fallback.
      assert a["AIUR_INSTANCE_KEY"] =~ ~r/\A[0-9a-f]{1,12}\z/
      assert a["AIUR_RELEASE_NODE"] =~ ~r/\Aaiur-tester-[0-9a-f]{1,12}@127\.0\.0\.1\z/
      refute a["AIUR_RELEASE_NODE"] == "aiur-tester@127.0.0.1"
      # Two distinct no-config projects never share an identity (the #443 collision).
      refute a["AIUR_INSTANCE_KEY"] == b["AIUR_INSTANCE_KEY"]
      # Stable across invocations from the same cwd — the control-command criterion
      # for global-config runs (status/pause/stop must resolve the launch identity).
      assert id.(proj_a)["AIUR_INSTANCE_KEY"] == a["AIUR_INSTANCE_KEY"]
    end

    test "projects under $HOME with only a global ~/.aiur/config get distinct keys, not $HOME's (#443)" do
      # #443 (bug case 2): the global config lives at ~/.aiur/config. The walk-up
      # must NOT treat it as a repo root, or every project under $HOME collapses
      # onto hash($HOME) and they reap each other. A fake $HOME holds the global
      # config; two projects beneath it must derive distinct, non-$HOME keys.
      home = Path.join(System.tmp_dir!(), "aiur-home-#{System.pid()}-#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(home, ".aiur"))
      File.write!(Path.join([home, ".aiur", "config"]), "")
      proj_a = Path.join([home, "projects", "alpha"])
      proj_b = Path.join([home, "projects", "beta"])
      File.mkdir_p!(proj_a)
      File.mkdir_p!(proj_b)
      on_exit(fn -> File.rm_rf!(home) end)

      key = fn cd ->
        {out, 0} =
          System.cmd("bash", [@engine, "__identity"],
            env: [
              {"HOME", home},
              {"AIUR_REPO_ROOT", ""},
              {"AIUR_INSTANCE_KEY", nil},
              {"AIUR_RELEASE_NODE", nil},
              {"USER", "tester"}
            ],
            cd: cd,
            stderr_to_stdout: true
          )

        out
        |> String.split("\n", trim: true)
        |> Enum.find_value(fn line ->
          case String.split(line, "=", parts: 2) do
            ["AIUR_INSTANCE_KEY", v] -> v
            _ -> nil
          end
        end)
      end

      ka = key.(proj_a)
      kb = key.(proj_b)
      khome = key.(home)

      for k <- [ka, kb, khome], do: assert(k =~ ~r/\A[0-9a-f]{1,12}\z/)
      # The walk-up stops at $HOME, so no two projects collapse together and none
      # collapses onto $HOME's own key.
      refute ka == kb
      refute ka == khome
      refute kb == khome
    end

    test "walk-up from cwd: a subdir and the project root derive the same key; a sibling root differs" do
      # AIUR_REPO_ROOT unset, so the key is derived by walking $PWD up to `.aiur/config`
      # — the real launch/control path that explicit-root tests never exercise.
      base = Path.join(System.tmp_dir!(), "aiur-walkup-#{System.pid()}-#{System.unique_integer([:positive])}")
      root_a = Path.join(base, "projA")
      deep_a = Path.join([root_a, "src", "deep"])
      root_b = Path.join(base, "projB")
      File.mkdir_p!(Path.join(root_a, ".aiur"))
      File.write!(Path.join([root_a, ".aiur", "config"]), "")
      File.mkdir_p!(deep_a)
      File.mkdir_p!(Path.join(root_b, ".aiur"))
      File.write!(Path.join([root_b, ".aiur", "config"]), "")
      on_exit(fn -> File.rm_rf!(base) end)

      key = fn cd ->
        {out, 0} =
          System.cmd("bash", [@engine, "__identity"],
            env: [
              {"AIUR_REPO_ROOT", nil},
              {"AIUR_INSTANCE_KEY", nil},
              {"AIUR_RELEASE_NODE", nil},
              {"USER", "tester"}
            ],
            cd: cd,
            stderr_to_stdout: true
          )

        out
        |> String.split("\n", trim: true)
        |> Enum.find_value(fn line ->
          case String.split(line, "=", parts: 2) do
            ["AIUR_INSTANCE_KEY", v] -> v
            _ -> nil
          end
        end)
      end

      root_key = key.(root_a)
      assert root_key not in [nil, ""]
      # control invoked from a subdir must resolve the launch's identity (criterion 2)
      assert key.(deep_a) == root_key
      # a different project root gets a different identity (criterion 1)
      refute key.(root_b) == root_key
    end
  end

  describe "engine wiring (source asserts)" do
    test "tmux session and socket are keyed per-instance" do
      src = File.read!(@engine)

      assert String.contains?(src, ~S(${AIUR_SESSION_PREFIX}-${USER:-user}${AIUR_INSTANCE_KEY:+-$AIUR_INSTANCE_KEY}-default)),
             "the tmux session name must include AIUR_INSTANCE_KEY so two instances never share a session"

      assert String.contains?(src, ~S(${AIUR_SESSION_PREFIX}-${USER:-user}${AIUR_INSTANCE_KEY:+-$AIUR_INSTANCE_KEY}")),
             "the tmux socket must include AIUR_INSTANCE_KEY"
    end

    test "launch reclaims a legacy un-keyed orphan, guarded by a live-session check (success criterion 3)" do
      src = File.read!(@engine)

      assert String.contains?(src, ~S(kill_beams_matching "-name aiur-${USER}@127.0.0.1")),
             "a keyed launch must reclaim a stale legacy-name beam so the old fixed name doesn't block startup"

      assert String.contains?(src, ~S(has-session -t "${legacy_socket}-default")),
             "the legacy reclaim must be guarded by a has-session check so a live legacy run is never killed"
    end
  end
end
