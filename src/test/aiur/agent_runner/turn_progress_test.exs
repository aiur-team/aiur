defmodule Aiur.AgentRunner.TurnProgressTest do
  # #2806: the witnesses the continuation loop uses to decide that a turn
  # changed nothing. Each one has to be observable from inside the loop and has
  # to move for a turn that did real work, or the bound would either never fire
  # or would punish a productive run.
  use Aiur.TestSupport

  alias Aiur.AgentRunner.TurnProgress
  alias Aiur.Issue

  defp issue(overrides \\ []) do
    struct(%Issue{id: "gid-tp", identifier: "TP-1", state: "in-progress", labels: ["agent:in-progress"]}, overrides)
  end

  defp static_probe(digest), do: fn _workspace, _worker_host -> {:ok, digest} end

  defp continuation_prompt(turn_number) do
    "Continuation guidance:\n\n- This is continuation turn ##{turn_number} of 9 for the current agent run.\n- Do the work.\n"
  end

  describe "prompt_digest/1" do
    test "ignores the turn counter, which every continuation prompt varies" do
      assert TurnProgress.prompt_digest(continuation_prompt(2)) ==
               TurnProgress.prompt_digest(continuation_prompt(3))
    end

    test "ignores the loop's own no-op notice, which carries the running count" do
      base = continuation_prompt(4)

      with_notice =
        String.replace(
          base,
          "- Do the work.",
          "    - Aiur observed that the last 2 turn(s) changed nothing it can see.\n- Do the work."
        )

      assert TurnProgress.prompt_digest(base) == TurnProgress.prompt_digest(with_notice)
    end

    test "changes when the instructions change — real new input is not normalized away" do
      refute TurnProgress.prompt_digest(continuation_prompt(2)) ==
               TurnProgress.prompt_digest(continuation_prompt(2) <> "- The operator asked for X.\n")
    end
  end

  describe "observe/2" do
    test "turn 1 is never a no-op: there is no previous turn to compare it to" do
      witness = TurnProgress.witness(continuation_prompt(1), "/ws", nil, issue(), workspace_probe: static_probe("a"))

      assert {:progress, %{consecutive_noops: 0}} = TurnProgress.observe(TurnProgress.empty(), witness)
    end

    test "counts consecutive turns with identical witnesses" do
      opts = [workspace_probe: static_probe("same")]
      first = TurnProgress.witness(continuation_prompt(2), "/ws", nil, issue(), opts)
      second = TurnProgress.witness(continuation_prompt(3), "/ws", nil, issue(), opts)
      third = TurnProgress.witness(continuation_prompt(4), "/ws", nil, issue(), opts)

      {:progress, state} = TurnProgress.observe(TurnProgress.empty(), first)
      {:noop, state} = TurnProgress.observe(state, second)
      assert state.consecutive_noops == 1
      {:noop, state} = TurnProgress.observe(state, third)
      assert state.consecutive_noops == 2
    end

    test "a workspace change resets the count — a committing turn is productive" do
      first = TurnProgress.witness(continuation_prompt(2), "/ws", nil, issue(), workspace_probe: static_probe("before"))
      second = TurnProgress.witness(continuation_prompt(3), "/ws", nil, issue(), workspace_probe: static_probe("before"))
      third = TurnProgress.witness(continuation_prompt(4), "/ws", nil, issue(), workspace_probe: static_probe("after"))

      {:progress, state} = TurnProgress.observe(TurnProgress.empty(), first)
      {:noop, state} = TurnProgress.observe(state, second)
      assert state.consecutive_noops == 1

      assert {:progress, %{consecutive_noops: 0}} = TurnProgress.observe(state, third)
    end

    test "a label transition resets the count" do
      opts = [workspace_probe: static_probe("same")]
      first = TurnProgress.witness(continuation_prompt(2), "/ws", nil, issue(), opts)
      second = TurnProgress.witness(continuation_prompt(3), "/ws", nil, issue(), opts)

      moved =
        TurnProgress.witness(
          continuation_prompt(4),
          "/ws",
          nil,
          issue(state: "merging", labels: ["agent:merging"]),
          opts
        )

      {:progress, state} = TurnProgress.observe(TurnProgress.empty(), first)
      {:noop, state} = TurnProgress.observe(state, second)
      assert {:progress, %{consecutive_noops: 0}} = TurnProgress.observe(state, moved)
    end
  end

  describe "from_opts/1" do
    test "defaults to an empty run and ignores a malformed carry" do
      assert TurnProgress.from_opts([]) == TurnProgress.empty()
      assert TurnProgress.from_opts(turn_progress: :garbage) == TurnProgress.empty()

      carried = %{consecutive_noops: 2, witness: %{prompt: "p", workspace: "w", issue: %{}}}
      assert TurnProgress.from_opts(turn_progress: carried) == carried
    end
  end

  describe "workspace_digest/2" do
    setup do
      root = Aiur.TestSupport.tmp_root!("turn-progress-git")
      workspace = Path.join(root, "ws")
      File.mkdir_p!(workspace)

      {_out, 0} = System.cmd("git", ["init", "--quiet", workspace], stderr_to_stdout: true)
      File.write!(Path.join(workspace, "a.txt"), "one\n")
      git!(workspace, ["add", "."])
      git!(workspace, ["-c", "user.name=T", "-c", "user.email=t@example.com", "commit", "--quiet", "-m", "first"])

      on_exit(fn -> File.rm_rf(root) end)
      %{workspace: workspace}
    end

    test "is stable across a turn that changed nothing", %{workspace: workspace} do
      assert {:ok, digest} = TurnProgress.workspace_digest(workspace, nil)
      # Reading files is not work: the digest is content-based, not mtime-based.
      assert File.read!(Path.join(workspace, "a.txt")) == "one\n"
      assert {:ok, ^digest} = TurnProgress.workspace_digest(workspace, nil)
    end

    test "moves for a commit", %{workspace: workspace} do
      {:ok, before_digest} = TurnProgress.workspace_digest(workspace, nil)
      File.write!(Path.join(workspace, "a.txt"), "two\n")
      git!(workspace, ["add", "."])
      git!(workspace, ["-c", "user.name=T", "-c", "user.email=t@example.com", "commit", "--quiet", "-m", "second"])

      assert {:ok, after_digest} = TurnProgress.workspace_digest(workspace, nil)
      refute after_digest == before_digest
    end

    test "moves for uncommitted and untracked work", %{workspace: workspace} do
      {:ok, before_digest} = TurnProgress.workspace_digest(workspace, nil)
      File.write!(Path.join(workspace, "b.txt"), "new\n")

      assert {:ok, after_digest} = TurnProgress.workspace_digest(workspace, nil)
      refute after_digest == before_digest
    end

    test "reports an unprobeable workspace instead of guessing", %{workspace: workspace} do
      assert {:error, {:workspace_probe_failed, 65, _}} =
               TurnProgress.workspace_digest(Path.join(workspace, "missing"), nil)

      assert {:error, {:workspace_probe_no_workspace, nil}} = TurnProgress.workspace_digest(nil, nil)
    end
  end

  defp git!(workspace, args) do
    {_out, 0} = System.cmd("git", ["-C", workspace | args], stderr_to_stdout: true)
    :ok
  end
end
