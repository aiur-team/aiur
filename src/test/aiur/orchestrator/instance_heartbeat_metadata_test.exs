defmodule Aiur.Orchestrator.InstanceHeartbeatMetadataTest do
  use ExUnit.Case, async: true

  alias Aiur.Instance.Roster
  alias Aiur.Instance.Roster.Presentation
  alias Aiur.Orchestrator.InstanceHeartbeatMetadata

  test "heartbeat publishes per-instance ticket rows and capacity" do
    metadata =
      InstanceHeartbeatMetadata.metadata(
        next_queue_fun: fn -> nil end,
        pending_decisions_fun: fn -> nil end,
        statuses_fun: fn ->
          [
            %{identifier: "acme/widgets#42", title: "Roster ticket", state: :running},
            %{identifier: "acme/widgets#43", title: "Idle ticket", state: :idle}
          ]
        end,
        capacity_fun: fn -> 3 end,
        held_tickets_fun: fn -> ["acme/widgets#42"] end,
        host_kind_fun: fn -> "container" end,
        public_url_fun: fn -> "https://aiur.example" end,
        ownership_metadata_fun: fn ->
          %{
            "version" => 1,
            "data" => %{
              "owns" => [%{"ticket" => 42}],
              "pool" => false,
              "dispatching" => false
            }
          }
        end
      )

    assert %{
             "version" => 1,
             "data" => %{
               "host_kind" => "container",
               "public_url" => "https://aiur.example",
               "agent_count" => 1,
               "agent_capacity" => 3,
               "held_tickets" => ["acme/widgets#42"],
               "owns" => [%{"ticket" => 42}],
               "pool" => false,
               "dispatching" => false,
               "agents" => [%{"identifier" => "acme/widgets#42", "title" => "Roster ticket", "state" => "running"}]
             }
           } = metadata
  end

  test "heartbeat carries the gateway identity, null when unavailable" do
    opts = [
      next_queue_fun: fn -> nil end,
      pending_decisions_fun: fn -> nil end,
      statuses_fun: fn -> [] end,
      capacity_fun: fn -> 1 end,
      held_tickets_fun: fn -> [] end,
      host_kind_fun: fn -> "home" end,
      public_url_fun: fn -> nil end,
      ownership_metadata_fun: fn -> %{} end
    ]

    available = %{gateway_id: "abc", gateway_label: "l", gateway_identity: "available"}
    data = InstanceHeartbeatMetadata.metadata([gateway_identity_fun: fn -> available end] ++ opts)["data"]
    assert Map.take(data, ["gateway_id", "gateway_label", "gateway_identity"]) == %{"gateway_id" => "abc", "gateway_label" => "l", "gateway_identity" => "available"}

    gone = %{gateway_id: nil, gateway_label: nil, gateway_identity: "unavailable"}
    data = InstanceHeartbeatMetadata.metadata([gateway_identity_fun: fn -> gone end] ++ opts)
    assert %{"gateway_id" => nil, "gateway_identity" => "unavailable"} = data["data"]
  end

  @base_opts [
    host_kind_fun: &__MODULE__.home/0,
    public_url_fun: &__MODULE__.nil_fun/0,
    ownership_metadata_fun: &__MODULE__.empty/0,
    gateway_identity_fun: &__MODULE__.identity/0
  ]

  def home, do: "home"
  def nil_fun, do: nil
  def empty, do: %{}
  def identity, do: %{gateway_id: "g", gateway_label: "l", gateway_identity: "available"}

  test "publishes projects and executor presence from real workload" do
    rows = [
      %{identifier: "acme/widgets#1", title: "a", state: :running},
      %{identifier: "acme/widgets#2", title: "b", state: :running},
      %{identifier: "acme/api#9", title: "c", state: :running}
    ]

    data =
      InstanceHeartbeatMetadata.metadata(
        @base_opts ++
          [
            statuses_fun: fn -> rows end,
            capacity_fun: fn -> 4 end,
            held_tickets_fun: fn -> ["acme/widgets#1", "acme/widgets#2", "acme/api#9"] end,
            executor_fun: fn -> true end,
            next_queue_fun: fn -> %{"acme/widgets" => 41, "acme/api" => nil} end,
            pending_decisions_fun: fn -> %{"acme/widgets" => 3} end
          ]
      )["data"]

    assert data["agent_count"] == 3
    assert data["executor_present"] == true

    assert data["projects"] == [
             %{"repo" => "acme/widgets", "running" => 2, "agents" => 2, "next_queue" => %{"number" => 41}, "pending_decisions" => 3, "owned_tickets" => 2},
             %{"repo" => "acme/api", "running" => 1, "agents" => 1, "next_queue" => %{"number" => nil}, "pending_decisions" => 0, "owned_tickets" => 1}
           ]
  end

  test "production-shaped rows (bare-number identifier + mixed-case tracker_identity) group under the downcased repo of held keys" do
    row = fn number ->
      issue = %{"node_id" => "I_#{number}", "database_id" => number, "number" => number, "title" => "t"}
      {:ok, identity} = Aiur.TrackerIdentity.from_github(issue, {"Aiur-Team", "Aiur"}, {"Aiur-Team", "Aiur"})
      %{identifier: to_string(number), tracker_identity: identity, title: "t", state: :running}
    end

    data =
      InstanceHeartbeatMetadata.metadata(
        @base_opts ++
          [
            statuses_fun: fn -> [row.(7718), row.(7636)] end,
            capacity_fun: fn -> 2 end,
            held_tickets_fun: fn -> ["aiur-team/aiur#7718", "aiur-team/aiur#7636"] end,
            executor_fun: fn -> true end,
            next_queue_fun: fn -> nil end,
            pending_decisions_fun: fn -> nil end
          ]
      )["data"]

    # Unreadable queue and Decision stores omit their keys; they are never zero-filled.
    assert data["projects"] == [%{"repo" => "aiur-team/aiur", "running" => 2, "agents" => 2, "owned_tickets" => 2}]
  end

  test "unreadable fields are omitted, not zero-filled, and the roster renders unknown" do
    data =
      InstanceHeartbeatMetadata.metadata(
        @base_opts ++
          [
            statuses_fun: fn -> nil end,
            capacity_fun: fn -> nil end,
            held_tickets_fun: fn -> exit(:timeout) end,
            executor_fun: fn -> nil end
          ]
      )["data"]

    for key <- ~w(agent_count agent_capacity held_tickets executor_present projects agents), do: refute(Map.has_key?(data, key), key)

    now = DateTime.utc_now()
    record = %{instance_id: "x", build_version: "1", metadata: %{"version" => 1, "data" => data}, heartbeat_at: now, expires_at: DateTime.add(now, 30)}
    {:ok, %{instances: [row]}} = Roster.list(now: now, list_fun: fn _ -> {:ok, [record]} end, leader_fun: fn -> :unheld end)
    assert Presentation.count(row.agent_count) == "unknown"
    assert Presentation.executor(row.executor_present) == "unknown"
  end

  test "zero and false are facts and survive" do
    data =
      InstanceHeartbeatMetadata.metadata(@base_opts ++ [next_queue_fun: &__MODULE__.nil_fun/0, pending_decisions_fun: &__MODULE__.nil_fun/0, statuses_fun: fn -> [] end, capacity_fun: fn -> 2 end, held_tickets_fun: fn -> [] end, executor_fun: fn -> false end])["data"]

    assert %{"agent_count" => 0, "held_tickets" => [], "executor_present" => false, "projects" => []} = data
  end

  test "oversized payload is trimmed in order, floor keys survive, cuts are named" do
    rows = for i <- 1..20, do: %{identifier: "acme/r#{rem(i, 3)}##{i}", title: String.duplicate("t", 300), state: :running}
    held = for i <- 1..200, do: "acme/r#{rem(i, 3)}##{i}"

    opts = @base_opts ++ [next_queue_fun: &__MODULE__.nil_fun/0, pending_decisions_fun: &__MODULE__.nil_fun/0, statuses_fun: fn -> rows end, capacity_fun: fn -> 20 end, held_tickets_fun: fn -> held end, executor_fun: fn -> true end]

    small = InstanceHeartbeatMetadata.metadata([max_bytes: 8_000] ++ opts)["data"]
    assert small["trimmed"] == ["agent_titles"]
    assert Enum.all?(small["agents"], &(byte_size(&1["title"]) <= 80))
    assert byte_size(Jason.encode!(small)) <= 8_000

    floor = InstanceHeartbeatMetadata.metadata([max_bytes: 1_200] ++ opts)["data"]
    assert byte_size(Jason.encode!(floor)) <= 1_200
    assert floor["trimmed"] == ["agent_titles", "agents", "held_tickets"]
    assert %{"agent_count" => 20, "executor_present" => true} = floor
    refute Map.has_key?(floor, "agents")
  end

  test "roster metadata preserves ownership, pool, and paused state for dispatch" do
    current = metadata_with_ownership(%{"owns" => [], "pool" => true, "dispatching" => true})

    reserved =
      metadata_with_ownership(%{
        "owns" => [%{"ticket" => 42}],
        "pool" => true,
        "dispatching" => true
      })

    assert {:ineligible, :peer_owns_ticket} =
             Aiur.Instance.eligible?(42, "home-a", [
               %{instance_id: "home-a", metadata: current},
               %{instance_id: "container-b", metadata: reserved}
             ])

    pool_closed = metadata_with_ownership(%{"owns" => [], "pool" => false, "dispatching" => true})

    assert {:ineligible, :pool_closed} =
             Aiur.Instance.eligible?(43, "home-a", [
               %{instance_id: "home-a", metadata: pool_closed}
             ])

    paused = metadata_with_ownership(%{"owns" => [], "pool" => true, "dispatching" => false})

    assert {:unavailable, :self_not_dispatching} =
             Aiur.Instance.eligible?(43, "home-a", [
               %{instance_id: "home-a", metadata: paused}
             ])
  end

  defp metadata_with_ownership(data) do
    InstanceHeartbeatMetadata.metadata(
      next_queue_fun: fn -> nil end,
      pending_decisions_fun: fn -> nil end,
      statuses_fun: fn -> [] end,
      capacity_fun: fn -> 1 end,
      held_tickets_fun: fn -> [] end,
      host_kind_fun: fn -> "home" end,
      public_url_fun: fn -> nil end,
      ownership_metadata_fun: fn -> %{"version" => 1, "data" => data} end
    )
  end
end
