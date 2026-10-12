defmodule Aiur.BuildQueue.CapabilityProviderTest do
  use Aiur.TestSupport
  alias Aiur.BuildQueue.{CapabilityProvider, ReadModel, Server}

  defmodule StatusBoundary do
    use GenServer
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Server)
    @impl true
    def init(opts), do: {:ok, opts}
    @impl true
    def handle_call(:status, _from, %{status: :exit}), do: exit(:status_unavailable)

    def handle_call(:status, _from, %{status: :blocked} = state) do
      send(state.owner, :status_read_blocked)

      receive do
        :release -> {:reply, :running, %{state | status: :running}}
      end
    end

    def handle_call(:status, _from, state), do: {:reply, state.status, state}
    def handle_call(:read_model, _from, %{source: :malformed} = state), do: {:reply, %{}, state}
    def handle_call(:read_model, _from, %{source: :unknown} = state), do: {:reply, %{build_queue: %{build_order_source: :unknown}}, state}

    def handle_call(:read_model, _from, state) do
      model = ReadModel.build(%{status: state.status, clock: fn -> 1_000 end, document: nil, projections: [], observations: %{}, build_order_projection: state.source})
      {:reply, model, state}
    end
  end

  for {status, expected} <- [
        running: %{state: :available},
        disabled: %{state: :unavailable, reason: :disabled},
        unsupported_tracker: %{state: :unavailable, reason: :unsupported_tracker},
        store_unavailable: %{state: :unavailable, reason: :store_unavailable},
        writes_paused: %{state: :degraded, reason: :writes_paused},
        weird: %{state: :unknown, reason: :unknown}
      ] do
    test "#{status} reports its exact capability" do
      start_supervised!({StatusBoundary, %{status: unquote(status), source: :absent_queue_projection}})
      capabilities = CapabilityProvider.capabilities(%{})
      assert capabilities["build_queue"] == unquote(Macro.escape(expected))

      if unquote(status) in [:disabled, :unsupported_tracker, :store_unavailable, :weird] do
        assert capabilities["build_queue.build_order_source"] == %{state: :unavailable, reason: :dependency_unavailable, depends_on: ["build_queue"]}
      end
    end
  end

  @tag capture_log: true
  test "an exiting status read reports unknown for both IDs" do
    start_supervised!({StatusBoundary, %{status: :exit}})

    assert CapabilityProvider.capabilities(%{}) == %{
             "build_queue" => %{state: :unknown, reason: :unknown},
             "build_queue.build_order_source" => %{state: :unknown, reason: :unknown}
           }
  end

  for status <- [:running, :writes_paused] do
    test "#{status} reports an available Build Order source" do
      projection = start_supervised!({Agent, fn -> nil end})
      start_supervised!({StatusBoundary, %{status: unquote(status), source: projection}})
      assert CapabilityProvider.capabilities(%{})["build_queue.build_order_source"] == %{state: :available}
    end

    test "#{status} source depends on build_orders when the projection is absent" do
      start_supervised!({StatusBoundary, %{status: unquote(status), source: :absent_queue_projection}})

      assert CapabilityProvider.capabilities(%{})["build_queue.build_order_source"] == %{
               state: :unavailable,
               reason: :dependency_unavailable,
               depends_on: ["build_orders"]
             }
    end
  end

  test "an unknown source flag stays unknown while the queue remains available" do
    start_supervised!({StatusBoundary, %{status: :running, source: :unknown}})
    capabilities = CapabilityProvider.capabilities(%{})
    assert capabilities["build_queue"] == %{state: :available}
    assert capabilities["build_queue.build_order_source"] == %{state: :unknown, reason: :unknown}
  end

  test "a raising facade read reports unknown for both IDs" do
    start_supervised!({StatusBoundary, %{status: :running, source: :malformed}})
    assert CapabilityProvider.capabilities(%{}) == Map.new(CapabilityProvider.capability_ids(), &{&1, %{state: :unknown, reason: :unknown}})
  end

  test "default registry includes both queue capabilities" do
    start_supervised!({StatusBoundary, %{status: :writes_paused, source: :absent_queue_projection}})
    report = Aiur.Capabilities.report(table: :absent_queue_capabilities)
    assert report.capabilities["build_queue"] == %{state: :degraded, reason: :writes_paused}
    assert report.capabilities["build_queue.build_order_source"] == %{state: :unavailable, reason: :dependency_unavailable, depends_on: ["build_orders"]}
  end

  for {enabled, tracker, reason} <- [{false, "memory", :disabled}, {true, "linear", :unsupported_tracker}] do
    test "an absent queue reports #{reason} through the real facade" do
      path = Aiur.Workflow.workflow_file_path()
      write_workflow_file!(path, tracker_kind: unquote(tracker))
      write_workflow_file_atomic!(path, File.read!(path) <> "\nbuild_queue:\n  enabled: #{unquote(enabled)}\n")
      :ok = Aiur.WorkflowStore.force_reload()
      assert Process.whereis(Server) == nil
      capabilities = CapabilityProvider.capabilities(%{})
      assert capabilities["build_queue"] == %{state: :unavailable, reason: unquote(reason)}
      assert capabilities["build_queue.build_order_source"] == %{state: :unavailable, reason: :dependency_unavailable, depends_on: ["build_queue"]}
    end
  end

  test "a stalled queue read becomes unknown within the registry provider budget" do
    server = start_supervised!({StatusBoundary, %{status: :blocked, owner: self(), source: :absent_queue_projection}})

    try do
      report = Aiur.Capabilities.report(table: :absent_queue_capabilities, providers: [CapabilityProvider])
      assert_received :status_read_blocked
      assert report.capabilities["build_queue"] == %{state: :unknown, reason: :unknown}
      assert report.capabilities["build_queue.build_order_source"] == %{state: :unknown, reason: :unknown}
    after
      send(server, :release)
      :sys.get_state(server)
    end
  end
end
