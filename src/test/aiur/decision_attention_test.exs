defmodule Aiur.DecisionAttentionTest do
  use Aiur.TestSupport

  alias Aiur.{DecisionAttention, Issue}
  alias Aiur.Events.SubscriptionStore

  test "opens, re-asks, and resolves an operator-decision attention" do
    identifier = "DECISION-#{System.unique_integer([:positive])}"
    issue = %Issue{identifier: identifier, title: "Needs a decision"}
    name = Module.concat(__MODULE__, "Registry#{System.unique_integer([:positive])}")
    test_pid = self()

    {:ok, pid} =
      DecisionAttention.start_link(
        name: name,
        reask_interval_ms: 60_000,
        alert_emitter: fn attention -> send(test_pid, {:decision_alert, attention}) end,
        resolution_emitter: fn attention -> send(test_pid, {:decision_resolved, attention}) end
      )

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)

    assert :ok = DecisionAttention.open(name, issue, nil, nil, "scope-question", "Should this facade target change?")

    assert_receive {:decision_alert, %{question: "Should this facade target change?", slug: "scope-question"}}
    assert SubscriptionStore.snapshot(identifier).open_attentions == ["scope-question"]

    send(pid, {:reask, {identifier, "scope-question"}})
    assert_receive {:decision_alert, %{question: "Should this facade target change?"}}

    assert :ok = DecisionAttention.resolve(name, issue, "scope-question")
    assert_receive {:decision_resolved, %{slug: "scope-question"}}
    assert SubscriptionStore.snapshot(identifier).open_attentions == []

    send(pid, {:reask, {identifier, "scope-question"}})
    refute_receive {:decision_alert, _}
  end

  test "writes a needs-attention alert with the operator question" do
    identifier = "DECISION-ALERT-#{System.unique_integer([:positive])}"
    workspace = Path.join(System.tmp_dir!(), "aiur-decision-attention-#{System.unique_integer([:positive])}")
    issue = %Issue{identifier: identifier, title: "Needs a decision"}
    name = Module.concat(__MODULE__, "AlertRegistry#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)

    on_exit(fn ->
      File.rm_rf!(workspace)
    end)

    {:ok, pid} = DecisionAttention.start_link(name: name, reask_interval_ms: 60_000)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)

    assert :ok = DecisionAttention.open(name, issue, workspace, nil, "scope-question", "Should this facade target change?")

    log = Path.join(workspace, "logs/agent.ndjson") |> File.read!()
    assert log =~ "ticket.#{identifier}.agent.attention.scope-question"
    assert log =~ "Operator decision required: Should this facade target change?"
    assert log =~ "\"needs_attention\":true"
  end
end
