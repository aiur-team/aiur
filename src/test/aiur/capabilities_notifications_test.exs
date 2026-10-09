defmodule Aiur.CapabilitiesNotificationsTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias Aiur.Capabilities
  alias Aiur.Capabilities.{Monitor, Table}

  defmodule Provider do
    @behaviour Aiur.Capabilities.Provider
    @impl true
    def capability_ids, do: ["test.notifications"]
    @impl true
    def capabilities(_context), do: Agent.get(__MODULE__, &%{"test.notifications" => %{state: &1}})
  end

  setup do
    start_supervised!(%{id: Provider, start: {Agent, :start_link, [fn -> :available end, [name: Provider]]}})
    table = String.to_atom("capability_notifications_#{System.unique_integer([:positive])}")
    start_supervised!({Table, table: table, name: nil})
    Phoenix.PubSub.subscribe(Aiur.PubSub, "capabilities")
    owner = self()

    publish = fn topic, payload, opts ->
      send(owner, {:published, topic, payload, opts, Capabilities.report(table: table).revision})
      {:ok, 1, 0}
    end

    %{opts: [table: table, providers: [Provider], name: nil, tick_ms: 60_000, publish_fun: publish]}
  end

  test "publishes once per revision change with only revision and boot ID after storing the report", %{opts: opts} do
    pid = monitor(opts)
    assert_notification(1)

    for {state, revision} <- [{:unavailable, 2}, {:available, 3}] do
      Agent.update(Provider, fn _ -> state end)
      tick(pid)
      assert_notification(revision)
    end

    refute_received {:published, _, _, _, _}
    refute_received {:capabilities_changed, _}
  end

  test "unchanged ticks and monitor restart do not publish or broadcast", %{opts: opts} do
    pid = monitor(opts)
    assert_notification(1)
    tick(pid)
    GenServer.cast(pid, :refresh)
    :sys.get_state(pid)
    stop_supervised!(Monitor)
    monitor(opts)
    refute_received {:published, _, _, _, _}
    refute_received {:capabilities_changed, _}
  end

  test "default publisher delivers the revision on the system topic", %{opts: opts} do
    :ok = Aiur.Events.Exchange.subscribe("system.capabilities.changed")
    monitor(Keyword.delete(opts, :publish_fun))
    boot_id = Aiur.Boot.run_id()
    assert_received {:event, %{"revision" => 1, "boot_id" => ^boot_id, topic: "system.capabilities.changed"}}
  end

  test "publisher errors and exits preserve revisions and local notifications and log each failure once", %{opts: opts} do
    owner = self()

    for failure <- [{:error, :unavailable}, :exit] do
      publish = fn _, _, _ ->
        send(owner, :attempted)
        if failure == :exit, do: exit(:publisher_down), else: failure
      end

      log =
        capture_log(fn ->
          pid = monitor(Keyword.put(opts, :publish_fun, publish))
          initial = Capabilities.report(opts).revision

          for {state, offset} <- [{:unavailable, 1}, {:available, 2}] do
            Agent.update(Provider, fn _ -> state end)
            tick(pid)
            assert Capabilities.report(opts).revision == initial + offset
            assert Capabilities.report(opts).capabilities["test.notifications"].state == state
            assert Process.alive?(pid)
            assert_received :attempted
            assert_received {:capabilities_changed, _}
          end

          stop_supervised!(Monitor)
        end)

      assert length(Regex.scan(~r/capability_registry.*publish_failed/, log)) == 1
    end
  end

  test "future regression guard: capability notifications never match default Executor wake bindings" do
    for {pattern, _route} <- Aiur.ExecutorBindings.defaults() do
      refute Aiur.Events.Topic.matches?(pattern, "system.capabilities.changed"), pattern
    end
  end

  defp monitor(opts) do
    pid = start_supervised!({Monitor, opts})
    :sys.get_state(pid)
    pid
  end

  defp tick(pid) do
    send(pid, :tick)
    :sys.get_state(pid)
  end

  defp assert_notification(revision) do
    boot_id = Aiur.Boot.run_id()
    assert_received {:published, "system.capabilities.changed", payload, [], ^revision}
    assert payload == %{"revision" => revision, "boot_id" => boot_id}
    assert_received {:capabilities_changed, ^revision}
  end
end
