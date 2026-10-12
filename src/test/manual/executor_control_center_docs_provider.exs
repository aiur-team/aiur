Code.require_file("executor_control_center_docs_meter_source.exs", __DIR__)

defmodule Aiur.Docs.ControlCenterFixture.Provider do
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))

  @impl true
  def init(opts), do: {:ok, Map.new(opts)}

  @impl true
  def handle_call(:snapshot, _from, %{snapshot: snapshot} = state), do: {:reply, snapshot, state}
  def handle_call(:snapshots, _from, state), do: {:reply, state.metrics, state}

  # Mirror Aiur.Orchestrator.GlobalPause's control API. Without these clauses the
  # provider FunctionClauseErrors on the first tap of the nav pause toggle, and
  # because `start_provider/2` links it to the script process, that crash takes
  # the whole fixture server down.
  def handle_call(:globally_paused?, _from, state) do
    {:reply, globally_paused?(state), state}
  end

  def handle_call({:set_global_pause, on?}, _from, state) when is_boolean(on?) do
    # The real switch holds every running agent that is not already individually
    # paused, so the synthetic fleet mirrors that: running rows gain a
    # `:global_pause` reason on pause and shed exactly that reason on resume.
    snapshot =
      state
      |> Map.fetch!(:snapshot)
      |> Map.put(:globally_paused, on?)
      |> Map.update(:running, [], fn running -> Enum.map(running, &apply_global_pause(&1, on?)) end)

    {:reply, {:ok, %{globally_paused: on?}}, %{state | snapshot: snapshot}}
  end

  def handle_call({:recent_decisions, limit}, _from, state) do
    {:reply, Enum.take(state.decisions, limit), state}
  end

  def handle_call({:recent_audit_history, limit}, _from, state) do
    {:reply, %{records: Enum.take(state.history, limit), contexts: %{}, revisions: %{}}, state}
  end

  # Per-decision latency lookup (Aiur.DecisionMetrics.snapshot/2).
  def handle_call({:snapshot, decision_id}, _from, %{metrics: metrics} = state) when is_binary(decision_id) do
    reply =
      case Map.fetch(metrics, decision_id) do
        {:ok, sample} -> {:ok, sample}
        :error -> {:error, :not_found}
      end

    {:reply, reply, state}
  end

  # Mirror Aiur.DecisionStore's :retained_counts reply so the dashboard's
  # PayloadLoader can render the overview counts. Derived from the synthetic
  # decisions this provider holds.
  def handle_call(:retained_counts, _from, %{decisions: decisions} = state) do
    {:reply, {:ok, %{counts: counts(decisions), health: :writable}}, state}
  end

  # Mirror Aiur.DecisionStore's {:retained_query, query} paged reply, including
  # the lifecycle filter and cursor paging the Commands view relies on. A
  # fixture that returns every decision for every query cannot show whether
  # pagination works.
  def handle_call({:retained_query, query}, _from, %{decisions: decisions} = state) do
    limit = Map.get(query, :limit, 25)

    matching =
      decisions
      |> Enum.filter(&lifecycle_match?(&1, Map.get(query, :lifecycle)))
      |> Enum.sort_by(& &1.created_at, {:desc, DateTime})

    after_cursor =
      case Map.get(query, :cursor) do
        %{decision_id: decision_id} -> Enum.drop_while(matching, &(&1.decision_id != decision_id)) |> Enum.drop(1)
        _no_cursor -> matching
      end

    page = Enum.take(after_cursor, limit)
    has_next? = length(after_cursor) > limit

    next_key =
      if has_next? do
        last = List.last(page)
        {-DateTime.to_unix(last.created_at, :microsecond), last.decision_id}
      end

    snapshot = %{
      decisions: page,
      next_key: next_key,
      has_next?: has_next?,
      total: length(matching),
      partial?: false,
      partial_reason: nil,
      counts: counts(decisions),
      health: :writable
    }

    {:reply, {:ok, snapshot}, state}
  end

  # Mirror Aiur.DecisionStore's answer and defer so the two actions that move a
  # Command out of the inbox can be exercised against synthetic data. Without
  # them the fixture rejects every write, and the card correctly refuses to
  # move — which looks like a dismissal bug rather than a missing fixture.
  def handle_call({:answer, decision_id, payload, _opts}, _from, %{decisions: decisions} = state) do
    with %{decision_status: status} = decision when status in [:open, :deferred] <-
           Enum.find(decisions, &(&1.decision_id == decision_id)),
         {:ok, answer} <-
           Aiur.DecisionAnswer.normalize(payload,
             decision_id: decision_id,
             decision_version: decision.version,
             options: decision.options,
             actor: %{kind: :operator, id: "example-operator"},
             now: DateTime.utc_now()
           ) do
      updated = %{decision | answer: answer, active_action_id: answer.action_id, decision_status: :decided}
      {:reply, {:ok, %{status: :accepted, decision: updated}}, replace(state, updated)}
    else
      nil -> {:reply, {:error, :not_found}, state}
      %{decision_status: status} -> {:reply, {:error, {:conflict, status}}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:defer, decision_id, _opts}, _from, %{decisions: decisions} = state) do
    case Enum.find(decisions, &(&1.decision_id == decision_id)) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %{decision_status: :deferred} = decision ->
        {:reply, {:ok, %{status: :duplicate, decision: decision}}, state}

      %{decision_status: :open} = decision ->
        updated = %{decision | decision_status: :deferred}
        {:reply, {:ok, %{status: :accepted, decision: updated}}, replace(state, updated)}

      %{decision_status: status} ->
        {:reply, {:error, {:conflict, status}}, state}
    end
  end

  # Mirror Aiur.DecisionStore's dismiss so the Commands view's Dismiss button
  # works against synthetic data instead of killing the provider.
  def handle_call({:dismiss, decision_id, _opts}, _from, %{decisions: decisions} = state) do
    case Enum.find(decisions, &(&1.decision_id == decision_id)) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %{decision_status: :dismissed} = decision ->
        {:reply, {:ok, %{status: :duplicate, decision: decision}}, state}

      %{decision_status: :open} = decision ->
        updated = %{decision | decision_status: :dismissed}
        decisions = Enum.map(decisions, &if(&1.decision_id == decision_id, do: updated, else: &1))
        {:reply, {:ok, %{status: :accepted, decision: updated}}, %{state | decisions: decisions}}

      %{decision_status: status} ->
        {:reply, {:error, {:conflict, status}}, state}
    end
  end

  # Every provider here is `start_link`ed from the run process, so ANY unmatched
  # call takes the whole fixture down — that is how a single dashboard button
  # killed the server twice. Fail the one call instead of the process; the
  # dashboard already degrades on an error reply. Keep adding real clauses
  # above as the control surface grows, but never let drift be fatal again.
  def handle_call(request, _from, state) do
    IO.warn("docs fixture has no clause for #{inspect(request)} — returning an error reply")
    {:reply, {:error, :unsupported_in_docs_fixture}, state}
  end

  defp replace(%{decisions: decisions} = state, updated) do
    %{state | decisions: Enum.map(decisions, &if(&1.decision_id == updated.decision_id, do: updated, else: &1))}
  end

  @open_statuses [:open, :deferred]
  @historic_statuses [:expired, :dismissed, :decided, :acknowledged, :resolved]
  @history_statuses [:deferred | @historic_statuses]

  defp counts(decisions) do
    open = Enum.count(decisions, &(&1.decision_status in @open_statuses))
    blocking = Enum.count(decisions, &(&1.decision_status in @open_statuses and &1.blocking))
    deferred = Enum.count(decisions, &(&1.decision_status == :deferred))
    deferred_blocking = Enum.count(decisions, &(&1.decision_status == :deferred and &1.blocking))

    %{
      open: open,
      blocking: blocking,
      deferred: deferred,
      awaiting: open - deferred,
      awaiting_blocking: blocking - deferred_blocking,
      total: length(decisions)
    }
  end

  defp lifecycle_match?(_decision, nil), do: true
  defp lifecycle_match?(decision, :open), do: decision.decision_status in @open_statuses
  defp lifecycle_match?(decision, :awaiting), do: decision.decision_status == :open
  defp lifecycle_match?(decision, :historic), do: decision.decision_status in @historic_statuses
  defp lifecycle_match?(decision, :history), do: decision.decision_status in @history_statuses
  defp lifecycle_match?(decision, lifecycle), do: decision.decision_status == lifecycle

  defp globally_paused?(state) do
    state |> Map.get(:snapshot, %{}) |> Map.get(:globally_paused, false) == true
  end

  defp apply_global_pause(agent, true) do
    if Map.get(agent, :pause_reason) do
      agent
    else
      Map.merge(agent, %{pause_reason: :global_pause, waiting_reason: :run_paused, work_state: :paused})
    end
  end

  defp apply_global_pause(%{pause_reason: :global_pause} = agent, false) do
    Map.merge(agent, %{pause_reason: nil, waiting_reason: :active, work_state: :working})
  end

  defp apply_global_pause(agent, false), do: agent
end
