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
  """

  use ExUnit.Case, async: true

  @engine Path.expand("../../../../packaging/npm/aiur-cli/libexec/aiur-engine.sh", __DIR__)

  # Run the engine's `__identity` command and parse its KEY=VALUE printout.
  defp identity(root) do
    {out, 0} =
      System.cmd("bash", [@engine, "__identity"],
        env: [{"AIUR_REPO_ROOT", root}],
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

    test "no project resolves to the legacy un-keyed identity (backward compat)" do
      tmp = Path.join(System.tmp_dir!(), "aiur-noproj-#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)

      {out, 0} =
        System.cmd("bash", [@engine, "__identity"],
          env: [{"AIUR_REPO_ROOT", ""}],
          cd: tmp,
          stderr_to_stdout: true
        )

      user = System.get_env("USER") || System.get_env("LOGNAME")
      assert out =~ "AIUR_INSTANCE_KEY=\n"
      assert out =~ "AIUR_RELEASE_NODE=aiur-#{user}@127.0.0.1"
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
