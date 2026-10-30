defmodule Aiur.AgentControlCLIExecutorSessionTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  alias Aiur.Executor.{AttachCLI, HookToken, Session, SessionCLI}

  setup do
    root = Aiur.TestSupport.tmp_root!("executor-cli")
    previous = Application.fetch_env(:aiur, :executor_state_dir)
    key = System.get_env("AIUR_INSTANCE_KEY")
    Application.put_env(:aiur, :executor_state_dir, root)
    System.put_env("AIUR_INSTANCE_KEY", "cli-test")
    start_supervised!({Session, instance_key: "cli-test"})

    on_exit(fn ->
      if previous == :error,
        do: Application.delete_env(:aiur, :executor_state_dir),
        else: Application.put_env(:aiur, :executor_state_dir, elem(previous, 1))

      if key,
        do: System.put_env("AIUR_INSTANCE_KEY", key),
        else: System.delete_env("AIUR_INSTANCE_KEY")

      Aiur.TestCleanup.rm_rf!(root)
    end)

    %{root: root, opts: [harness: "claude", repo_root: root, bound_port: 1234]}
  end

  test "RPC allows binding reads but refuses remote repository writes", %{root: root} do
    assert {:ok, %{scope: :read}} =
             Aiur.ControlCall.parse("Aiur.AgentControlCLI.executor_session(json: true)")

    assert {:error, :denied_remote} =
             Aiur.ControlCall.parse(~s|Aiur.AgentControlCLI.executor_attach(harness: "claude", repo_root: "#{root}")|)

    assert {:error, :denied_remote} =
             Aiur.ControlCall.parse(~s|Aiur.AgentControlCLI.executor_detach(repo_root: "#{root}")|)

    assert {:error, :option_not_allowed} =
             Aiur.ControlCall.parse("Aiur.AgentControlCLI.executor_session(bound_port: 42)")
  end

  test "public control RPC emits binding status and exit markers", %{root: root} do
    assert capture_io(fn ->
             Aiur.AgentControlCLI.executor_attach(harness: "claude", repo_root: root)
           end) =~ "__AIUR_CONTROL_EXIT__:69"

    output = capture_io(fn -> Aiur.AgentControlCLI.executor_session(json: true) end)
    assert output =~ "__AIUR_CONTROL_EXIT__:0"
    assert output =~ "\"freshness\":\"unknown\""
    assert output =~ "\"state\":\"detached\""
  end

  test "attach requires a listener and instance key before creating state", %{opts: opts} do
    output =
      capture_io(fn ->
        assert AttachCLI.run_attach(Keyword.put(opts, :bound_port, nil)) == 69
      end)

    assert output =~ "restart without --no-dashboard"
    assert Session.current() == :none
    assert HookToken.read() == {:error, :enoent}
    System.delete_env("AIUR_INSTANCE_KEY")

    assert capture_io(fn -> assert AttachCLI.run_attach(opts) == 69 end) =~
             "AIUR_INSTANCE_KEY"
  end

  test "attach installs hooks, refuses replacement and permits takeover", %{
    opts: opts,
    root: root
  } do
    output = capture_io(fn -> assert AttachCLI.run_attach(opts) == 0 end)
    assert {:ok, first} = Session.current()

    assert output =~
             "ATTACHED binding=#{first.binding_id} harness=claude state=awaiting_first_hook"

    assert {:ok, _token} = HookToken.read()
    assert File.read!(Path.join(root, ".claude/settings.local.json")) =~ "AIUR_EXECUTOR_HOOK=1"
    refusal = capture_io(fn -> assert AttachCLI.run_attach(opts) == 75 end)
    assert refusal =~ "binding=#{first.binding_id} harness=claude age_ms=unknown; use --takeover"

    takeover =
      capture_io(fn ->
        assert AttachCLI.run_attach(Keyword.put(opts, :takeover?, true)) == 0
      end)

    assert takeover =~ "SUPERSEDED binding=#{first.binding_id}"
    assert {:ok, replacement} = Session.current()
    refute replacement.binding_id == first.binding_id
  end

  test "detach removes hooks and rotates authentication", %{opts: opts, root: root} do
    capture_io(fn -> assert AttachCLI.run_attach(opts) == 0 end)
    {:ok, old} = HookToken.read()
    {:ok, binding} = Session.current()

    assert capture_io(fn -> assert AttachCLI.run_detach(opts) == 0 end) =~
             "DETACHED binding=#{binding.binding_id}"

    assert {:ok, fresh} = HookToken.read()
    refute fresh == old

    conn =
      Plug.Test.conn(:post, "/api/v1/executor/hook")
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> old)

    assert AiurWeb.ExecutorHookAuth.call(conn, []).status == 401

    conn =
      Plug.Test.conn(:post, "/api/v1/executor/hook")
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> fresh)

    refute AiurWeb.ExecutorHookAuth.call(conn, []).halted
    refute File.read!(Path.join(root, ".claude/settings.local.json")) =~ "AIUR_EXECUTOR_HOOK=1"
    assert {:ok, %{state: "detached", end_reason: "stopped"}} = Session.current()
  end

  test "failed install keeps pending binding and prints the settings path", %{
    opts: opts,
    root: root
  } do
    File.write!(Path.join(root, ".claude"), "a file blocks the directory")
    output = capture_io(fn -> assert AttachCLI.run_attach(opts) == 73 end)
    assert output =~ Path.join(root, ".claude/settings.local.json")
    assert {:ok, %{state: "awaiting_first_hook"}} = Session.current()

    assert capture_io(fn ->
             assert AttachCLI.run_attach(Keyword.merge(opts, takeover?: true, print_config: true)) == 0
           end) =~ "AIUR_EXECUTOR_HOOK=1"
  end

  test "print config and Codex leave repository settings untouched", %{opts: opts, root: root} do
    assert capture_io(fn ->
             assert AttachCLI.run_attach(Keyword.put(opts, :print_config, true)) == 0
           end) =~ "AIUR_EXECUTOR_HOOK=1"

    refute File.exists?(Path.join(root, ".claude"))

    output =
      capture_io(fn ->
        assert AttachCLI.run_attach(Keyword.merge(opts, harness: "codex", takeover?: true)) ==
                 0
      end)

    assert output =~ "trust the hooks in Codex"
    refute File.exists?(Path.join(root, ".codex"))
  end

  test "session renders unknown hook age then real age and rejection counters", %{
    opts: opts,
    root: root
  } do
    assert {:ok, _binding} = Session.attach(%{harness: "claude"})
    now = DateTime.utc_now()
    read_opts = [json: true, now: now, path: Path.join(root, "claims.json")]
    data = Jason.decode!(capture_io(fn -> assert SessionCLI.run(read_opts) == 0 end))
    assert data["observed_at"] == DateTime.to_iso8601(now)
    assert data["age_ms"] == nil
    assert data["freshness"] == "unknown"
    refute Map.has_key?(data, "transcript_path")
    {:ok, binding} = Session.current()
    assert {:ok, _} = Session.bind_provider_session(binding.binding_id, %{session_id: "one"})
    assert {:ok, _} = Session.touch(binding.binding_id, DateTime.add(now, -5, :second))

    assert {:error, :foreign_session} =
             Session.bind_provider_session(binding.binding_id, %{session_id: "other"})

    assert {:error, :not_attached} = Session.touch("wrong-binding", now)
    data = Jason.decode!(capture_io(fn -> SessionCLI.run(read_opts) end))
    assert data["age_ms"] == 5000
    assert data["freshness"] == "fresh"
    assert data["foreign_session_count"] == 1
    assert data["not_attached_count"] == 1

    assert capture_io(fn -> SessionCLI.run(Keyword.put(read_opts, :json, false)) end) =~
             "age_ms=5000 freshness=fresh"

    assert {:ok, _} = Session.touch(binding.binding_id, DateTime.add(now, -3600, :second))
    stale = Jason.decode!(capture_io(fn -> SessionCLI.run(read_opts) end))
    assert stale["age_ms"] == 3_600_000
    assert stale["freshness"] == "stale"
  end
end
