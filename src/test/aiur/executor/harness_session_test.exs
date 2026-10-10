defmodule Aiur.Executor.HarnessSessionTest do
  use Aiur.TestSupport

  alias Aiur.Executor.{Claims, HarnessSession}

  @uuid "0b1c2d3e-4f50-4a6b-8c7d-9e0f1a2b3c4d"
  # Fixture of the Claude Code 2.1.296 environment; the names are undocumented.
  @claude_env %{
    "CLAUDE_CODE_SESSION_ID" => @uuid,
    "CLAUDE_CONFIG_DIR" => "/home/u/.claude",
    "CLAUDE_PID" => "4242",
    "PWD" => "/work/repo"
  }

  setup do
    root = Aiur.TestSupport.tmp_root!("aiur-harness-session")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{opts: [path: Path.join(root, "claims.json")]}
  end

  defp encode(env), do: Enum.map(env, fn {key, value} -> {key, Base.encode64(value)} end)

  test "detects the Claude session from the environment" do
    assert %{"harness" => "claude", "session_id" => @uuid, "config_dir" => "/home/u/.claude", "harness_pid" => 4242, "cwd" => "/work/repo"} =
             HarnessSession.detect(@claude_env)
  end

  test "reads the Codex thread id first" do
    other = "11111111-2222-4333-8444-555555555555"
    assert %{"harness" => "codex", "session_id" => ^other, "harness_pid" => nil} = HarnessSession.detect(Map.put(@claude_env, "CODEX_THREAD_ID", other))
  end

  test "a child session detects nothing" do
    assert HarnessSession.detect(Map.put(@claude_env, "CLAUDE_CODE_CHILD_SESSION", "1")) == nil
  end

  test "a malformed session id detects nothing" do
    assert HarnessSession.detect(%{"CLAUDE_CODE_SESSION_ID" => "not-a-uuid"}) == nil
  end

  test "an explicit session id overrides the environment and defaults to claude" do
    other = "11111111-2222-4333-8444-555555555555"
    assert %{"harness" => "codex", "session_id" => ^other} = HarnessSession.resolve(session_id: other, harness: "codex", env: encode(@claude_env))
    assert %{"harness" => "claude", "session_id" => ^other, "harness_pid" => 4242} = HarnessSession.resolve(session_id: other, env: encode(@claude_env))
  end

  test "owner records the Claude session from the environment", %{opts: opts} do
    {:ok, entry} = Claims.claim("a", [session: HarnessSession.resolve(env: encode(@claude_env))] ++ opts)
    assert entry["session"]["session_id"] == @uuid
    assert is_binary(entry["session"]["recorded_at"])
  end

  test "child session does not register", %{opts: opts} do
    env = encode(Map.put(@claude_env, "CLAUDE_CODE_CHILD_SESSION", "1"))
    {:ok, entry} = Claims.claim("a", [session: HarnessSession.resolve(env: env)] ++ opts)
    refute Map.has_key?(entry, "session")
  end

  test "observer read does not write the session", %{opts: opts} do
    {:ok, _owner} = Claims.claim("a", opts)
    before = File.read!(opts[:path])
    assert {:error, {:held_by, _}} = Claims.claim("b", [session: HarnessSession.detect(@claude_env)] ++ opts)
    assert File.read!(opts[:path]) == before
    {:ok, observer} = Claims.observe("b", opts)
    refute Map.has_key?(observer, "session")
  end

  test "renew keeps the session and a new session id replaces it", %{opts: opts} do
    {:ok, _} = Claims.claim("a", [session: HarnessSession.detect(@claude_env)] ++ opts)
    assert {:ok, %{"session" => %{"session_id" => @uuid}}} = Claims.renew("a", opts)
    other = "11111111-2222-4333-8444-555555555555"
    assert {:ok, %{"session" => %{"session_id" => ^other}}} = Claims.claim("a", [session: HarnessSession.detect(%{@claude_env | "CLAUDE_CODE_SESSION_ID" => other})] ++ opts)
  end

  test "current returns the live handle", %{opts: opts} do
    session = HarnessSession.detect(Map.put(@claude_env, "CLAUDE_PID", System.pid()))
    {:ok, _} = Claims.claim("a", [session: session] ++ opts)
    assert %{"state" => "live", "session_id" => @uuid} = HarnessSession.current(opts)
  end

  test "dead harness pid reads as unknown", %{opts: opts} do
    {:ok, _} = Claims.claim("a", [session: HarnessSession.detect(Map.put(@claude_env, "CLAUDE_PID", "2147483646"))] ++ opts)
    assert %{"state" => "unknown", "reason" => "harness_pid_dead"} = HarnessSession.current(opts)
  end

  test "expired lease and missing session read as unknown", %{opts: opts} do
    assert %{"state" => "unknown", "reason" => "no_live_owner"} = HarnessSession.current(opts)
    {:ok, _} = Claims.claim("a", opts)
    assert %{"state" => "unknown", "reason" => "no_session"} = HarnessSession.current(opts)
    past = DateTime.add(DateTime.utc_now(), -10 * Claims.lease_ttl_ms(), :millisecond)
    {:ok, _} = Claims.claim("b", [session: HarnessSession.detect(@claude_env), now: past] ++ [path: opts[:path] <> ".2"])
    assert %{"reason" => "no_live_owner"} = HarnessSession.current(path: opts[:path] <> ".2")
  end

  test "session ids and harness names are validated" do
    assert HarnessSession.valid_session_id?(@uuid)
    refute HarnessSession.valid_session_id?("abc")
    assert HarnessSession.valid_harness?("codex")
    refute HarnessSession.valid_harness?("vim")
  end
end
