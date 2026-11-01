defmodule Aiur.Executor.CheckCLITest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  alias Aiur.Executor.{CheckCLI, HookConfig, HookToken, Session, TranscriptFormat}

  setup do
    root = Aiur.TestSupport.tmp_root!("executor-check")
    previous = Application.fetch_env(:aiur, :executor_state_dir)
    key = System.get_env("AIUR_INSTANCE_KEY")
    ttl = Application.fetch_env(:aiur, :executor_session_ttl_ms)
    Application.put_env(:aiur, :executor_state_dir, Path.join(root, "state"))
    Application.put_env(:aiur, :executor_session_ttl_ms, 600_000)
    System.put_env("AIUR_INSTANCE_KEY", "check-test")
    now = DateTime.utc_now()
    start_supervised!({Session, instance_key: "check-test", clock: fn -> now end})

    on_exit(fn ->
      restore(:executor_state_dir, previous)
      restore(:executor_session_ttl_ms, ttl)
      if key, do: System.put_env("AIUR_INSTANCE_KEY", key), else: System.delete_env("AIUR_INSTANCE_KEY")
      Aiur.TestCleanup.rm_rf!(root)
    end)

    :ok = HookToken.ensure()
    :ok = HookConfig.write_url(1234)
    :ok = HookConfig.install(:claude, repo_root: root)
    path = Path.join(root, "transcript.jsonl")
    File.write!(path, "{}\n")
    %{opts: [repo_root: root, bound_port: 1234, now: now], path: path, now: now, root: root}
  end

  test "listener off has its own actionable failure", %{opts: opts} do
    assert row(Keyword.put(opts, :bound_port, nil), :listener) ==
             {:fail, "dashboard listener is off (started with --no-dashboard); restart without --no-dashboard"}
  end

  test "missing and detached bindings fail", %{opts: opts} do
    assert {:fail, "not attached: run aiur executor-attach --harness claude|codex"} = row(opts, :binding)
    {:ok, binding} = Session.attach(%{harness: "claude"})
    {:ok, _} = Session.detach(binding.binding_id, "stopped")
    assert {:fail, "not attached: run aiur executor-attach --harness claude|codex"} = row(opts, :binding)
  end

  test "each credential must exist and have mode 0600", %{opts: opts} do
    for path <- [HookToken.path(), HookToken.headers_path(), HookConfig.url_path()] do
      body = File.read!(path)
      File.chmod!(path, 0o644)
      assert {:fail, "hook credentials missing or readable by others;" <> _} = row(opts, :credentials)
      File.chmod!(path, 0o600)
      File.rm!(path)
      assert {:fail, _} = row(opts, :credentials)
      File.write!(path, body)
      File.chmod!(path, 0o600)
    end

    assert {:ok, _} = row(opts, :credentials)
  end

  test "Claude missing hooks fail", %{opts: opts, root: root} do
    Session.attach(%{harness: "claude"})
    File.write!(Path.join([root, ".claude", "settings.local.json"]), ~s({"hooks":{}}))
    assert {:fail, "hooks not installed; run aiur executor-attach --harness claude in this repository"} = row(opts, :hooks)
    assert :ok = HookConfig.install(:claude, repo_root: root)
    assert {:ok, "Claude hooks are installed"} = row(opts, :hooks)
  end

  test "never-received Codex hook is unknown, not ok", context do
    {:ok, binding} = Session.attach(%{harness: "codex"})
    assert {:unknown, "no hook yet: review and trust the hooks in Codex"} = row(context.opts, :hooks)
    assert {:unknown, "no hook yet; start or resume the Executor and enable its hooks"} = row(context.opts, :hook_age)
    {:ok, _} = Session.bind_provider_session(binding.binding_id, %{session_id: "one", transcript_path: context.path})
    assert {:ok, "Codex hook received"} = row(context.opts, :hooks)
  end

  test "stale hook reports minutes with TTL boundary", context do
    attached(context)
    assert {:ok, "last hook 10 min ago"} = row(Keyword.put(context.opts, :now, DateTime.add(context.now, 600)), :hook_age)

    assert {:fail, "no hook for 11 min; resume the Executor and confirm hooks are enabled"} =
             row(Keyword.put(context.opts, :now, DateTime.add(context.now, 660)), :hook_age)
  end

  test "unreadable transcript reports filesystem reason", context do
    attached(context)
    File.rm!(context.path)
    assert {:fail, "transcript unreadable: enoent; resume the Executor to refresh its path and permissions"} = row(context.opts, :transcript)
  end

  test "drift latch reports version", context do
    binding = attached(context)
    format = TranscriptFormat.new() |> Map.merge(%{"alerted" => true, "total" => 200, "untested_version" => "9.0.0"})
    assert {:ok, _} = Session.record_checkpoint(binding, 3, format)
    assert {:fail, "transcript format changed (version 9.0.0); update the transcript adapter before reattaching"} = row(context.opts, :drift)
  end

  test "no transcript observations stay unknown", context do
    Session.attach(%{harness: "claude"})
    assert {:unknown, "transcript path unknown; start or resume the Executor to send a hook"} = row(context.opts, :transcript)
    assert {:unknown, "transcript format unknown; wait for transcript records after the first hook"} = row(context.opts, :drift)
  end

  test "all ok exits zero; fail and unknown exit one with JSON evidence and no mutation", context do
    output = capture_io(fn -> assert CheckCLI.run(Keyword.put(context.opts, :json, true)) == 1 end)
    assert Enum.any?(Jason.decode!(output), &(&1["check"] == "binding" and &1["status"] == "fail"))
    binding = attached(context)
    assert {:ok, _} = Session.record_checkpoint(binding, 3, TranscriptFormat.count(TranscriptFormat.new(), %{"type" => "user", "version" => "2.1.299"}))
    before = Session.current()
    output = capture_io(fn -> assert CheckCLI.run(Keyword.put(context.opts, :json, true)) == 0 end)
    rows = Jason.decode!(output)
    assert length(rows) == 7
    assert Enum.all?(rows, &(&1["status"] == "ok" and &1["observed_at"] == DateTime.to_iso8601(context.now)))
    assert Session.current() == before
    assert capture_io(fn -> assert CheckCLI.run(Keyword.put(context.opts, :bound_port, nil)) == 1 end) =~ "listener: fail — dashboard listener is off"
    {:ok, _} = Session.attach(%{harness: "codex", takeover?: true})
    capture_io(fn -> assert CheckCLI.run(context.opts) == 1 end)
  end

  test "public control RPC exposes check without attaching", context do
    output = capture_io(fn -> Aiur.AgentControlCLI.executor_check(repo_root: context.root, json: true) end)
    assert output =~ "__AIUR_CONTROL_EXIT__:1"
    assert output =~ "not attached: run aiur executor-attach"
    assert Session.current() == :none
  end

  defp attached(context) do
    {:ok, binding} = Session.attach(%{harness: "claude"})
    {:ok, binding} = Session.bind_provider_session(binding.binding_id, %{session_id: "one", transcript_path: context.path})
    binding
  end

  defp row(opts, check) do
    row = Enum.find(CheckCLI.checks(opts), &(&1.check == check))
    {row.status, row.detail}
  end

  defp restore(key, :error), do: Application.delete_env(:aiur, key)
  defp restore(key, {:ok, value}), do: Application.put_env(:aiur, key, value)
end
