defmodule VoiceConverse.AgentFork.CodexTest do
  use ExUnit.Case, async: false

  import VoiceConverse.AgentForkStubs

  alias VoiceConverse.AgentFork
  alias VoiceConverse.AgentForkStubs

  @parent_id AgentForkStubs.parent_id()
  @fork_thread "fork-thread-0001"

  setup do
    %{root: tmp_root()}
  end

  describe "Codex native fork" do
    test "codex fork params are ephemeral read-only", ctx do
      parent = codex_parent(ctx.root)
      exe = codex_stub(ctx.root, parent, @fork_thread)

      assert {:ok, ref} = AgentFork.fork(codex_handle(parent), "why that test?", codex_executable: exe)
      assert_receive {:fork_answer, ^ref, "It covers the retry.", :native, usage}, 5_000
      assert is_integer(usage.first_token_ms)
      assert usage.tokens["total"]["totalTokens"] == 42

      assert recorded(ctx.root, "argv") == ["app-server", "--disable", "hooks", "-c", "notify=[]"]

      rpc = ctx.root |> recorded("rpc") |> Enum.map(&Jason.decode!/1)
      # Nothing else (no thread/resume, no turn on the parent) is ever sent.
      assert Enum.map(rpc, & &1["method"]) == ["initialize", "initialized", "thread/fork", "turn/start"]

      fork = Enum.find(rpc, &(&1["method"] == "thread/fork"))["params"]

      assert fork == %{
               "threadId" => @parent_id,
               "ephemeral" => true,
               "excludeTurns" => true,
               "sandbox" => "read-only",
               "approvalPolicy" => "never",
               "cwd" => parent.repo
             }

      # An in-progress lastTurnId is rejected; omitting it is the safe way to fork a busy parent.
      refute Map.has_key?(fork, "lastTurnId")

      turn = Enum.find(rpc, &(&1["method"] == "turn/start"))["params"]
      assert turn["threadId"] == @fork_thread
      assert turn["approvalPolicy"] == "never"
      assert turn["sandboxPolicy"] == %{"type" => "readOnly", "networkAccess" => false}
      assert [%{"type" => "text", "text" => prompt}] = turn["input"]
      assert prompt =~ AgentFork.read_only_note()
    end

    test "fork leaves the Codex parent unchanged", ctx do
      parent = codex_parent(ctx.root)
      exe = codex_stub(ctx.root, parent, @fork_thread)
      before = parent_state(parent.rollout, parent.sessions_dir, parent.repo)

      {:ok, ref} = AgentFork.fork(codex_handle(parent), "q", codex_executable: exe)
      assert_receive {:fork_answer, ^ref, _, :native, _}, 5_000

      assert parent_state(parent.rollout, parent.sessions_dir, parent.repo) == before
    end

    test "a fork that comes back as the parent thread is refused before any turn", ctx do
      parent = codex_parent(ctx.root)
      exe = codex_stub(ctx.root, parent, @parent_id)

      {:ok, ref} = AgentFork.fork(codex_handle(parent), "q", codex_executable: exe)
      assert_receive {:fork_failed, ^ref, :fork_not_isolated}, 5_000
      refute Enum.any?(recorded(ctx.root, "rpc"), &(&1 =~ "turn/start"))
    end
  end
end
