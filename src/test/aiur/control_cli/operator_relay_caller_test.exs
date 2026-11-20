defmodule Aiur.ControlCLI.OperatorRelayCallerTest do
  # Drives the relay RPC entry point the CLI calls, against the application's Command store.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Aiur.{DecisionStore, Workflow}

  setup do
    dir = Aiur.TestSupport.tmp_root!("operator-relay-caller-7955")
    File.mkdir_p!(dir)
    config = Path.join(dir, "config")
    audit = Path.join(dir, "control-audit.ndjson")
    previous_audit = Application.get_env(:aiur, :control_audit_file)
    Application.put_env(:aiur, :control_audit_file, audit)
    File.write!(config, "tracker: {kind: memory}\nworkspace: {root: #{Path.join(dir, "workspaces")}}\nexecutor: {relay_operator_answers: true}\n")
    previous_workflow = Workflow.workflow_file_path()
    Workflow.set_workflow_file_path(config)

    on_exit(fn ->
      Workflow.set_workflow_file_path(previous_workflow)
      if previous_audit, do: Application.put_env(:aiur, :control_audit_file, previous_audit), else: Application.delete_env(:aiur, :control_audit_file)
      Aiur.TestCleanup.rm_rf!(dir)
    end)

    %{dir: dir, audit: audit}
  end

  defp request do
    {:ok, %{decision: decision}} =
      DecisionStore.request(
        %{
          question: "Ship the worker's own change?",
          authority: "human_required",
          context: %{authority_basis: "product"},
          reversibility: "reversible",
          blocking: true,
          source_id: "relay-caller-#{System.unique_integer([:positive])}",
          options: [%{id: "yes", label: "Yes"}, %{id: "no", label: "No"}]
        },
        [ticket: %{identifier: "7955", title: "Relay caller test", url: nil}, source: %{agent_id: "codex", session_id: "relay-caller"}],
        Aiur.DecisionStore
      )

    decision
  end

  defp relay(decision, caller) do
    params = [decision_id: decision.decision_id, option_id: "yes", quote: "yes", relayed_by: "attended-executor", auto_current: true] ++ caller
    parent = self()

    stderr = capture_io(:stderr, fn -> send(parent, {:out, capture_io(fn -> Aiur.AgentControlCLI.operator_relay_answer(params) end)}) end)
    assert_received {:out, out}, "relay entry point printed nothing"
    {out, stderr}
  end

  defp answer(decision) do
    {:ok, %{answer: answer}} = DecisionStore.get(decision.decision_id, Aiur.DecisionStore)
    answer
  end

  test "an agent-workspace caller with AIUR_AGENT_WORKSPACE unset is refused and audited; the attended Executor still relays", %{dir: dir, audit: audit} do
    decision = request()
    worker_cwd = Path.join([dir, "workspaces", "owner", "repo", "7955"])

    {out, stderr} = relay(decision, caller_cwd: worker_cwd, caller_agent_workspace_env: "")
    assert out =~ "__AIUR_CONTROL_EXIT__:1"
    assert stderr =~ "relayed operator answers are refused from agent workspaces"
    assert answer(decision) == nil

    assert [record] = audit |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    assert %{"event" => "operator_relay_refused", "outcome" => "refused", "reason" => "agent_workspace", "decision_id" => decision_id} = record
    assert decision_id == decision.decision_id

    {out, _stderr} = relay(decision, caller_cwd: "/operator/home", caller_agent_workspace_env: Path.join(dir, "workspaces/repo/7955"))
    assert out =~ "__AIUR_CONTROL_EXIT__:1"
    assert answer(decision) == nil

    {out, stderr} = relay(decision, [])
    assert out =~ "__AIUR_CONTROL_EXIT__:1"
    assert stderr =~ "require caller context"
    assert answer(decision) == nil

    {out, _stderr} = relay(decision, caller_cwd: "/operator/home", caller_agent_workspace_env: "")
    assert out =~ "answered by operator, relayed by attended-executor"
    assert out =~ "__AIUR_CONTROL_EXIT__:0"
    assert %{actor: %{kind: :operator_relayed, id: "attended-executor"}} = answer(decision)
  end
end
