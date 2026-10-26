defmodule AiurWeb.DashboardLiveSupport.StoreStubs do
  @moduledoc false

  defmodule DecisionStoreStub do
    @moduledoc """
    Shared retained-store replies for the dashboard stubs.

    The dashboard reads canonical counts and one retained page per route, so a
    stub that answers neither is not a stand-in for the store — it is a store
    that crashes on contact.
    """

    def counts(decision) do
      open = flag(decision.decision_status == :open)
      deferred = flag(decision.decision_status == :deferred)
      blocking = flag(Map.get(decision, :blocking, false))

      %{
        total: 1,
        open: open + deferred,
        blocking: (open + deferred) * blocking,
        deferred: deferred,
        awaiting: open,
        awaiting_blocking: open * blocking
      }
    end

    defp flag(true), do: 1
    defp flag(_false), do: 0

    def empty_query do
      %{
        decisions: [],
        next_key: nil,
        has_next?: false,
        total: 0,
        partial?: false,
        partial_reason: nil,
        counts: %{total: 0, open: 0, blocking: 0, deferred: 0, awaiting: 0, awaiting_blocking: 0},
        health: :writable
      }
    end
  end

  defmodule CountingDetailStore do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
    end

    def retained_lookup_count(server), do: GenServer.call(server, :retained_lookup_count)

    @impl true
    def init(opts) do
      {:ok, %{store: Keyword.fetch!(opts, :store), retained_lookup_count: 0}}
    end

    @impl true
    def handle_call(:retained_lookup_count, _from, state) do
      {:reply, state.retained_lookup_count, state}
    end

    def handle_call({:retained_lookup, _decision_id} = request, _from, state) do
      reply = GenServer.call(state.store, request)
      {:reply, reply, %{state | retained_lookup_count: state.retained_lookup_count + 1}}
    end

    def handle_call(request, _from, state) do
      {:reply, GenServer.call(state.store, request), state}
    end
  end

  defmodule StaleCountsStore do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
    end

    @impl true
    def init(opts), do: {:ok, %{store: Keyword.fetch!(opts, :store)}}

    @impl true
    def handle_call(:retained_counts, _from, state) do
      counts = %{total: 0, open: 0, blocking: 0, deferred: 0, awaiting: 0, awaiting_blocking: 0}
      {:reply, {:ok, %{counts: counts, health: :writable}}, state}
    end

    def handle_call(request, _from, state) do
      {:reply, GenServer.call(state.store, request), state}
    end
  end

  defmodule AvailabilityStore do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
    end

    def set_available(server, available?) do
      GenServer.call(server, {:set_available, available?})
    end

    @impl true
    def init(opts), do: {:ok, %{store: Keyword.fetch!(opts, :store), available?: true}}

    @impl true
    def handle_call({:set_available, available?}, _from, state) do
      {:reply, :ok, %{state | available?: available?}}
    end

    def handle_call(_request, _from, %{available?: false} = state) do
      {:reply, {:error, :store_unavailable}, state}
    end

    def handle_call(request, _from, state) do
      {:reply, GenServer.call(state.store, request), state}
    end
  end

  defmodule VersionedDetailStore do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
    end

    @impl true
    def init(opts) do
      {:ok,
       %{
         overview: Keyword.fetch!(opts, :overview),
         detail: Keyword.fetch!(opts, :detail),
         report: Keyword.fetch!(opts, :report)
       }}
    end

    @impl true
    def handle_call({:recent_decisions, _limit}, _from, state), do: {:reply, [state.overview], state}

    def handle_call({:retained_lookup, decision_id}, _from, %{detail: %{decision_id: decision_id} = detail} = state) do
      {:reply, {:ok, %{decision: detail, health: :writable}}, state}
    end

    def handle_call({:retained_lookup, _decision_id}, _from, state) do
      {:reply, {:ok, %{decision: nil, health: :writable}}, state}
    end

    def handle_call({:replace_detail, detail}, _from, state) do
      {:reply, :ok, %{state | detail: detail}}
    end

    def handle_call(:retained_counts, _from, state) do
      {:reply, {:ok, %{counts: DecisionStoreStub.counts(state.detail), health: :writable}}, state}
    end

    def handle_call({:retained_query, _query}, _from, state) do
      {:reply, {:ok, DecisionStoreStub.empty_query()}, state}
    end

    def handle_call({:answer, decision_id, payload, opts}, _from, state) do
      send(state.report, {:versioned_detail_answer, decision_id, payload, opts})
      {:reply, {:ok, %{status: :accepted}}, state}
    end

    def handle_call({:revise, decision_id, payload, opts}, _from, state) do
      send(state.report, {:versioned_detail_revision, decision_id, payload, opts})
      {:reply, {:ok, %{status: :accepted}}, state}
    end
  end

  defmodule StaleDetailStore do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
    end

    @impl true
    def init(opts) do
      {:ok,
       %{
         overview: Keyword.fetch!(opts, :overview),
         detail_status: Keyword.fetch!(opts, :detail_status),
         report: Keyword.fetch!(opts, :report)
       }}
    end

    @impl true
    def handle_call({:recent_decisions, _limit}, _from, state), do: {:reply, [state.overview], state}

    def handle_call({:set_detail_status, detail_status}, _from, state) do
      {:reply, :ok, %{state | detail_status: detail_status}}
    end

    def handle_call({:retained_lookup, _decision_id}, _from, %{detail_status: :unavailable} = state) do
      {:reply, {:error, :store_unavailable}, state}
    end

    def handle_call({:retained_lookup, _decision_id}, _from, %{detail_status: :indeterminate} = state) do
      {:reply, {:ok, %{decision: nil, health: {:corrupt, 1, :test_partial}}}, state}
    end

    def handle_call({:recent_audit_history, _limit}, _from, state) do
      {:reply, %{records: [], contexts: %{}, revisions: %{}}, state}
    end

    def handle_call(:retained_counts, _from, state) do
      counts = %{total: 1, open: 1, blocking: true, deferred: 0, awaiting: 1, awaiting_blocking: true}
      {:reply, {:ok, %{counts: counts, health: :writable}}, state}
    end

    def handle_call({:retained_query, _query}, _from, state) do
      {:reply, {:ok, DecisionStoreStub.empty_query()}, state}
    end

    def handle_call({:answer, decision_id, payload, opts}, _from, state) do
      send(state.report, {:stale_detail_answer, decision_id, payload, opts})
      {:reply, {:ok, %{status: :accepted}}, state}
    end

    def handle_call({:revise, decision_id, payload, opts}, _from, state) do
      send(state.report, {:stale_detail_revision, decision_id, payload, opts})
      {:reply, {:ok, %{status: :accepted}}, state}
    end

    def handle_call(_request, _from, state), do: {:reply, {:error, :store_unavailable}, state}
  end

  defmodule RejectingDecisionStore do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
    end

    @impl true
    def init(opts) do
      {:ok, %{decision: Keyword.fetch!(opts, :decision), report: Keyword.fetch!(opts, :report)}}
    end

    @impl true
    def handle_call(:health, _from, state), do: {:reply, :writable, state}
    def handle_call({:get, decision_id}, _from, %{decision: %{decision_id: decision_id} = decision} = state), do: {:reply, {:ok, decision}, state}
    def handle_call({:get, _decision_id}, _from, state), do: {:reply, {:error, :not_found}, state}

    def handle_call(
          {:retained_lookup, decision_id},
          _from,
          %{decision: %{decision_id: decision_id} = decision} = state
        ),
        do: {:reply, {:ok, %{decision: decision, health: :writable}}, state}

    def handle_call({:retained_lookup, _decision_id}, _from, state),
      do: {:reply, {:ok, %{decision: nil, health: :writable}}, state}

    def handle_call(:list, _from, state), do: {:reply, [state.decision], state}
    def handle_call({:recent_decisions, _limit}, _from, state), do: {:reply, [state.decision], state}
    def handle_call(:all_history, _from, state), do: {:reply, %{state.decision.decision_id => [state.decision]}, state}

    def handle_call(:all_audit_history, _from, state) do
      {:reply, %{state.decision.decision_id => [state.decision]}, state}
    end

    def handle_call(:retained_counts, _from, state) do
      {:reply, retained_counts(state.decision), state}
    end

    def handle_call({:retained_query, _query}, _from, state) do
      {:reply, {:ok, DecisionStoreStub.empty_query()}, state}
    end

    def handle_call({:recent_audit_history, _limit}, _from, state) do
      {:reply, %{records: [state.decision], contexts: %{}, revisions: %{}}, state}
    end

    def handle_call({:answer, decision_id, payload, opts}, _from, state) do
      send(state.report, {:dashboard_answer_attempt, decision_id, payload, opts})
      {:reply, {:error, {:conflict, {:stale_version, 1, 2}}}, state}
    end

    defp retained_counts(decision) do
      {:ok, %{counts: DecisionStoreStub.counts(decision), health: :writable}}
    end
  end

  defmodule RejectingRevisionStore do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
    end

    @impl true
    def init(opts) do
      {:ok, %{decision: Keyword.fetch!(opts, :decision), report: Keyword.fetch!(opts, :report)}}
    end

    @impl true
    def handle_call(:health, _from, state), do: {:reply, :writable, state}
    def handle_call({:get, decision_id}, _from, %{decision: %{decision_id: decision_id} = decision} = state), do: {:reply, {:ok, decision}, state}
    def handle_call({:get, _decision_id}, _from, state), do: {:reply, {:error, :not_found}, state}

    def handle_call(
          {:retained_lookup, decision_id},
          _from,
          %{decision: %{decision_id: decision_id} = decision} = state
        ),
        do: {:reply, {:ok, %{decision: decision, health: :writable}}, state}

    def handle_call({:retained_lookup, _decision_id}, _from, state),
      do: {:reply, {:ok, %{decision: nil, health: :writable}}, state}

    def handle_call(:list, _from, state), do: {:reply, [state.decision], state}
    def handle_call({:recent_decisions, _limit}, _from, state), do: {:reply, [state.decision], state}
    def handle_call(:all_history, _from, state), do: {:reply, %{state.decision.decision_id => [state.decision]}, state}

    def handle_call(:all_audit_history, _from, state) do
      {:reply, %{state.decision.decision_id => [state.decision]}, state}
    end

    def handle_call(:retained_counts, _from, state) do
      {:reply, retained_counts(state.decision), state}
    end

    def handle_call({:retained_query, _query}, _from, state) do
      {:reply, {:ok, DecisionStoreStub.empty_query()}, state}
    end

    def handle_call({:recent_audit_history, _limit}, _from, state) do
      {:reply, %{records: [state.decision], contexts: %{}, revisions: %{}}, state}
    end

    def handle_call({:revise, decision_id, payload, opts}, _from, state) do
      send(state.report, {:dashboard_revision_attempt, decision_id, payload, opts})
      {:reply, {:error, {:conflict, {:stale_action, "new-active-action"}}}, state}
    end

    defp retained_counts(decision) do
      {:ok, %{counts: DecisionStoreStub.counts(decision), health: :writable}}
    end
  end
end
