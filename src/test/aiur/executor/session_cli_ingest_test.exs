defmodule Aiur.Executor.SessionCLIIngestTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  alias Aiur.Executor.{BackgroundAgents, Claims, HarnessState, Session, SessionCLI, SessionIngest}
  alias Aiur.ExecutorWakeInbox
  alias Aiur.TestSupport.Isolation

  setup context do
    root = Aiur.TestSupport.tmp_root!("executor-cli-ingest")
    previous = Application.fetch_env(:aiur, :executor_state_dir)
    Application.put_env(:aiur, :executor_state_dir, root)
    start_supervised!({Session, instance_key: "cli-ingest"})
    {pubsub, _topic} = Isolation.start_pubsub!(context)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:aiur, :executor_state_dir, value)
        :error -> Application.delete_env(:aiur, :executor_state_dir)
      end

      Aiur.TestCleanup.rm_rf!(root)
    end)

    %{pubsub: pubsub, opts: [json: true, path: Path.join(root, "claims.json")]}
  end

  test "unattached hooks rejected by ingestion appear in CLI counters", %{pubsub: pubsub, opts: opts} do
    start_supervised!({SessionIngest, pubsub: pubsub})
    dispatch("SessionStart")
    assert SessionIngest.rejected_counts() == %{not_attached: 1}
    assert Session.rejected_counts() == %{}

    status = status(opts)
    assert status["recording?"] == true
    assert status["read_capability"]["status"] == "unknown"
    assert status["read_capability"]["reason"] == "awaiting_first_hook"
    assert status["not_attached_count"] == 1
    assert status["foreign_session_count"] == 0

    assert capture_io(fn -> SessionCLI.run(Keyword.put(opts, :json, false)) end) =~
             "recording=true foreign_session=0 not_attached=1"
  end

  test "harness and forwarded session rejections are counted once by ingestion", %{pubsub: pubsub, opts: opts} do
    start_supervised!({SessionIngest, pubsub: pubsub})
    assert {:ok, _binding} = Session.attach(%{harness: "claude"})
    dispatch("SessionStart", "one", "codex")
    assert SessionIngest.rejected_counts() == %{foreign_session: 1}
    assert Session.rejected_counts() == %{}
    assert status(opts)["foreign_session_count"] == 1

    dispatch("SessionStart")
    assert SessionIngest.rejected_counts() == %{foreign_session: 1}
    assert {:ok, %{provider_session_id: "one"}} = Session.current()

    dispatch("Stop", "foreign")
    assert SessionIngest.rejected_counts() == %{foreign_session: 2}
    assert Session.rejected_counts() == %{foreign_session: 1}
    assert status(opts)["foreign_session_count"] == 2
  end

  test "disabled ingestion reports recording false and unavailable counters", %{opts: opts} do
    assert Process.whereis(SessionIngest) == nil
    status = status(opts)
    assert status["recording?"] == false
    assert status["read_capability"]["status"] == "unknown"
    assert Map.fetch!(status, "transcript_rejection") == "unknown"
    assert status["not_attached_count"] == nil
    assert status["foreign_session_count"] == nil

    assert capture_io(fn -> SessionCLI.run(Keyword.put(opts, :json, false)) end) =~
             "recording=false foreign_session=unknown not_attached=unknown"
  end

  test "JSON includes the live projections, wake depth, and hook ages", %{pubsub: pubsub, opts: opts} do
    now = DateTime.utc_now()
    at = DateTime.add(now, -5, :second)
    start_supervised!({ExecutorWakeInbox, debounce_ms: 0})
    start_supervised!({BackgroundAgents, pubsub: pubsub})
    start_supervised!({HarnessState, pubsub: pubsub, interval_ms: nil, clock: fn -> now end})
    assert {:ok, %{binding_id: id}} = Session.attach(%{harness: "claude"})
    assert {:ok, _binding} = Session.bind_provider_session(id, %{session_id: "executor-session", cwd: "/private/executor"})
    assert {:ok, _binding} = Session.touch(id, at)
    assert {:ok, _claim} = Claims.observe("listener", path: opts[:path], now: now)
    assert :ok = ExecutorWakeInbox.enqueue(%{"kind" => "attention", "source_id" => 1, "ticket" => "42"})
    send(HarnessState, {:executor_hook, %{event: "PostToolUse", observed_at: at}})
    assert %{state: :working} = HarnessState.snapshot()

    status = status(Keyword.put(opts, :now, now))
    assert status["attached"] == true
    assert status["observed_at"] == DateTime.to_iso8601(now)
    assert %{"binding_id" => ^id, "age_ms" => 5_000, "freshness" => "fresh"} = status["binding"]
    refute Map.has_key?(status["binding"], "cwd")
    assert %{"state" => "working", "observed_at" => timestamp, "age_ms" => 5_000, "freshness" => "fresh"} = status["harness_state"]
    assert timestamp == DateTime.to_iso8601(at)
    assert status["background_agents"] == %{"status" => "ok", "agents" => []}
    assert %{"items" => items, "sources" => %{"commands" => %{"status" => _}}, "observed_at" => _} = status["blockers"]
    assert is_list(items)
    assert status["wakes"] == %{"cursor" => 0, "pending_count" => 1}
    assert [%{"id" => "listener", "pending_count" => 1}] = status["roster"]
  end

  defp status(opts), do: Jason.decode!(capture_io(fn -> assert SessionCLI.run(opts) == 0 end))

  defp dispatch(event, id \\ "one", harness \\ "claude") do
    SessionIngest.dispatch(%{"hook_event_name" => event, "session_id" => id, "pid" => "123", "source" => "startup"}, harness)
  end
end
