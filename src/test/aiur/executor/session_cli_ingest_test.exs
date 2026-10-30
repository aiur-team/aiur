defmodule Aiur.Executor.SessionCLIIngestTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  alias Aiur.Executor.{Session, SessionCLI, SessionIngest}
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
    assert status["not_attached_count"] == nil
    assert status["foreign_session_count"] == nil

    assert capture_io(fn -> SessionCLI.run(Keyword.put(opts, :json, false)) end) =~
             "recording=false foreign_session=unknown not_attached=unknown"
  end

  defp status(opts), do: Jason.decode!(capture_io(fn -> assert SessionCLI.run(opts) == 0 end))

  defp dispatch(event, id \\ "one", harness \\ "claude") do
    SessionIngest.dispatch(%{"hook_event_name" => event, "session_id" => id, "pid" => "123", "source" => "startup"}, harness)
  end
end
