defmodule Aiur.DecisionAttentionResolutionTest do
  use Aiur.TestSupport

  import ExUnit.CaptureIO

  alias Aiur.{AlertFeed, AlertLedger, DecisionAttention, DecisionAttentionResolution, Issue}
  alias Aiur.Orchestrator.{State, StatusReport}

  test "the owner lookup covers running entries, claims, and workspace leases" do
    issue = %Issue{id: "owner-id", identifier: "OWNER-1"}
    base = %State{last_polled_issues: %{"owner-id" => issue}}

    assert {:reply, true, _} =
             StatusReport.has_live_owner(
               %{base | running: %{"owner-id" => %{identifier: "OWNER-1"}}},
               "OWNER-1"
             )

    assert {:reply, true, _} =
             StatusReport.has_live_owner(%{base | claimed: MapSet.new(["owner-id"])}, "OWNER-1")

    leased =
      put_in(base.dispatch_recovery.workspace_ownership.waits, %{
        "OWNER-1" => %{owner: "provider"}
      })

    assert {:reply, true, _} = StatusReport.has_live_owner(leased, "OWNER-1")
    assert {:reply, false, _} = StatusReport.has_live_owner(base, "OWNER-1")
  end

  test "an unavailable owner lookup reports unknown" do
    server = Module.concat(__MODULE__, "Missing#{System.unique_integer([:positive])}")
    assert :unknown == StatusReport.has_live_owner_api(server, "OWNER-UNKNOWN", 1)
  end

  test "a live owner resolves a stranded reminder instead of re-asking it" do
    identifier = "STRANDED-OWNER-#{System.unique_integer([:positive])}"
    test_pid = self()

    {pid, name} =
      start_attention(
        owner_lookup: fn ^identifier -> true end,
        alert_emitter: fn attention -> send(test_pid, {:alert, attention}) end,
        resolution_emitter: fn attention -> send(test_pid, {:resolved, attention}) end
      )

    issue = %Issue{identifier: identifier}
    assert :ok = DecisionAttention.open(name, issue, nil, nil, "stranded-requeued", "Requeued")
    assert_receive {:alert, %{slug: "stranded-requeued"}}, 1_000

    send(pid, {:reask, {identifier, "stranded-requeued"}})
    assert_receive {:resolved, %{slug: "stranded-requeued"}}, 1_000
    refute_receive {:alert, _}, 100
    assert :sys.get_state(pid).attentions == %{}
  end

  test "restart import resolves an attention when its ticket already has an owner" do
    identifier = "STRANDED-RESTORE-#{System.unique_integer([:positive])}"
    test_pid = self()

    imported = [
      %{
        identifier: identifier,
        slug: "stranded-requeued",
        question: "Requeued",
        source_created_at: DateTime.utc_now()
      }
    ]

    {pid, _name} =
      start_attention(
        attention_loader: fn -> imported end,
        owner_lookup: fn ^identifier -> true end,
        decision_projector: fn _, _ ->
          send(test_pid, :projected)
          flunk("owned attention must not be reopened")
        end,
        alert_emitter: fn attention -> send(test_pid, {:alert, attention}) end,
        resolution_emitter: fn attention -> send(test_pid, {:resolved, attention}) end
      )

    assert_receive {:resolved, %{slug: "stranded-requeued"}}, 1_000
    refute :sys.get_state(pid).importing?
    assert :sys.get_state(pid).attentions == %{}
    refute_received :projected
    refute_received {:alert, _}
  end

  test "without an owner the stranded reminder remains open and re-asks once" do
    identifier = "STRANDED-NO-OWNER-#{System.unique_integer([:positive])}"
    test_pid = self()

    {pid, name} =
      start_attention(
        owner_lookup: fn _ -> false end,
        alert_emitter: fn attention -> send(test_pid, {:alert, attention}) end,
        resolution_emitter: fn attention -> send(test_pid, {:resolved, attention}) end
      )

    assert :ok =
             DecisionAttention.open(
               name,
               %Issue{identifier: identifier},
               nil,
               nil,
               "stranded-requeued",
               "Requeued"
             )

    assert_receive {:alert, %{slug: "stranded-requeued"}}, 1_000
    send(pid, {:reask, {identifier, "stranded-requeued"}})
    assert_receive {:alert, %{slug: "stranded-requeued"}}, 1_000
    assert map_size(:sys.get_state(pid).attentions) == 1
    refute_received {:resolved, _}
  end

  test "an unknown owner status keeps the reminder and avoids claiming there is no owner" do
    identifier = "STRANDED-UNKNOWN-#{System.unique_integer([:positive])}"
    test_pid = self()

    {pid, name} =
      start_attention(
        owner_lookup: fn _ -> :unknown end,
        alert_emitter: fn attention -> send(test_pid, {:alert, attention}) end,
        resolution_emitter: fn attention -> send(test_pid, {:resolved, attention}) end
      )

    assert :ok =
             DecisionAttention.open(
               name,
               %Issue{identifier: identifier},
               nil,
               nil,
               "stranded-requeued",
               "No live owner"
             )

    assert_receive {:alert, %{question: "No live owner"}}, 1_000
    send(pid, {:reask, {identifier, "stranded-requeued"}})
    assert_receive {:alert, %{question: question}}, 1_000
    assert question =~ "live-owner status could not be checked"
    assert map_size(:sys.get_state(pid).attentions) == 1
    refute_received {:resolved, _}
  end

  test "a running ticket does not resolve an unrelated operator decision" do
    identifier = "OPERATOR-DECISION-#{System.unique_integer([:positive])}"
    test_pid = self()

    {pid, name} =
      start_attention(
        owner_lookup: fn _ -> true end,
        alert_emitter: fn attention -> send(test_pid, {:alert, attention}) end,
        resolution_emitter: fn attention -> send(test_pid, {:resolved, attention}) end
      )

    assert :ok =
             DecisionAttention.open(
               name,
               %Issue{identifier: identifier},
               nil,
               nil,
               "scope-question",
               "Which option?"
             )

    assert_receive {:alert, %{slug: "scope-question"}}, 1_000
    send(pid, {:reask, {identifier, "scope-question"}})
    assert_receive {:alert, %{slug: "scope-question"}}, 1_000
    refute_received {:resolved, _}
  end

  test "acknowledging a duplicate alert resolves its recheck, then a new firing remains active" do
    identifier = "DUPLICATE-ACK-#{System.unique_integer([:positive])}"
    issue = %Issue{identifier: identifier, title: "Duplicate dispatch"}
    topic = "ticket.#{identifier}.agent.attention.duplicate-dispatch"
    ledger_dir = Aiur.TestSupport.tmp_root!("duplicate-ack-alerts")
    File.mkdir_p!(ledger_dir)
    ledger = Path.join(ledger_dir, "alerts.ndjson")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(ledger_dir) end)
    test_pid = self()

    alert_emitter = fn attention ->
      append_attention(ledger, attention, true)
      send(test_pid, {:duplicate_alert, attention})
    end

    resolution_emitter = fn attention ->
      append_attention(ledger, attention, false)
      send(test_pid, {:duplicate_resolved, attention})
    end

    {pid, name} =
      start_attention(
        pid_alive?: fn _pid -> true end,
        attention_acknowledged?: fn acknowledged_topic ->
          AlertFeed.condition_state(acknowledged_topic, ledger_path: ledger) == :resolved
        end,
        alert_emitter: alert_emitter,
        resolution_emitter: resolution_emitter
      )

    assert :ok =
             DecisionAttention.open(
               name,
               issue,
               nil,
               nil,
               "duplicate-dispatch",
               "Two sessions: pid 101 and pid 202"
             )

    assert_received {:duplicate_alert, %{slug: "duplicate-dispatch"}}
    assert AlertFeed.condition_state(topic, ledger_path: ledger) == :firing

    assert capture_io(fn ->
             assert Aiur.AlertsCLI.run(ack: topic, executor_id: "operator-7", ledger_path: ledger) ==
                      0
           end) =~ "Acknowledged #{topic} as operator-7"

    assert AlertFeed.condition_state(topic, ledger_path: ledger) == :resolved

    assert [%{"acknowledged_by" => %{"kind" => "executor", "id" => "operator-7"}}] =
             ledger
             |> File.read!()
             |> String.split("\n", trim: true)
             |> Enum.map(&Jason.decode!/1)
             |> Enum.filter(&Map.has_key?(&1, "acknowledged_by"))

    send(pid, {:reask, {identifier, "duplicate-dispatch"}})
    _ = :sys.get_state(pid)
    assert_received {:duplicate_resolved, %{slug: "duplicate-dispatch"}}

    assert :ok =
             DecisionAttention.open(
               name,
               issue,
               nil,
               nil,
               "duplicate-dispatch",
               "Two sessions: pid 101 and pid 202"
             )

    assert_received {:duplicate_alert, %{slug: "duplicate-dispatch"}}
    assert AlertFeed.condition_state(topic, ledger_path: ledger) == :firing

    send(pid, {:reask, {identifier, "duplicate-dispatch"}})
    _ = :sys.get_state(pid)
    assert_received {:duplicate_alert, %{slug: "duplicate-dispatch"}}
    refute_received {:duplicate_resolved, _}
  end

  test "PID liveness detects a live OS process and one that has exited" do
    assert DecisionAttentionResolution.pid_alive?(String.to_integer(System.pid()))
    assert DecisionAttentionResolution.ps_pid_alive?(String.to_integer(System.pid()))

    sleep = System.find_executable("sleep") || raise "sleep executable is required for this test"

    port =
      Port.open({:spawn_executable, sleep}, [:binary, :exit_status, :use_stdio, args: ["300"]])

    {:os_pid, child_pid} = Port.info(port, :os_pid)

    try do
      assert DecisionAttentionResolution.pid_alive?(child_pid)
      kill = System.find_executable("kill") || raise "kill executable is required for this test"
      {_output, 0} = System.cmd(kill, ["-TERM", Integer.to_string(child_pid)])
      assert_receive {^port, {:exit_status, _status}}, 1_000
      refute DecisionAttentionResolution.pid_alive?(child_pid)
      refute DecisionAttentionResolution.ps_pid_alive?(child_pid)
    after
      if Port.info(port) != nil, do: Port.close(port)
    end
  end

  test "PID liveness treats a zombie process as exited on macOS" do
    assert DecisionAttentionResolution.process_state_alive?("S")
    assert DecisionAttentionResolution.process_state_alive?("R+")
    refute DecisionAttentionResolution.process_state_alive?("Z")
    refute DecisionAttentionResolution.process_state_alive?("")
  end

  test "remote duplicate-dispatch PIDs are not checked on the daemon host" do
    attention = %{
      issue: %Issue{identifier: "REMOTE-5133"},
      slug: "duplicate-dispatch",
      worker_host: "worker.example",
      question: "Two sessions: pid 101 and pid 202"
    }

    state = %{pid_alive?: fn _pid -> false end, attention_acknowledged?: fn _topic -> false end}
    refute DecisionAttentionResolution.resolve?(attention, state)
  end

  test "restored duplicate-dispatch attention ignores historical PIDs but can be acknowledged" do
    attention = %{
      issue: %Issue{identifier: "RESTORED-5133"},
      slug: "duplicate-dispatch",
      worker_host: nil,
      restored?: true,
      question: "Two sessions: pid 101 and pid 202"
    }

    state = %{
      pid_alive?: fn _pid -> false end,
      attention_acknowledged?: fn _topic -> false end
    }

    refute DecisionAttentionResolution.resolve?(attention, state)
    assert DecisionAttentionResolution.resolve?(attention, %{state | attention_acknowledged?: fn _ -> true end})
  end

  defp append_attention(ledger, attention, needs_attention) do
    topic = "ticket.#{attention.issue.identifier}.agent.attention.#{attention.slug}"

    :ok =
      AlertLedger.append(
        %{
          "event" => "alert",
          "timestamp" => DateTime.to_iso8601(DateTime.utc_now()),
          "topic" => if(needs_attention, do: topic, else: topic <> ".resolved"),
          "needs_attention" => needs_attention
        },
        ledger_path: ledger
      )
  end

  defp start_attention(opts) do
    name = Module.concat(__MODULE__, "Registry#{System.unique_integer([:positive])}")

    defaults = [
      name: name,
      reask_interval_ms: 60_000,
      attention_loader: fn -> [] end,
      decision_projector: fn _, _ ->
        {:ok, %{status: :accepted, decision: %{decision_id: "decision", version: 1}}}
      end
    ]

    pid = start_supervised!({DecisionAttention, Keyword.merge(defaults, opts)})
    {pid, name}
  end
end
