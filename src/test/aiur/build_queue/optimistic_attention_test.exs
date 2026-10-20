defmodule Aiur.BuildQueue.OptimisticAttentionTest do
  use Aiur.TestSupport
  alias Aiur.BuildQueue.{Attention, AttentionActions, Store}
  alias Aiur.Orchestrator.OptimisticLedger

  defmodule CaptureSink do
    # The sink is app-global; drop alerts other processes raise while a test runs (#4975).
    def emit_system(topic, opts) do
      if self() == Application.get_env(:aiur, :optimistic_attention_test_pid), do: send(self(), {:attention, topic, opts})
      :ok
    end
  end

  setup do
    previous = Application.fetch_env!(:aiur, :signal)
    root = Aiur.TestSupport.tmp_root!("optimistic-attention")
    prior_root = Application.fetch_env(:aiur, :decision_state_dir)
    Application.put_env(:aiur, :decision_state_dir, root)
    Application.put_env(:aiur, :optimistic_attention_test_pid, self())
    Application.put_env(:aiur, :signal, alert_sink: CaptureSink)

    on_exit(fn ->
      Application.put_env(:aiur, :signal, previous)
      Application.delete_env(:aiur, :optimistic_attention_test_pid)

      case prior_root do
        {:ok, value} -> Application.put_env(:aiur, :decision_state_dir, value)
        :error -> Application.delete_env(:aiur, :decision_state_dir)
      end

      Aiur.TestCleanup.rm_rf!(root)
    end)

    :ok
  end

  test "terminal failure emits warning once with preserved work and choices" do
    payload = %{ticket: "11", blocker: "10", cause: :pr_closed_unmerged, action: :paused_parked, severity: "warning"}
    assert :ok = Attention.open(:optimistic_blocker_failed, "11", payload)
    assert :ok = Attention.open(:optimistic_blocker_failed, "11", payload)
    assert_received {:attention, "ticket.11.queue.attention.optimistic_blocker_failed", opts}
    refute_received {:attention, _, _}
    assert opts[:severity] == "warning"
    assert opts[:exchange_payload] == payload
    assert opts[:message] =~ "paused and parked #11; branch and PR kept"
    assert opts[:message] =~ "wait for a replacement blocker"
    assert opts[:message] =~ "re-base #11 on the default branch and resume it, or close it"
  end

  test "persistent trouble emits info while dependent keeps running" do
    payload = %{blocker: "10", cause: :agent_error, action: :none, severity: "info"}
    assert :ok = Attention.transient(:optimistic_blocker_failed, "11", payload)
    assert_received {:attention, _, opts}
    assert opts[:severity] == "info"
    assert opts[:needs_attention]
    assert opts[:message] =~ "#11 keeps running"
  end

  test "terminal failure remains visible after an informational trouble wake" do
    assert :ok = Attention.open({:optimistic_blocker_failed, :trouble}, "11", %{blocker: "10", cause: :agent_error, action: :none, severity: "info"})
    assert_received {:attention, _, info}
    assert info[:severity] == "info"
    assert :ok = Attention.open(:optimistic_blocker_failed, "11", %{blocker: "10", cause: :not_planned, action: :parked})
    assert_received {:attention, _, warning}
    assert warning[:severity] == "warning"
    assert warning[:message] =~ "parked #11"
    assert :ok = Attention.transient(:optimistic_blocker_failed, "11", %{}, true)
    assert_received {:attention, "ticket.11.queue.attention.optimistic_blocker_failed.resolved", resolved}
    refute resolved[:needs_attention]
  end

  test "agent-error prerequisite names running starts without claiming they are parked" do
    :ok = Supervisor.terminate_child(Aiur.Supervisor, OptimisticLedger)
    on_exit(fn -> Supervisor.restart_child(Aiur.Supervisor, OptimisticLedger) end)
    path = Path.join(System.tmp_dir!(), "optimistic-attention-ledger-#{System.unique_integer([:positive])}.json")
    on_exit(fn -> File.rm(path) end)
    start_supervised!({OptimisticLedger, path: path})
    assert :ok = OptimisticLedger.record_start("11", %{attempt_id: "attention-start", start_trigger: :pr_opened, started_at_ms: 100, blockers: [%{"id" => "10"}]})
    assert {:ok, document} = Store.load()
    context = %{document: document, store: Store, clock: fn -> 100 end, observations: %{}, marker: "agent:queued"}
    AttentionActions.execute(context, {:attention_open, {{:prerequisite_failed, :agent_error}, "10"}})
    assert_received {:attention, "ticket.10.queue.attention.prerequisite_failed", opts}
    assert opts[:exchange_payload][:started] == ["11"]
    assert opts[:message] =~ "#11 already started"
    refute opts[:message] =~ "(parked)"
    assert {:ok, row} = OptimisticLedger.get("11")
    assert row["status"] == "running"
  end

  test "churn attention names its recorded blocker and keeps work running" do
    payload = %{blocker: "10", cause: :churn, action: :none, severity: "info"}
    assert :ok = Attention.open({:optimistic_blocker_failed, :churn}, "11", payload)
    assert_received {:attention, "ticket.11.queue.attention.optimistic_blocker_failed", opts}
    assert opts[:exchange_payload] == payload
    assert opts[:severity] == "info"
    assert opts[:message] =~ "#10 has repeated conflicting integrations"
    assert opts[:message] =~ "#11 keeps running"
  end

  test "merged blocker notice asks for a default branch rebase without replacement language" do
    payload = %{blocker: "10", cause: :merged, action: :none, severity: "info"}
    assert :ok = Attention.open({:optimistic_blocker_failed, :merged}, "11", payload)
    assert_received {:attention, "ticket.11.queue.attention.optimistic_blocker_failed", opts}
    assert opts[:severity] == "info"
    assert opts[:message] =~ "Blocker #10 merged"
    assert opts[:message] =~ "Rebase #11 on the default branch"
    refute opts[:message] =~ "replacement blocker"
  end

  test "invalid action and missing failure facts cannot publish" do
    for payload <- [%{blocker: "10", cause: :not_planned, action: :bogus}, %{blocker: "10", action: :parked}, %{}] do
      assert {:error, :invalid_attention} = Attention.open(:optimistic_blocker_failed, "11", payload)
    end

    assert {:ok, %{latches: []}} = Store.load()
    refute_received {:attention, _, _}
    assert :ok = Attention.open(:optimistic_blocker_failed, "11", %{blocker: "10", cause: :not_planned, action: :parked})
  end

  test "prerequisite attention names started optimistic dependents" do
    assert :ok = Attention.open(:prerequisite_failed, "10", %{cause: :not_planned, started: ["11"], blocked: ["12"]})
    assert_received {:attention, _, opts}
    assert opts[:exchange_payload][:started] == ["11"]
    assert opts[:message] =~ "#11 already started"
  end
end
