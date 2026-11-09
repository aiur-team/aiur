defmodule Aiur.Orchestrator.SpendCap.StoreHealthTest do
  use ExUnit.Case, async: false

  alias Aiur.Orchestrator.SpendCap.Store
  alias Aiur.TestSupport.GroupedScopes, as: GS

  @topic "system.spend_cap.unavailable"

  setup do
    dir = Aiur.TestSupport.tmp_root!("spend-cap-health")
    File.mkdir_p!(dir)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "a persistence write error alerts with its cause and recovers on the next successful write", %{dir: dir} do
    failing = start_supervised!({Agent, fn -> false end}, id: make_ref())

    writer = fn path, json, opts ->
      if Agent.get(failing, & &1), do: {:error, :eio}, else: Aiur.Fs.atomic_write(path, json, opts)
    end

    store = start_store(dir, writer: writer)
    identity = GS.identity(5693)

    Agent.update(failing, fn _ -> true end)
    assert {:error, :spend_cap_write_failed} = Store.put(store, identity, "5.00")
    assert Store.health(store) == {:unavailable, :spend_cap_write_failed}
    assert Store.admission(store, identity) == {:skip, :spend_cap_unavailable}

    assert_receive {:alert, @topic, opts}, 1_000
    assert opts[:needs_attention] == true
    assert opts[:reason] =~ "spend_cap_write_failed"

    Agent.update(failing, fn _ -> false end)
    assert_receive {:alert, @topic <> ".resolved", resolved}, 1_000
    assert resolved[:needs_attention] == false
    assert Store.health(store) == :healthy
    assert Store.admission(store, identity) == :allow
    assert {:ok, %{"state" => "active"}} = Store.put(store, identity, "5.00")
    refute_received {:alert, @topic, _opts}
  end

  test "a failed subscription re-subscribes automatically and recovers", %{dir: dir} do
    owner = self()
    attempts = start_supervised!({Agent, fn -> 0 end}, id: make_ref())

    subscribe = fn ->
      attempt = Agent.get_and_update(attempts, &{&1 + 1, &1 + 1})
      send(owner, {:subscribe_attempt, attempt})
      if attempt == 1, do: {:error, :pubsub_unavailable}, else: :ok
    end

    store = start_store(dir, subscribe_fun: subscribe)

    assert_receive {:subscribe_attempt, 1}, 1_000
    assert_receive {:alert, @topic, opts}, 1_000
    assert opts[:reason] =~ "spend_cap_subscription_failed"

    assert_receive {:subscribe_attempt, 2}, 1_000
    assert_receive {:alert, @topic <> ".resolved", _resolved}, 1_000
    assert Store.health(store) == :healthy
    refute_receive {:subscribe_attempt, 3}, 100
  end

  test "an unreadable state directory is retried until it loads", %{dir: dir} do
    state_dir = Path.join(dir, "state")
    File.write!(state_dir, "not a directory")

    store = start_store(state_dir, [])
    assert {:unavailable, :spend_cap_state_unavailable} = Store.health(store)
    assert_receive {:alert, @topic, _opts}, 1_000

    File.rm!(state_dir)
    assert_receive {:alert, @topic <> ".resolved", _resolved}, 1_000
    assert Store.health(store) == :healthy
  end

  defp start_store(dir, opts) do
    owner = self()

    base = [
      name: nil,
      table: nil,
      state_dir: dir,
      repository: "its-everdred/aiur",
      subscribe_fun: fn -> :ok end,
      running_subscribe_fun: fn -> :ok end,
      usage_fun: fn _identity -> usage("1.25") end,
      alert_fun: fn topic, alert_opts ->
        send(owner, {:alert, topic, alert_opts})
        :ok
      end,
      retry_ms: 10,
      retry_max_ms: 20
    ]

    {:ok, store} = start_supervised({Store, Keyword.merge(base, opts)})
    store
  end

  defp usage(amount) do
    %{
      state: :known,
      authority: %{schema_version: 1, aggregate_generation: 3, source_position: 8, source_generation: 2, price_table_revision: "prices-v1"},
      api_equivalent_estimate: %{rollup: %{"USD" => Decimal.new(amount)}, coverage: %{status: :complete, known: 1, unknown: 0, reasons: []}}
    }
  end
end
