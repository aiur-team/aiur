defmodule Aiur.BuildOrder.PackStatus.HealthTest do
  use Aiur.BuildOrder.PackStatusCase

  test "a failed refresh marks retained completion stale without discarding it", context do
    {:ok, response} = Agent.start_link(fn -> :success end)
    {:ok, clock} = Agent.start_link(fn -> ~U[2026-08-02 12:00:00Z] end)
    test = self()

    request_fun = fn _request ->
      case Agent.get(response, & &1) do
        :success ->
          send(test, {:successful_request, self()})

          {:ok,
           %{
             status: 200,
             body: %{
               "data" => %{
                 "repository" => %{
                   "i4101" => %{"number" => 4101, "state" => "CLOSED", "stateReason" => "COMPLETED"},
                   "i4102" => %{"number" => 4102, "state" => "OPEN", "stateReason" => nil},
                   "i4103" => %{"number" => 4103, "state" => "OPEN", "stateReason" => nil}
                 }
               }
             }
           }}

        :failure ->
          send(test, {:failed_request, self()})
          {:ok, %{status: 502, body: %{}}}
      end
    end

    poller = start_poller(context.pack_path, request_fun, now_fun: fn -> Agent.get(clock, & &1) end)

    Application.put_env(:aiur, :build_order_planning_pack, context.pack_path)

    Application.put_env(:aiur, :build_order_planning_membership_snapshot, fn ->
      %{generation: 0, health: :healthy, freshness: %{status: :fresh}, members: []}
    end)

    Application.put_env(:aiur, :build_order_pack_status_health_snapshot, fn -> PackStatus.health(poller) end)
    assert :ok = PackStatus.subscribe()

    on_exit(fn ->
      Application.delete_env(:aiur, :build_order_planning_pack)
      Application.delete_env(:aiur, :build_order_planning_membership_snapshot)
    end)

    initial_generation = PlanningSource.catalog().generation

    assert :ok = PackStatus.refresh(poller)
    assert_receive {:successful_request, successful_task}, @async_assert_timeout
    assert await_task(successful_task)
    assert_receive {:build_order_pack_status_changed, %ProviderHealth{state: :healthy}}, @async_assert_timeout
    assert %ProviderHealth{state: :healthy, complete?: true, last_success_at: ~U[2026-08-02 12:00:00Z]} = PackStatus.health(poller)
    healthy_snapshot = PlanningSource.catalog()
    assert healthy_snapshot.health.state == :healthy
    assert healthy_snapshot.status_health.state == :healthy
    assert healthy_snapshot.generation > initial_generation

    Agent.update(response, fn _ -> :failure end)
    Agent.update(clock, fn _ -> ~U[2026-08-02 12:05:00Z] end)

    assert :ok = PackStatus.refresh(poller)
    assert_receive {:failed_request, failed_task}, @async_assert_timeout
    assert await_task(failed_task)
    assert_receive {:build_order_pack_status_changed, %ProviderHealth{state: :stale}}, @async_assert_timeout

    assert %ProviderHealth{
             state: :stale,
             complete?: false,
             observed_at: ~U[2026-08-02 12:00:00Z],
             last_success_at: ~U[2026-08-02 12:00:00Z],
             last_attempt_at: ~U[2026-08-02 12:05:00Z]
           } = PackStatus.health(poller)

    snapshot = PlanningSource.catalog()
    assert snapshot.health.state == :healthy
    assert snapshot.status_health.state == :stale
    assert snapshot.status_health.failure == :pack_status_refresh_failed
    assert snapshot.generation == healthy_snapshot.generation

    [root] = snapshot.data.entries
    {:ok, selected} = PlanningSource.demand(root.identity)
    grid = selected |> BuildOrderPresenter.present(:unavailable, :unavailable) |> BuildOrderGridModel.build(nil)

    assert Enum.find(grid.cards, &(&1.id == "4101")).state == :merged
    assert Enum.find(grid.cards, &(&1.id == "4101")).completion.progress == 100
  end

  test "reports unavailable without a token rather than clearing status", context do
    poller =
      start_supervised!(
        {PackStatus,
         name: nil,
         poll_on_start: false,
         paths_fun: fn -> [context.pack_path] end,
         repo_fun: fn -> {:ok, {"acme", "widgets"}} end,
         token_fun: fn -> {:error, :missing_token} end,
         request_fun: fn _request -> flunk("must not reach GitHub without a token") end}
      )

    assert {:error, :missing_token} = PackStatus.refresh_sync(poller)
    refute File.exists?(context.status_path)

    assert %ProviderHealth{state: :unavailable, complete?: false, failure: :pack_status_refresh_failed} =
             PackStatus.health(poller)
  end

  test "a restarted poller keeps health generations monotonic", context do
    {:ok, response} = Agent.start_link(fn -> "COMPLETED" end)

    request_fun = fn _request ->
      reason = Agent.get(response, & &1)

      issues = %{
        "i4101" => %{"number" => 4101, "state" => "CLOSED", "stateReason" => reason},
        "i4102" => %{"number" => 4102, "state" => "OPEN", "stateReason" => nil},
        "i4103" => %{"number" => 4103, "state" => "OPEN", "stateReason" => nil}
      }

      {:ok, %{status: 200, body: %{"data" => %{"repository" => issues}}}}
    end

    opts = [
      name: nil,
      poll_on_start: false,
      paths_fun: fn -> [context.pack_path] end,
      token_fun: fn -> {:ok, "token"} end,
      request_fun: request_fun
    ]

    first = start_supervised!({PackStatus, opts})
    assert {:ok, [_written]} = PackStatus.refresh_sync(first)
    first_generation = PackStatus.health(first).generation

    Agent.update(response, fn _ -> nil end)
    assert {:error, _reason} = PackStatus.refresh_sync(first)
    second_generation = PackStatus.health(first).generation
    assert second_generation == first_generation

    Agent.update(response, fn _ -> "NOT_PLANNED" end)
    assert {:ok, [_written]} = PackStatus.refresh_sync(first)
    last_generation = PackStatus.health(first).generation
    assert last_generation > second_generation
    assert :ok = stop_supervised(PackStatus)

    second = start_supervised!({PackStatus, name: nil, poll_on_start: false})

    assert PackStatus.health(second).generation > last_generation
  end

  test "a changed sibling advances generation when another pack fails", context do
    invalid_pack = Path.join(Path.dirname(context.pack_path), "invalid.json")
    File.write!(invalid_pack, "not-json")

    poller =
      start_supervised!(
        {PackStatus,
         name: nil,
         poll_on_start: false,
         paths_fun: fn -> [context.pack_path, invalid_pack] end,
         token_fun: fn -> {:ok, "token"} end,
         request_fun:
           issues_response(%{
             "i4101" => %{"number" => 4101, "state" => "CLOSED", "stateReason" => "COMPLETED"},
             "i4102" => %{"number" => 4102, "state" => "OPEN", "stateReason" => nil},
             "i4103" => %{"number" => 4103, "state" => "OPEN", "stateReason" => nil}
           })}
      )

    initial_generation = PackStatus.health(poller).generation

    assert {:error, {:pack_refresh_failed, [_invalid]}} = PackStatus.refresh_sync(poller)
    assert PackStatus.health(poller).generation > initial_generation
    assert %{"members" => %{"4101" => %{"lifecycle" => "completed"}}} = Jason.decode!(File.read!(context.status_path))
  end
end
