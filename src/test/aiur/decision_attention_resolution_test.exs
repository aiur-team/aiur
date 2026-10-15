defmodule Aiur.DecisionAttentionResolutionTest do
  use Aiur.TestSupport

  alias Aiur.{DecisionAttention, Issue}
  alias Aiur.Orchestrator.{State, StatusReport}

  test "the owner lookup covers running entries, claims, and workspace leases" do
    issue = %Issue{id: "owner-id", identifier: "OWNER-1"}
    base = %State{last_polled_issues: %{"owner-id" => issue}}

    assert {:reply, true, _} = StatusReport.has_live_owner(%{base | running: %{"owner-id" => %{identifier: "OWNER-1"}}}, "OWNER-1")
    assert {:reply, true, _} = StatusReport.has_live_owner(%{base | claimed: MapSet.new(["owner-id"])}, "OWNER-1")

    leased = put_in(base.dispatch_recovery.workspace_ownership.waits, %{"OWNER-1" => %{owner: "provider"}})
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
    imported = [%{identifier: identifier, slug: "stranded-requeued", question: "Requeued", source_created_at: DateTime.utc_now()}]

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

    assert :ok = DecisionAttention.open(name, %Issue{identifier: identifier}, nil, nil, "stranded-requeued", "Requeued")
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

    assert :ok = DecisionAttention.open(name, %Issue{identifier: identifier}, nil, nil, "stranded-requeued", "No live owner")
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

    assert :ok = DecisionAttention.open(name, %Issue{identifier: identifier}, nil, nil, "scope-question", "Which option?")
    assert_receive {:alert, %{slug: "scope-question"}}, 1_000
    send(pid, {:reask, {identifier, "scope-question"}})
    assert_receive {:alert, %{slug: "scope-question"}}, 1_000
    refute_received {:resolved, _}
  end

  defp start_attention(opts) do
    name = Module.concat(__MODULE__, "Registry#{System.unique_integer([:positive])}")

    defaults = [
      name: name,
      reask_interval_ms: 60_000,
      attention_loader: fn -> [] end,
      decision_projector: fn _, _ -> {:ok, %{status: :accepted, decision: %{decision_id: "decision", version: 1}}} end
    ]

    {:ok, pid} = DecisionAttention.start_link(Keyword.merge(defaults, opts))
    on_exit(fn -> Aiur.TestSupport.safe_stop(pid) end)
    {pid, name}
  end
end
