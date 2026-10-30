Code.require_file("../conversation/journal_support.exs", __DIR__)

defmodule Aiur.Executor.AttachCLIDetachTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  alias Aiur.Conversation.TestSupport
  alias Aiur.Executor.{AttachCLI, HookConfig, HookToken, Session, SessionIngest}

  setup context do
    context = TestSupport.setup(context)
    root = context.root
    previous = Application.fetch_env(:aiur, :executor_state_dir)
    key = System.get_env("AIUR_INSTANCE_KEY")
    Application.put_env(:aiur, :executor_state_dir, Path.join(root, "state"))
    System.put_env("AIUR_INSTANCE_KEY", "detach-test")
    start_supervised!({Session, instance_key: "detach-test"})
    start_supervised!({SessionIngest, pubsub: context.pubsub})
    path = Path.join([root, ".claude", "settings.local.json"])
    File.mkdir_p!(Path.dirname(path))
    original = ~s({"permissions":{"allow":["Read"]},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo user"}]}]}})
    File.write!(path, original)

    on_exit(fn ->
      if previous == :error,
        do: Application.delete_env(:aiur, :executor_state_dir),
        else: Application.put_env(:aiur, :executor_state_dir, elem(previous, 1))

      if key,
        do: System.put_env("AIUR_INSTANCE_KEY", key),
        else: System.delete_env("AIUR_INSTANCE_KEY")
    end)

    %{opts: [harness: "claude", repo_root: root, bound_port: 1234], path: path, original: original}
  end

  test "detach after SessionEnd rotates and uninstalls, and repeated detach succeeds", %{opts: opts, path: path, original: original} do
    capture_io(fn -> assert AttachCLI.run_attach(opts) == 0 end)
    assert {:ok, token} = HookToken.read()
    dispatch("SessionStart")
    assert SessionIngest.rejected_counts() == %{}
    dispatch("SessionEnd")
    assert SessionIngest.rejected_counts() == %{}
    assert {:ok, %{state: "detached", end_reason: "stopped"} = binding} = Session.current()
    assert File.read!(path) =~ "AIUR_EXECUTOR_HOOK=1"

    assert capture_io(fn -> assert AttachCLI.run_detach(opts) == 0 end) ==
             "DETACHED binding=#{binding.binding_id}\n"

    assert {:ok, fresh} = HookToken.read()
    refute fresh == token
    assert authentication(token).status == 401
    refute authentication(fresh).halted
    assert File.read!(path) == original

    assert capture_io(fn -> assert AttachCLI.run_detach(opts) == 0 end) ==
             "DETACHED binding=#{binding.binding_id}\n"

    assert {:ok, repeated} = HookToken.read()
    refute repeated == fresh
    assert authentication(fresh).status == 401
    refute authentication(repeated).halted
    assert File.read!(path) == original
  end

  test "detach with no binding revokes stale hooks and token while preserving user settings", %{opts: opts, path: path, original: original} do
    assert Session.current() == :none
    assert :ok = HookToken.ensure()
    assert {:ok, token} = HookToken.read()
    assert :ok = HookConfig.install(:claude, repo_root: opts[:repo_root])
    assert File.read!(path) =~ "AIUR_EXECUTOR_HOOK=1"

    assert capture_io(fn -> assert AttachCLI.run_detach(opts) == 0 end) ==
             "DETACHED (no Executor binding)\n"

    assert {:ok, fresh} = HookToken.read()
    refute fresh == token
    assert authentication(token).status == 401
    refute authentication(fresh).halted
    assert File.read!(path) == original
    assert Session.current() == :none
  end

  defp dispatch(event) do
    SessionIngest.dispatch(%{"hook_event_name" => event, "session_id" => "one", "pid" => "123"}, "claude")
  end

  defp authentication(token) do
    Plug.Test.conn(:post, "/api/v1/executor/hook")
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
    |> AiurWeb.ExecutorHookAuth.call([])
  end
end
