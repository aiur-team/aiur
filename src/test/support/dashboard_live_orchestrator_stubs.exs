defmodule AiurWeb.DashboardLiveSupport.OrchestratorStubs do
  @moduledoc false

  alias Aiur.Orchestrator.SnapshotStore

  defmodule CountingOrchestrator do
    use GenServer

    alias Aiur.Orchestrator.SnapshotStore

    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
    end

    def snapshot_count(server), do: GenServer.call(server, :snapshot_count)

    @impl true
    def init(opts) do
      snapshot = Keyword.fetch!(opts, :snapshot)

      if Keyword.get(opts, :publish?, true) do
        :ok = SnapshotStore.publish(Keyword.fetch!(opts, :name), snapshot)
      end

      {:ok, %{snapshot: snapshot, snapshot_count: 0, report: Keyword.get(opts, :report), block_queued_demand?: Keyword.get(opts, :block_queued_demand?, false)}}
    end

    @impl true
    def handle_call(:snapshot, _from, state) do
      snapshot_count = state.snapshot_count + 1
      if is_pid(state.report), do: send(state.report, {:dashboard_payload_loaded, self(), snapshot_count})
      {:reply, state.snapshot, %{state | snapshot_count: snapshot_count}}
    end

    def handle_call(:snapshot_count, _from, state) do
      {:reply, state.snapshot_count, state}
    end

    def handle_call({:note_queued_demand, identifiers}, _from, state) do
      if is_pid(state.report), do: send(state.report, {:queued_demand_received, self(), identifiers})

      if state.block_queued_demand? do
        receive do
          :release_queued_demand -> :ok
        end
      end

      {:reply, %{coalesced: false}, state}
    end

    def handle_call(:request_refresh, _from, state) do
      if is_pid(state.report), do: send(state.report, {:dashboard_refresh_requested, self()})
      {:reply, %{coalesced: false}, state}
    end
  end

  defmodule GlobalPauseFailureOrchestrator do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
    end

    @impl true
    def init(opts) do
      state = %{report: Keyword.fetch!(opts, :report)}
      {:reply, snapshot, state} = handle_call(:snapshot, nil, state)
      :ok = SnapshotStore.publish(Keyword.fetch!(opts, :name), snapshot)
      {:ok, state}
    end

    @impl true
    def handle_call(:snapshot, _from, state) do
      {:reply,
       %{
         running: [],
         retrying: [],
         idle: [],
         agent_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
         capacity: nil,
         globally_paused: false,
         global_pause: %{globally_paused: false, paused_at: nil, source: nil},
         rate_limits: nil,
         polling: %{checking?: false, next_poll_in_ms: nil, poll_interval_ms: nil}
       }, state}
    end

    def handle_call({:set_global_pause, on?, source}, _from, state) do
      send(state.report, {:global_pause_attempt, on?, source})
      {:reply, {:error, {:global_pause_persistence_failed, :disk_full}}, state}
    end
  end

  defmodule ProviderMeterSourceStub do
    @moduledoc false

    def load(context) do
      report(:load, context)
      config(:snapshots, %{codex: nil, claude: nil})
    end

    def reload(context, message) do
      report(:reload, {context, message})
      config(:reload_snapshots, config(:snapshots, %{codex: nil, claude: nil}))
    end

    def subscribe(context) do
      report(:subscribe, context)
      :ok
    end

    defp report(call, arg) do
      case config(:pid, nil) do
        pid when is_pid(pid) -> send(pid, {:provider_meter_source, call, arg})
        _other -> :ok
      end
    end

    defp config(key, default), do: Map.get(Application.get_env(:aiur, :provider_meter_source_stub, %{}), key, default)
  end

  defmodule QueueOrchestrator do
    use GenServer

    alias Aiur.Orchestrator.{GlobalPause, OperatorMessages, StatusReport}

    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
    end

    @impl true
    def init(opts), do: {:ok, Keyword.fetch!(opts, :state)}

    @impl true
    def handle_call(:snapshot, _from, state), do: StatusReport.snapshot(state)

    def handle_call(:global_pause_status, _from, state), do: {:reply, {:ok, GlobalPause.global_pause_status(state)}, state}

    def handle_call({:send_correlated_operator_message, issue_identifier, payload}, _from, state) do
      OperatorMessages.send_correlated_operator_message_call(state, issue_identifier, payload)
    end

    def handle_call({:send_operator_message, issue_identifier, payload}, _from, state) do
      OperatorMessages.send_operator_message_call(state, issue_identifier, payload)
    end

    def handle_call({:claim_next_queue_item, issue_identifier}, _from, state) do
      OperatorMessages.claim_next_queue_item_call(state, issue_identifier)
    end

    def handle_call({:claim_next_checkpoint_queue_item, issue_identifier}, _from, state) do
      OperatorMessages.claim_next_checkpoint_queue_item_call(state, issue_identifier)
    end
  end
end
