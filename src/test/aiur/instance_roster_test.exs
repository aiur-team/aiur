defmodule Aiur.Instance.RosterTest do
  use ExUnit.Case, async: true

  alias Aiur.Instance.Roster

  test "expired heartbeat remains stale with its age, then drops after retention" do
    now = ~U[2026-10-24 12:00:00Z]

    records = [
      %{
        instance_id: "home-a",
        build_version: "1.2.3",
        metadata: %{
          "version" => 1,
          "data" => %{"host_kind" => "home", "public_url" => "https://aiur.example", "agent_count" => 2, "agent_capacity" => 4, "leader" => true, "held_tickets" => ["acme/widgets#41"]}
        },
        heartbeat_at: ~U[2026-10-24 11:59:50Z],
        expires_at: ~U[2026-10-24 12:00:20Z]
      },
      %{
        instance_id: "container-b",
        build_version: "1.2.2",
        metadata: %{"version" => 1, "data" => %{"host_kind" => "container"}},
        heartbeat_at: ~U[2026-10-24 11:59:10Z],
        expires_at: ~U[2026-10-24 11:59:40Z]
      }
    ]

    {:ok, roster} =
      Roster.list(
        now: now,
        list_fun: fn _ -> {:ok, records} end,
        leader_fun: fn -> %{instance_id: "home-a"} end
      )

    expired = Enum.find(roster.instances, &(&1.instance_id == "container-b"))
    assert expired.state == :stale
    assert expired.age_ms == 50_000
    refute expired.state == :idle
    assert expired.host_kind == "container"
    assert expired.leader? == false
    assert Enum.find(roster.instances, &(&1.instance_id == "home-a")).public_url == "https://aiur.example"
    home = Enum.find(roster.instances, &(&1.instance_id == "home-a"))
    assert home.leader? == true
    assert home.agent_count == 2
    assert home.agent_capacity == 4
    assert home.held_tickets == ["acme/widgets#41"]

    {:ok, removed} = Roster.list(now: DateTime.add(now, 61, :second), stale_retention_ms: 20_000, list_fun: fn _ -> {:ok, records} end)
    refute Enum.any?(removed.instances, &(&1.instance_id == "container-b"))
  end

  test "unknown leader lookup does not reuse heartbeat metadata" do
    now = DateTime.utc_now()

    record = %{
      instance_id: "home-a",
      build_version: "1.2.3",
      metadata: %{"version" => 1, "data" => %{"leader" => true}},
      heartbeat_at: now,
      expires_at: DateTime.add(now, 30, :second)
    }

    assert {:ok, %{instances: [row]}} =
             Roster.list(
               now: now,
               list_fun: fn _ -> {:ok, [record]} end,
               leader_fun: fn -> :unknown end
             )

    assert row.leader? == nil
  end

  test "store errors remain errors rather than an empty roster" do
    assert {:error, :offline} = Roster.list(list_fun: fn _ -> {:error, :offline} end)
  end
end
