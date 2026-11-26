defmodule Aiur.Orchestrator.InstanceHeartbeatMetadata.ProjectSignalsTest do
  use ExUnit.Case, async: true

  alias Aiur.Orchestrator.InstanceHeartbeatMetadata
  alias Aiur.Orchestrator.InstanceHeartbeatMetadata.ProjectSignals

  defp counts(by_ticket), do: fn -> {:ok, %{needs_you_by_ticket: by_ticket}} end

  test "pending Decisions are summed per repo" do
    assert ProjectSignals.pending_decisions(counts_fun: counts(%{"Acme/Widgets#1" => 2, "acme/widgets#2" => 1, "acme/api#9" => 4})) ==
             %{"acme/widgets" => 3, "acme/api" => 4}
  end

  test "an unreadable or unparseable Decision store is nil, not an empty count" do
    assert ProjectSignals.pending_decisions(counts_fun: counts(nil)) == nil
    assert ProjectSignals.pending_decisions(counts_fun: fn -> raise "boom" end) == nil
    assert ProjectSignals.pending_decisions(counts_fun: counts(%{"not a ticket" => 1})) == nil
  end

  test "next queue entry is the first ready item of the lowest-ranked queue" do
    model = %{
      status: :running,
      queues: [
        %{set_rank: 2, queue_id: "b", items: [%{number: 9, state: :ready, verdict: :ready}]},
        %{set_rank: 1, queue_id: "a", items: [%{number: 5, state: :blocked, verdict: :pending}, %{number: 6, state: :ready, verdict: :ready}]}
      ]
    }

    assert ProjectSignals.next_queue(repo_fun: fn -> "Acme/Widgets" end, queue_fun: fn -> model end) == %{"acme/widgets" => 6}
    assert ProjectSignals.next_queue(repo_fun: fn -> "Acme/Widgets" end, queue_fun: fn -> %{model | queues: []} end) == %{"acme/widgets" => nil}
  end

  test "an unreadable queue is nil" do
    assert ProjectSignals.next_queue(repo_fun: fn -> "a/b" end, queue_fun: fn -> %{status: :store_unavailable, queues: []} end) == nil
    assert ProjectSignals.next_queue(repo_fun: fn -> nil end, queue_fun: fn -> %{status: :running, queues: []} end) == nil
  end

  test "the heartbeat omits an unreadable field from every project instead of writing 0" do
    base = [
      statuses_fun: fn -> [] end,
      ownership_metadata_fun: fn -> %{} end,
      held_tickets_fun: fn -> ["acme/widgets#1"] end,
      gateway_identity_fun: fn -> %{gateway_id: "g", gateway_label: "G", gateway_identity: %{}} end,
      host_kind_fun: fn -> "home" end,
      public_url_fun: fn -> nil end,
      capacity_fun: fn -> 4 end
    ]

    [ok] = InstanceHeartbeatMetadata.metadata(base ++ [next_queue_fun: fn -> %{"acme/widgets" => 7} end, pending_decisions_fun: fn -> %{} end])["data"]["projects"]
    assert %{"next_queue" => %{"number" => 7}, "pending_decisions" => 0, "agents" => 0} = ok

    [down] = InstanceHeartbeatMetadata.metadata(base ++ [next_queue_fun: fn -> nil end, pending_decisions_fun: fn -> nil end])["data"]["projects"]
    refute Map.has_key?(down, "next_queue")
    refute Map.has_key?(down, "pending_decisions")
  end
end
