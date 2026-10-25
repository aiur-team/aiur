defmodule Aiur.BuildOrder.PackStatus.FileTest do
  use Aiur.BuildOrder.PackStatusCase

  test "writes tracker completion for promoted members into status.json", context do
    poller =
      start_poller(
        context.pack_path,
        issues_response(%{
          "i4101" => %{"number" => 4101, "state" => "CLOSED", "stateReason" => "COMPLETED"},
          "i4102" => %{"number" => 4102, "state" => "CLOSED", "stateReason" => "NOT_PLANNED"},
          "i4103" => %{"number" => 4103, "state" => "OPEN", "stateReason" => nil}
        })
      )

    assert {:ok, [written]} = PackStatus.refresh_sync(poller)
    assert written == context.pack_path

    # Drafts have no tracker fact and must not be invented.
    assert_receive {:query, query}, 1000
    assert query =~ "i4101: issue(number: 4101)"
    refute query =~ "4104"

    assert %{"members" => members} = Jason.decode!(File.read!(context.status_path))
    assert %{"lifecycle" => "completed", "observed_at" => "2026-08-02T12:00:00Z"} = members["4101"]
    assert %{"lifecycle" => "cancelled"} = members["4102"]
    assert %{"lifecycle" => "open"} = members["4103"]
    refute Map.has_key?(members, "4104")
  end

  test "a merged member renders 100% on the Build Order page after reconcile", context do
    previous_pack = Application.get_env(:aiur, :build_order_planning_pack)
    previous_membership = Application.get_env(:aiur, :build_order_planning_membership_snapshot)

    Application.put_env(:aiur, :build_order_planning_pack, context.pack_path)
    # No live membership at all: this is the second run of a Build Order whose
    # members merged during an earlier run.
    Application.put_env(:aiur, :build_order_planning_membership_snapshot, fn -> %{generation: 0, members: []} end)

    on_exit(fn ->
      if previous_pack,
        do: Application.put_env(:aiur, :build_order_planning_pack, previous_pack),
        else: Application.delete_env(:aiur, :build_order_planning_pack)

      if previous_membership,
        do: Application.put_env(:aiur, :build_order_planning_membership_snapshot, previous_membership),
        else: Application.delete_env(:aiur, :build_order_planning_membership_snapshot)
    end)

    # Before the projection exists only part of completion resolves. The zero
    # is retained with an explicit partial state rather than becoming a bare,
    # exact-looking percentage.
    initial_completion = grid().overall_completion
    assert initial_completion.progress == 0
    assert initial_completion.progress_resolution == :partial

    poller =
      start_poller(
        context.pack_path,
        issues_response(%{
          "i4101" => %{"number" => 4101, "state" => "CLOSED", "stateReason" => "COMPLETED"},
          "i4102" => %{"number" => 4102, "state" => "CLOSED", "stateReason" => "COMPLETED"},
          "i4103" => %{"number" => 4103, "state" => "OPEN", "stateReason" => nil}
        })
      )

    assert {:ok, [_written]} = PackStatus.refresh_sync(poller)

    grid = grid()
    assert grid.overall_completion.progress > 0
    assert Enum.find(grid.cards, &(&1.id == "4101")).state == :merged
    assert Enum.find(grid.cards, &(&1.id == "4101")).completion.progress == 100
    assert Enum.find(grid.cards, &(&1.id == "4103")).state != :merged
  end

  test "preserves unrelated status keys and earlier members", context do
    File.write!(context.status_path, ~s({"state":"active","members":{"4999":"completed"}}))

    poller =
      start_poller(
        context.pack_path,
        issues_response(%{
          "i4101" => %{"number" => 4101, "state" => "CLOSED", "stateReason" => "COMPLETED"},
          "i4102" => %{"number" => 4102, "state" => "OPEN", "stateReason" => nil},
          "i4103" => %{"number" => 4103, "state" => "OPEN", "stateReason" => nil}
        })
      )

    assert {:ok, [_written]} = PackStatus.refresh_sync(poller)

    status = Jason.decode!(File.read!(context.status_path))
    assert status["state"] == "active"
    assert status["members"]["4999"] == "completed"
    assert %{"lifecycle" => "completed"} = status["members"]["4101"]
  end

  test "does not rewrite an unchanged projection", context do
    {:ok, clock} = Agent.start_link(fn -> ~U[2026-08-02 12:00:00Z] end)
    assert :ok = PackStatus.subscribe()

    poller =
      start_poller(
        context.pack_path,
        issues_response(%{
          "i4101" => %{"number" => 4101, "state" => "CLOSED", "stateReason" => "COMPLETED"},
          "i4102" => %{"number" => 4102, "state" => "OPEN", "stateReason" => nil},
          "i4103" => %{"number" => 4103, "state" => "OPEN", "stateReason" => nil}
        }),
        now_fun: fn -> Agent.get(clock, & &1) end
      )

    assert {:ok, [_written]} = PackStatus.refresh_sync(poller)
    assert_receive {:build_order_pack_status_changed, %ProviderHealth{generation: generation}}, 1000
    body = File.read!(context.status_path)

    Agent.update(clock, fn _ -> ~U[2026-08-02 12:05:00Z] end)
    assert {:ok, [_written]} = PackStatus.refresh_sync(poller)

    # If the second cycle wrote, its later observed_at would change the body.
    assert File.read!(context.status_path) == body
    refute File.read!(context.status_path) =~ "2026-08-02T12:05:00Z"
    assert PackStatus.health(poller).generation == generation
    refute_receive {:build_order_pack_status_changed, _health}, 100
  end

  test "an invalid second chunk preserves its old state while committing the valid first chunk", context do
    tickets = Enum.map(1..51, &%{"ticket" => &1})
    File.write!(context.pack_path, Jason.encode!(%{"repository" => "acme/widgets", "tickets" => tickets}))
    previous = ~s({"members":{"51":"completed"}})
    File.write!(context.status_path, previous)

    request_fun = fn %{method: :post, body: %{"query" => query}} ->
      numbers = query_numbers(query)

      issues =
        Map.new(numbers, fn number ->
          state = if number == 51, do: "MYSTERY", else: "OPEN"
          {"i#{number}", %{"number" => number, "state" => state, "stateReason" => nil}}
        end)

      {:ok, %{status: 200, body: %{"data" => %{"repository" => issues}}}}
    end

    poller = start_poller(context.pack_path, request_fun)

    assert {:error, {:pack_refresh_failed, [incomplete_graphql_response: ["51"]]}} = PackStatus.refresh_sync(poller)
    members = context_members(context.pack_path)
    assert members["51"] == "completed"
    assert members["1"]["lifecycle"] == "open"
    assert map_size(members) == 51
  end

  test "a first-chunk failure halts later requests and preserves the projection", context do
    tickets = Enum.map(1..51, &%{"ticket" => &1})
    File.write!(context.pack_path, Jason.encode!(%{"repository" => "acme/widgets", "tickets" => tickets}))
    previous = ~s({"members":{"1":"completed"}})
    File.write!(context.status_path, previous)
    test = self()

    poller =
      start_poller(context.pack_path, fn _request ->
        send(test, :failed_chunk_request)
        {:ok, %{status: 502, body: %{}}}
      end)

    assert {:error, _reason} = PackStatus.refresh_sync(poller)
    assert_receive :failed_chunk_request, 1000
    refute_receive :failed_chunk_request, 100
    assert File.read!(context.status_path) == previous
    assert PackStatus.health(poller).state == :unavailable
  end

  test "an unknown closed reason preserves the projection", context do
    previous = ~s({"members":{"4101":"completed"}})
    File.write!(context.status_path, previous)

    poller =
      start_poller(
        context.pack_path,
        issues_response(%{
          "i4101" => %{"number" => 4101, "state" => "CLOSED", "stateReason" => nil},
          "i4102" => %{"number" => 4102, "state" => "OPEN", "stateReason" => nil},
          "i4103" => %{"number" => 4103, "state" => "OPEN", "stateReason" => nil}
        })
      )

    assert {:error, {:pack_refresh_failed, [incomplete_graphql_response: ["4101"]]}} = PackStatus.refresh_sync(poller)
    assert File.read!(context.status_path) == previous
  end

  test "a failed tracker read leaves the previous projection intact", context do
    File.write!(context.status_path, ~s({"members":{"4101":"completed"}}))

    poller =
      start_poller(context.pack_path, fn _request ->
        {:ok, %{status: 502, body: %{}}}
      end)

    assert {:error, _reason} = PackStatus.refresh_sync(poller)
    assert Jason.decode!(File.read!(context.status_path)) == %{"members" => %{"4101" => "completed"}}
  end

  test "an incomplete tracker response leaves the previous projection intact", context do
    previous = ~s({"members":{"4101":"completed","4102":"open","4103":"open"}})
    File.write!(context.status_path, previous)

    poller =
      start_poller(
        context.pack_path,
        issues_response(%{"i4101" => %{"number" => 4101, "state" => "CLOSED", "stateReason" => "COMPLETED"}})
      )

    assert {:error, {:pack_refresh_failed, [incomplete]}} = PackStatus.refresh_sync(poller)
    assert inspect(incomplete) =~ "incomplete_graphql_response"
    assert File.read!(context.status_path) == previous
    assert %ProviderHealth{state: :unavailable, complete?: false, failure: :pack_status_refresh_failed} = PackStatus.health(poller)
  end

  test "a corrupt status projection remains intact", context do
    previous = "{not-json"
    File.write!(context.status_path, previous)

    poller =
      start_poller(
        context.pack_path,
        issues_response(%{
          "i4101" => %{"number" => 4101, "state" => "CLOSED", "stateReason" => "COMPLETED"},
          "i4102" => %{"number" => 4102, "state" => "OPEN", "stateReason" => nil},
          "i4103" => %{"number" => 4103, "state" => "OPEN", "stateReason" => nil}
        })
      )

    assert {:error, {:pack_refresh_failed, [:invalid_status]}} = PackStatus.refresh_sync(poller)
    assert File.read!(context.status_path) == previous
  end
end
