defmodule Aiur.Orchestrator.SpendCap.StoreRefreshTest do
  use ExUnit.Case, async: false

  alias Aiur.Orchestrator.SpendCap.{Evaluation, Record, Store}
  alias Aiur.TestSupport.GroupedScopes, as: GS

  setup do
    root = Aiur.TestSupport.tmp_root!("spend-cap-refresh")
    File.mkdir_p!(root)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)
    %{root: root}
  end

  test "coalesces broadcasts into one snapshot and projects only running nonterminal caps", %{root: root} do
    owner = self()
    running = GS.identity(5693)
    idle = GS.identity(77)
    exhausted = GS.identity(88)

    usage_fun = fn
      ^running -> usage("0.25")
      ^idle -> usage("0.10")
      ^exhausted -> usage("1.00")
    end

    {:ok, store} =
      start_store(root,
        usage_fun: usage_fun,
        snapshot_fun: fn ->
          send(owner, :snapshot_read)
          %{generation: 9}
        end,
        project_fun: fn %{generation: 9}, identity ->
          send(owner, {:projected, identity})
          usage_fun.(identity)
        end,
        refresh_debounce_ms: 20,
        reserve_event_id_fun: fn -> {:ok, 71} end,
        stop_fun: fn _identity, _reason -> :ok end,
        event_fun: fn _topic, _payload, event_id -> {:ok, event_id, 0} end,
        transition_fun: fn _identifier, _state -> :ok end
      )

    assert {:ok, %{"state" => "active"}} = Store.put(store, running, "1.00")
    assert {:ok, %{"state" => "active"}} = Store.put(store, idle, "1.00")
    assert {:ok, %{"state" => "budget_exhausted"}} = Store.put(store, exhausted, "1.00")

    send(store, {:usage_aggregate_changed, %{generation: 9}})
    refute_receive :snapshot_read, 50

    send(store, {
      :running_changed,
      [
        %{status: :running, identifier: "5693", tracker_identity: running},
        %{status: :running, identifier: "88", tracker_identity: exhausted}
      ]
    })

    send(store, {:usage_aggregate_changed, %{generation: 10}})
    send(store, {:usage_aggregate_changed, %{generation: 11}})
    send(store, {:usage_aggregate_changed, %{generation: 12}})

    assert_receive :snapshot_read, 1_000
    assert_receive {:projected, ^running}, 1_000
    refute_receive {:projected, ^idle}, 50
    refute_receive {:projected, ^exhausted}, 50
    refute_receive :snapshot_read, 50
  end

  test "partial coverage stays active on known spend and raises one attention", %{root: root} do
    owner = self()
    identity = GS.identity(5693)
    {:ok, coverage} = Agent.start_link(fn -> :partial end)
    on_exit(fn -> if Process.alive?(coverage), do: Agent.stop(coverage) end)

    usage_fun = fn ^identity -> usage("0.50", Agent.get(coverage, & &1)) end

    {:ok, store} =
      start_store(root,
        usage_fun: usage_fun,
        alert_fun: fn topic, opts ->
          send(owner, {:alert, topic, opts})
          :ok
        end
      )

    assert {:ok, payload} = Store.put(store, identity, "1.00")
    assert payload["state"] == "active"
    assert payload["coverage"]["status"] == "partial"

    assert_receive {:alert, "ticket.5693.usage.spend_cap_partial", opts}, 1_000
    assert opts[:needs_attention]
    assert opts[:severity] == "warning"

    assert {:ok, %{"state" => "active"}} = Store.get(store, "5693")
    refute_receive {:alert, "ticket.5693.usage.spend_cap_partial", _opts}, 50

    Agent.update(coverage, fn _status -> :complete end)
    assert {:ok, payload} = Store.get(store, "5693")
    assert payload["coverage"]["status"] == "known"
    assert_receive {:alert, "ticket.5693.usage.spend_cap_partial.resolved", resolved}, 1_000
    refute resolved[:needs_attention]
  end

  test "unavailable usage closes dispatch but does not stop an already-running agent", %{root: root} do
    owner = self()
    identity = GS.identity(5693)
    {:ok, projection} = Agent.start_link(fn -> usage("0.25") end)
    on_exit(fn -> if Process.alive?(projection), do: Agent.stop(projection) end)

    {:ok, store} =
      start_store(root,
        usage_fun: fn ^identity -> Agent.get(projection, & &1) end,
        snapshot_fun: fn -> %{generation: 5} end,
        project_fun: fn %{generation: 5}, ^identity ->
          result = Agent.get(projection, & &1)
          send(owner, :projection_read)
          result
        end,
        stop_fun: fn _identity, _reason ->
          send(owner, :stop_requested)
          :ok
        end,
        refresh_debounce_ms: 10
      )

    assert {:ok, %{"state" => "active"}} = Store.put(store, identity, "1.00")
    Agent.update(projection, fn _usage -> %{state: :unavailable} end)
    send(store, {:running_changed, [%{status: :running, identifier: "5693", tracker_identity: identity}]})
    send(store, {:usage_aggregate_changed, %{generation: 5}})

    assert_receive :projection_read, 1_000
    _state = :sys.get_state(store)
    assert Store.admission(store, identity) == {:skip, :spend_cap_unavailable}
    assert {:ok, %{"state" => "unavailable", "spent_amount" => nil}} = Store.get(store, "5693")
    refute_receive :stop_requested, 50
  end

  test "startup returns while a restored pending tracker effect is blocked", %{root: root} do
    owner = self()
    identity = GS.identity(5693)
    state_dir = Path.join(root, "restored")
    File.mkdir_p!(state_dir)

    record = Record.new!(identity, "1.00", ~U[2026-10-24 20:00:00Z])
    {:reached, record} = Evaluation.refresh(record, usage("1.00"), ~U[2026-10-24 20:01:00Z])

    record =
      record
      |> Map.put(:event_id, 42)
      |> Record.effect(:stop, :completed)
      |> Record.effect(:event, :completed)

    checkpoint = %{version: 1, repository: "its-everdred/aiur", records: [Record.encode(record)]}
    File.write!(Path.join(state_dir, "ticket-spend-caps.json"), Jason.encode!(checkpoint))

    starter =
      Task.async(fn ->
        Store.start_link(
          name: nil,
          table: nil,
          state_dir: state_dir,
          repository: "its-everdred/aiur",
          subscribe_fun: fn -> :ok end,
          running_subscribe_fun: fn -> :ok end,
          usage_fun: fn _identity -> flunk("terminal records must not be projected at startup") end,
          transition_fun: fn "5693", "budget-exhausted" ->
            send(owner, {:tracker_effect_started, self()})

            receive do
              :finish_tracker_effect -> :ok
            end
          end,
          task_start_fun: fn run -> Task.start_link(run) end
        )
      end)

    assert {:ok, store} = Task.await(starter, 500)
    on_exit(fn -> if Process.alive?(store), do: GenServer.stop(store) end)
    assert_receive {:tracker_effect_started, effect_task}, 1_000
    send(effect_task, :finish_tracker_effect)
  end

  test "usage recovery re-admits an idle unavailable ticket", %{root: root} do
    owner = self()
    identity = GS.identity(5693)
    {:ok, projection} = Agent.start_link(fn -> usage("0.25") end)
    on_exit(fn -> if Process.alive?(projection), do: Agent.stop(projection) end)

    {:ok, store} =
      start_store(root,
        usage_fun: fn ^identity -> Agent.get(projection, & &1) end,
        snapshot_fun: fn -> %{generation: 6} end,
        project_fun: fn %{generation: 6}, ^identity ->
          send(owner, :recovery_projection_read)
          Agent.get(projection, & &1)
        end,
        refresh_debounce_ms: 10
      )

    assert {:ok, %{"state" => "active"}} = Store.put(store, identity, "1.00")

    Agent.update(projection, fn _usage -> %{state: :unavailable} end)
    assert {:ok, %{"state" => "unavailable"}} = Store.get(store, "5693")
    assert Store.admission(store, identity) == {:skip, :spend_cap_unavailable}

    Agent.update(projection, fn _usage -> usage("0.25") end)
    send(store, {:usage_aggregate_changed, %{generation: 6}})

    assert_receive :recovery_projection_read, 1_000
    _state = :sys.get_state(store)
    assert Store.admission(store, identity) == :allow
    assert {:ok, %{"state" => "active", "spent_amount" => "0.25"}} = Store.get(store, "5693")
  end

  test "state directory is owner-only", %{root: root} do
    state_dir = Path.join(root, "owner-only")
    File.mkdir_p!(state_dir)
    File.chmod!(state_dir, 0o755)
    {:ok, _store} = start_store(state_dir)

    assert Bitwise.band(File.stat!(state_dir).mode, 0o777) == 0o700
  end

  defp start_store(state_dir, opts \\ []) do
    defaults = [
      name: nil,
      table: nil,
      state_dir: state_dir,
      repository: "its-everdred/aiur",
      subscribe_fun: fn -> :ok end,
      running_subscribe_fun: fn -> :ok end,
      usage_fun: fn _identity -> usage("0.25") end
    ]

    start_supervised({Store, Keyword.merge(defaults, opts)})
  end

  defp usage(amount, coverage \\ :complete) do
    coverage =
      case coverage do
        :complete -> %{status: :known, known: 1, unknown: 0, reasons: []}
        :partial -> %{status: :partial, known: 1, unknown: 1, reasons: [:unknown_model]}
      end

    %{
      state: :known,
      authority: %{schema_version: 1, aggregate_generation: 3, source_position: 8, source_generation: 2, price_table_revision: "prices-v1"},
      api_equivalent_estimate: %{rollup: %{"USD" => Decimal.new(amount)}, coverage: coverage}
    }
  end
end
