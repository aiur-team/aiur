defmodule Aiur.Orchestrator.SpendCap.StoreTest do
  use ExUnit.Case, async: false

  alias Aiur.Orchestrator.SpendCap.{Record, Store}
  alias Aiur.TestSupport.GroupedScopes, as: GS

  setup do
    dir = Aiur.TestSupport.tmp_root!("spend-cap-store")
    File.mkdir_p!(dir)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "persists exhaustion before stopping and finishes versioned effects in order", %{dir: dir} do
    owner = self()
    identity = GS.identity(5693)

    {:ok, store} =
      start_supervised(
        {Store,
         name: nil,
         table: nil,
         state_dir: dir,
         repository: "its-everdred/aiur",
         subscribe_fun: fn -> :ok end,
         usage_fun: fn ^identity -> usage("1.25") end,
         now_fun: fn -> ~U[2026-10-24 20:01:00Z] end,
         reserve_event_id_fun: fn -> {:ok, 42} end,
         stop_fun: fn stopped, end_state ->
           checkpoint = File.read!(Path.join(dir, "ticket-spend-caps.json"))
           send(owner, {:stopped, stopped, end_state, checkpoint})
           :ok
         end,
         event_fun: fn topic, payload, event_id ->
           send(owner, {:event, topic, payload, event_id})
           {:ok, event_id, 1}
         end,
         transition_fun: fn identifier, state ->
           send(owner, {:transition, self(), identifier, state})

           receive do
             :complete_transition -> :ok
           end
         end,
         task_start_fun: tracked_task_start(owner)}
      )

    assert {:ok, payload} = Store.put(store, identity, "1.25")
    assert payload["state"] == "budget_exhausted"
    assert payload["end_state"] == "budget_exhausted"

    assert_receive {:stopped, ^identity, :budget_exhausted, checkpoint}, 1_000
    assert Jason.decode!(checkpoint)["records"] |> hd() |> Map.fetch!("state") == "budget_exhausted"

    assert_receive {:event, "ticket.5693.usage.spend_cap_reached", event, 42}, 1_000
    assert event["contract"] == "aiur.ticket_spend_cap_reached"
    assert event["contract_version"] == 1
    assert event["end_state"] == "budget_exhausted"
    assert event["job_id"] == "5693"

    assert_receive {:transition, transition_task, "5693", "budget-exhausted"}, 1_000
    assert Store.delete(store, "5693") == {:error, :exhaustion_transition_pending}
    send(transition_task, :complete_transition)

    await_effect_tasks(3)
    assert {:ok, %{"effects" => %{"tracker_transition" => "completed"}}} = Store.get(store, "5693")
    assert :ok = Store.delete(store, "5693")
  end

  test "usage aggregate updates enforce a cap that was configured below the threshold", %{dir: dir} do
    owner = self()
    identity = GS.identity(5693)
    {:ok, spend} = Agent.start_link(fn -> "0.50" end)

    on_exit(fn ->
      if Process.alive?(spend), do: Agent.stop(spend)
    end)

    {:ok, store} =
      start_supervised(
        {Store,
         name: nil,
         table: nil,
         state_dir: dir,
         repository: "its-everdred/aiur",
         subscribe_fun: fn -> :ok end,
         usage_fun: fn ^identity -> usage(Agent.get(spend, & &1)) end,
         snapshot_fun: fn -> %{spend: Agent.get(spend, & &1)} end,
         project_fun: fn %{spend: amount}, ^identity -> usage(amount) end,
         reserve_event_id_fun: fn -> {:ok, 43} end,
         stop_fun: fn stopped, end_state ->
           send(owner, {:stopped_after_update, stopped, end_state})
           :ok
         end,
         event_fun: fn _topic, _payload, event_id -> {:ok, event_id, 0} end,
         transition_fun: fn _identifier, _state -> :ok end,
         task_start_fun: tracked_task_start(owner)}
      )

    assert {:ok, %{"state" => "active"}} = Store.put(store, identity, "1.00")
    send(store, {:running_changed, [%{status: :running, identifier: "5693", tracker_identity: identity}]})
    Agent.update(spend, fn _current -> "1.00" end)
    send(store, {:usage_aggregate_changed, %{generation: 4}})

    assert_receive {:stopped_after_update, ^identity, :budget_exhausted}, 1_000
    await_effect_tasks(3)
    assert {:ok, %{"state" => "budget_exhausted"}} = Store.get(store, "5693")
  end

  test "restart reuses the persisted event id and resumes only unfinished effects", %{dir: dir} do
    owner = self()
    identity = GS.identity(5693)
    path = Path.join(dir, "ticket-spend-caps.json")

    {:ok, first} =
      start_supervised(
        {Store,
         name: nil,
         table: nil,
         state_dir: dir,
         repository: "its-everdred/aiur",
         subscribe_fun: fn -> :ok end,
         usage_fun: fn ^identity -> usage("1.00") end,
         reserve_event_id_fun: fn -> {:ok, 42} end,
         stop_fun: fn _identity, :budget_exhausted -> :ok end,
         event_fun: fn _topic, _payload, event_id ->
           send(owner, {:first_event_attempt, event_id})
           {:error, :offline}
         end,
         transition_fun: fn _identifier, _state -> flunk("transition must wait for the event") end,
         task_start_fun: tracked_task_start(owner),
         retry_ms: 60_000}
      )

    assert {:ok, %{"state" => "budget_exhausted"}} = Store.put(first, identity, "1.00")
    assert_receive {:first_event_attempt, 42}, 1_000
    await_effect_tasks(2)
    assert {:ok, %{"effects" => %{"stop" => "completed", "event" => "pending"}}} = Store.get(first, "5693")

    record = path |> File.read!() |> Jason.decode!() |> Map.fetch!("records") |> hd()
    assert record["event_id"] == 42
    assert record["effects"]["stop"] == "completed"
    assert record["effects"]["event"] == "pending"

    assert :ok = stop_supervised(Store)

    {:ok, _second} =
      start_supervised(
        {Store,
         name: nil,
         table: nil,
         state_dir: dir,
         repository: "its-everdred/aiur",
         subscribe_fun: fn -> :ok end,
         usage_fun: fn _identity -> flunk("exhausted records must not be re-evaluated") end,
         reserve_event_id_fun: fn -> flunk("the persisted event id must be reused") end,
         stop_fun: fn _identity, _end_state -> flunk("completed stop must not be repeated") end,
         event_fun: fn topic, payload, event_id ->
           send(owner, {:retried_event, topic, payload, event_id})
           {:ok, event_id, 1}
         end,
         transition_fun: fn identifier, state ->
           send(owner, {:resumed_transition, identifier, state})
           :ok
         end}
      )

    assert_receive {:retried_event, "ticket.5693.usage.spend_cap_reached", %{"end_state" => "budget_exhausted"}, 42}, 1_000
    assert_receive {:resumed_transition, "5693", "budget-exhausted"}, 1_000
  end

  test "a ticket cap never includes another ticket's recorded cost", %{dir: dir} do
    identity = GS.identity(5693)
    other = GS.identity(77)

    {:ok, store} =
      start_supervised(
        {Store,
         name: nil,
         table: nil,
         state_dir: dir,
         repository: "its-everdred/aiur",
         subscribe_fun: fn -> :ok end,
         usage_fun: fn
           ^identity -> usage("0.50")
           ^other -> usage("50.00")
         end}
      )

    assert {:ok, payload} = Store.put(store, identity, "1.00")
    assert payload["state"] == "active"
    assert payload["spent_amount"] == "0.50"
    assert payload["remaining_amount"] == "0.50"
  end

  test "corrupt state fails closed instead of resetting caps", %{dir: dir} do
    File.write!(Path.join(dir, "ticket-spend-caps.json"), "not json")

    {:ok, store} =
      start_supervised({Store, name: nil, table: nil, state_dir: dir, repository: "its-everdred/aiur", subscribe_fun: fn -> :ok end})

    assert Store.health(store) == {:unavailable, :spend_cap_state_corrupt}
    assert Store.admission(store, GS.identity(5693)) == {:skip, :spend_cap_unavailable}
    assert {:error, :spend_cap_unavailable} = Store.put(store, GS.identity(5693), "1.00")
  end

  test "a future checkpoint version fails closed without discarding the file", %{dir: dir} do
    path = Path.join(dir, "ticket-spend-caps.json")
    File.write!(path, Jason.encode!(%{"version" => 2, "repository" => "its-everdred/aiur", "records" => []}))

    {:ok, store} =
      start_supervised({Store, name: nil, table: nil, state_dir: dir, repository: "its-everdred/aiur", subscribe_fun: fn -> :ok end})

    assert Store.health(store) == {:unavailable, :version_unsupported}
    assert File.exists?(path)
  end

  test "logically contradictory persisted state fails closed", %{dir: dir} do
    record = Record.new!(GS.identity(5693), "1.00", ~U[2026-10-24 20:00:00Z])
    encoded = record |> Record.encode() |> Map.put("end_state", "budget_exhausted")
    checkpoint = Jason.encode!(%{"version" => 1, "repository" => "its-everdred/aiur", "records" => [encoded]})
    File.write!(Path.join(dir, "ticket-spend-caps.json"), checkpoint)

    {:ok, store} =
      start_supervised({Store, name: nil, table: nil, state_dir: dir, repository: "its-everdred/aiur", subscribe_fun: fn -> :ok end})

    assert Store.health(store) == {:unavailable, :spend_cap_state_corrupt}
  end

  test "a failed usage subscription makes dispatch fail closed", %{dir: dir} do
    {:ok, store} =
      start_supervised({Store, name: nil, table: nil, state_dir: dir, repository: "its-everdred/aiur", subscribe_fun: fn -> {:error, :pubsub_unavailable} end})

    assert Store.health(store) == {:unavailable, :spend_cap_subscription_failed}
    assert Store.admission(store, GS.identity(5693)) == {:skip, :spend_cap_unavailable}
  end

  test "the first checkpoint syncs its directory entry exactly once", %{dir: dir} do
    owner = self()
    identity = GS.identity(5693)

    {:ok, store} =
      start_supervised(
        {Store,
         name: nil,
         table: nil,
         state_dir: dir,
         repository: "its-everdred/aiur",
         subscribe_fun: fn -> :ok end,
         usage_fun: fn ^identity -> usage("0.25") end,
         filesystem_sync_fun: fn ->
           send(owner, :filesystem_synced)
           :ok
         end}
      )

    assert {:ok, %{"state" => "active"}} = Store.put(store, identity, "1.00")
    assert_receive :filesystem_synced, 1_000
    assert {:ok, %{"state" => "active"}} = Store.put(store, identity, "2.00")
    refute_receive :filesystem_synced, 50
  end

  test "a mismatched event receipt stays parked until its retry delay", %{dir: dir} do
    owner = self()
    identity = GS.identity(5693)

    {:ok, store} =
      start_supervised(
        {Store,
         name: nil,
         table: nil,
         state_dir: dir,
         repository: "its-everdred/aiur",
         subscribe_fun: fn -> :ok end,
         usage_fun: fn ^identity -> usage("1.00") end,
         reserve_event_id_fun: fn -> {:ok, 51} end,
         stop_fun: fn _identity, :budget_exhausted -> :ok end,
         event_fun: fn _topic, _payload, 51 ->
           send(owner, :event_attempted)
           {:ok, 99, 0}
         end,
         transition_fun: fn _identifier, _state -> flunk("transition must wait for the event") end,
         retry_ms: 60_000}
      )

    assert {:ok, %{"state" => "budget_exhausted"}} = Store.put(store, identity, "1.00")
    assert_receive :event_attempted, 1_000

    send(store, {:usage_aggregate_changed, %{generation: 5}})
    refute_receive :event_attempted, 100
  end

  test "a failed stop blocks later effects until the stop retry succeeds", %{dir: dir} do
    owner = self()
    identity = GS.identity(5693)
    {:ok, attempts} = Agent.start_link(fn -> 0 end)
    on_exit(fn -> if Process.alive?(attempts), do: Agent.stop(attempts) end)

    {:ok, store} =
      start_supervised(
        {Store,
         name: nil,
         table: nil,
         state_dir: dir,
         repository: "its-everdred/aiur",
         subscribe_fun: fn -> :ok end,
         usage_fun: fn ^identity -> usage("1.00") end,
         stop_fun: fn _identity, :budget_exhausted ->
           attempt = Agent.get_and_update(attempts, &{&1 + 1, &1 + 1})
           send(owner, {:stop_attempt, attempt})
           if attempt == 1, do: {:error, :busy}, else: :ok
         end,
         reserve_event_id_fun: fn -> {:ok, 52} end,
         event_fun: fn _topic, _payload, 52 ->
           send(owner, :event_after_stop)
           {:ok, 52, 0}
         end,
         transition_fun: fn _identifier, _state -> :ok end,
         retry_ms: 20}
      )

    assert {:ok, %{"state" => "budget_exhausted"}} = Store.put(store, identity, "1.00")
    assert_receive {:stop_attempt, 1}, 1_000
    refute_receive :event_after_stop, 10
    assert_receive {:stop_attempt, 2}, 1_000
    assert_receive :event_after_stop, 1_000
  end

  test "restart resumes a pending tracker transition without repeating completed effects", %{dir: dir} do
    owner = self()
    identity = GS.identity(5693)

    first_opts = [
      name: nil,
      table: nil,
      state_dir: dir,
      repository: "its-everdred/aiur",
      subscribe_fun: fn -> :ok end,
      usage_fun: fn ^identity -> usage("1.00") end,
      stop_fun: fn _identity, :budget_exhausted -> :ok end,
      reserve_event_id_fun: fn -> {:ok, 53} end,
      event_fun: fn _topic, _payload, 53 -> {:ok, 53, 0} end,
      transition_fun: fn "5693", "budget-exhausted" ->
        send(owner, :first_transition_attempt)
        {:error, :offline}
      end,
      retry_ms: 60_000
    ]

    {:ok, first} = start_supervised({Store, first_opts})
    assert {:ok, %{"state" => "budget_exhausted"}} = Store.put(first, identity, "1.00")
    assert_receive :first_transition_attempt, 1_000
    assert :ok = stop_supervised(Store)

    {:ok, _second} =
      start_supervised(
        {Store,
         name: nil,
         table: nil,
         state_dir: dir,
         repository: "its-everdred/aiur",
         subscribe_fun: fn -> :ok end,
         usage_fun: fn _identity -> flunk("exhausted state must not be re-evaluated") end,
         stop_fun: fn _identity, _state -> flunk("completed stop must not repeat") end,
         reserve_event_id_fun: fn -> flunk("persisted event id must be reused") end,
         event_fun: fn _topic, _payload, _event_id -> flunk("completed event must not repeat") end,
         transition_fun: fn "5693", "budget-exhausted" ->
           send(owner, :resumed_tracker_transition)
           :ok
         end}
      )

    assert_receive :resumed_tracker_transition, 1_000
  end

  defp usage(amount) do
    %{
      state: :known,
      authority: %{schema_version: 1, aggregate_generation: 3, source_position: 8, source_generation: 2, price_table_revision: "prices-v1"},
      api_equivalent_estimate: %{rollup: %{"USD" => Decimal.new(amount)}, coverage: %{status: :complete, known: 1, unknown: 0, reasons: []}}
    }
  end

  defp tracked_task_start(owner) do
    fn run ->
      Task.start_link(fn ->
        run.()
        send(owner, :spend_cap_effect_finished)
      end)
    end
  end

  defp await_effect_tasks(count) do
    Enum.each(1..count, fn _index -> assert_receive :spend_cap_effect_finished, 1_000 end)
  end
end
