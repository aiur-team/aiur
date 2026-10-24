Code.require_file(Path.expand("../orchestrator/control_cli/fixture.exs", __DIR__))

defmodule Aiur.ExecutorAttentionCliAlertsTest do
  use Aiur.TestSupport

  import ExUnit.CaptureIO

  alias Aiur.AlertLedger

  alias Aiur.Orchestrator.ControlCLI.TestFixture
  alias Aiur.Orchestrator.StatusCLI

  import TestFixture, except: [setup: 1]

  setup context do
    TestFixture.setup(context)
  end

  alias Aiur.ExecutorAttention.CLI, as: AgentControlCLI

  describe "alerts/1" do
    test "alerts and watch use the default project ledger" do
      log_root = Aiur.TestSupport.tmp_root!("aiur-default-alert-ledger")
      previous_log_file = Application.get_env(:aiur, :log_file)
      Application.put_env(:aiur, :log_file, Path.join(log_root, "daemon.log"))
      on_exit(fn -> Aiur.TestCleanup.rm_rf!(log_root) end)
      Aiur.TestSupport.put_runtime_state_dir!(log_root)

      on_exit(fn ->
        if previous_log_file,
          do: Application.put_env(:aiur, :log_file, previous_log_file),
          else: Application.delete_env(:aiur, :log_file)
      end)

      ledger = AlertLedger.path()
      File.mkdir_p!(Path.dirname(ledger))

      File.write!(ledger, "{\"event\":\"alert\",\"topic\":\"ticket.51.agent.paused\",\"reason\":\"operator paused the agent\",\"needs_attention\":true,\"source_ticket_id\":\"51\",\"agent\":\"51\"}\n")

      assert capture_io(fn -> AgentControlCLI.alerts(needs_attention: true) end) =~ "ticket.51.agent.paused"

      assert capture_io(fn -> StatusCLI.watch(mode: :full, blocking_asks: []) end) =~
               "#51"
    end

    test "prints persisted alerts as JSON lines with optional attention filtering" do
      workspace_root =
        Aiur.TestSupport.tmp_root!("aiur-control-alerts")

      on_exit(fn -> Aiur.TestCleanup.rm_rf!(workspace_root) end)
      restore_workflow_file_after_test()
      write_workflow_file!(Aiur.Workflow.workflow_file_path(), workspace_root: workspace_root)

      log = Path.join(workspace_root, "repo/51/logs/agent.ndjson")
      File.mkdir_p!(Path.dirname(log))
      recent_timestamp = DateTime.utc_now() |> DateTime.to_iso8601()

      File.write!(log, """
      {"event":"alert","timestamp":"#{recent_timestamp}","name":"ticket.51.agent.phase.work.start","message":"work","reason":"work phase started","needs_attention":false}
      {"event":"alert","timestamp":"#{recent_timestamp}","name":"ticket.51.agent.paused","message":"paused","reason":"operator paused the agent","severity":"warning","needs_attention":true,"source_ticket_id":"51"}
      """)

      ledger = Path.join(workspace_root, "ledger.ndjson")

      File.write!(ledger, """
      {"event":"alert","timestamp":"#{recent_timestamp}","name":"ticket.51.agent.paused","message":"paused","reason":"operator paused the agent","severity":"warning","needs_attention":true,"source_ticket_id":"51"}
      """)

      output = capture_io(fn -> AgentControlCLI.alerts(needs_attention: true, ledger_paths: [ledger]) end)

      assert output =~ "\"topic\":\"ticket.51.agent.paused\""
      assert output =~ "\"reason\":\"operator paused the agent\""
      assert output =~ "\"needs_attention\":true"
      refute output =~ "phase.work.start"
      assert output =~ "__AIUR_CONTROL_EXIT__:0"
    end
  end
end
