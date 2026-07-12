defmodule Aiur.DecisionStore do
  @moduledoc """
  The single public Decision application service and serialized writer.

  Every accepted mutation follows persist-before-notify: validate,
  compare against the current in-memory index, reserve a durably
  persisted event ID, append + fsync the canonical audit record,
  atomically replace the current-state projection, and only then
  publish to `Aiur.Events.Exchange` and broadcast on `Aiur.PubSub`. A
  request is rejected outright (no audit append, no notification) if
  validation fails or the durable ID reservation itself fails.

  On boot, replays the canonical audit stream, rebuilds the current
  projection, and repairs `decisions.json` if it doesn't already match.
  Interior corruption puts the store into a read-only mode: existing
  reads keep serving the validated prefix, every mutation is rejected,
  and one operator alert is emitted — never silently skipped.

  Version/dedup rules for a request against `decision_id`'s current
  state:

    * no current record — accepted only as version 1.
    * same version + same content hash — duplicate (returns the
      existing record; no append, no new notification).
    * same version + different content hash — idempotency conflict.
    * exactly `current version + 1` — accepted as the next version.
    * lower than current — stale.
    * anything else higher — a version gap.
  """

  use GenServer

  require Logger

  alias Aiur.{Alerts, Boot, Config, Decision, DecisionAnswer, DecisionDispatch, DecisionEvent, DecisionLog, DecisionProjection, DecisionPubSub, DecisionValidation, JsonStore}
  alias Aiur.Events.{IdGenerator, Publisher}

  @ndjson_filename "decisions.ndjson"
  @projection_filename "decisions.json"
  @request_timeout 60_000
  @default_dispatch_delay_ms 0
  @default_reconcile_delay_ms 250
  @default_retry_delays_ms [250, 1_000, 5_000]
  @transient_failure_classes ["orchestrator_unavailable", "orchestrator_timeout"]

  @type accept_result :: %{status: :accepted | :duplicate, decision: Decision.t()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Submits a `decision.requested` payload. `opts` carries the trusted
  `:ticket`/`:source` context (see `Aiur.DecisionValidation.normalize/2`);
  an optional `"version"`/`:version` key in `payload` states which
  version this request targets (defaults to `1`, i.e. a fresh Decision).
  """
  @spec request(map(), keyword(), GenServer.server(), timeout()) :: {:ok, accept_result()} | {:error, term()}
  def request(payload, opts \\ [], server \\ __MODULE__, timeout \\ @request_timeout)
      when is_map(payload) and is_list(opts) do
    GenServer.call(server, {:request, payload, opts}, timeout)
  end

  @doc """
  Durably accepts one operator answer before scheduling its correlated
  delivery. `opts[:actor]` is trusted runtime identity; actor fields in the
  payload are ignored.
  """
  @spec answer(String.t(), map(), keyword(), GenServer.server(), timeout()) ::
          {:ok, map()} | {:error, term()}
  def answer(decision_id, payload, opts \\ [], server \\ __MODULE__, timeout \\ @request_timeout)
      when is_binary(decision_id) and is_map(payload) and is_list(opts) do
    GenServer.call(server, {:answer, decision_id, payload, opts}, timeout)
  end

  @doc "Explicitly schedules a previously failed action for one idempotent retry."
  @spec retry_dispatch(String.t(), String.t(), GenServer.server()) ::
          {:ok, :scheduled | :already_dispatching} | {:error, term()}
  def retry_dispatch(decision_id, action_id, server \\ __MODULE__)
      when is_binary(decision_id) and is_binary(action_id) do
    GenServer.call(server, {:retry_dispatch, decision_id, action_id})
  end

  @spec get(String.t(), GenServer.server()) :: {:ok, Decision.t()} | {:error, :not_found}
  def get(decision_id, server \\ __MODULE__) when is_binary(decision_id) do
    GenServer.call(server, {:get, decision_id})
  end

  @spec list(GenServer.server()) :: [Decision.t()]
  def list(server \\ __MODULE__) do
    GenServer.call(server, :list)
  end

  @spec history(String.t(), GenServer.server()) :: {:ok, [Decision.t()]} | {:error, :not_found}
  def history(decision_id, server \\ __MODULE__) when is_binary(decision_id) do
    GenServer.call(server, {:history, decision_id})
  end

  @doc "Complete ordered audit history, including request and lifecycle events."
  @spec audit_history(String.t(), GenServer.server()) ::
          {:ok, [Decision.t() | DecisionEvent.t()]} | {:error, :not_found}
  def audit_history(decision_id, server \\ __MODULE__) when is_binary(decision_id) do
    GenServer.call(server, {:audit_history, decision_id})
  end

  @doc "`:writable`, or a reason tuple describing why the store is currently read-only/unavailable."
  @spec health(GenServer.server()) :: :writable | tuple()
  def health(server \\ __MODULE__) do
    GenServer.call(server, :health)
  end

  @impl true
  def init(opts) do
    state =
      case Config.Paths.decision_state_dir() do
        {:ok, dir} -> boot(dir, Keyword.get(opts, :filesystem_sync_fun, &Aiur.Fs.sync_filesystem/0))
        {:error, reason} -> unavailable_state(nil, {:path_unresolved, reason})
      end
      |> configure_dispatch(opts)

    {:ok, state, {:continue, :schedule_reconciliation}}
  end

  defp configure_dispatch(state, opts) do
    Map.merge(state, %{
      dispatcher: Keyword.get(opts, :dispatcher, &DecisionDispatch.dispatch/2),
      dispatch_delay_ms: Keyword.get(opts, :dispatch_delay_ms, @default_dispatch_delay_ms),
      reconcile_delay_ms: Keyword.get(opts, :reconcile_delay_ms, @default_reconcile_delay_ms),
      retry_delays_ms: Keyword.get(opts, :retry_delays_ms, @default_retry_delays_ms),
      dispatching: MapSet.new(),
      retry_counts: %{}
    })
  end

  @impl true
  def handle_continue(:schedule_reconciliation, state) do
    if state.writable? do
      Process.send_after(self(), :reconcile_dispatches, state.reconcile_delay_ms)
    end

    {:noreply, state}
  end

  defp boot(dir, filesystem_sync_fun) do
    ndjson_path = Path.join(dir, @ndjson_filename)
    projection_path = Path.join(dir, @projection_filename)

    case DecisionLog.prepare(dir, ndjson_path, filesystem_sync_fun) do
      :ok -> replay_and_project(ndjson_path, projection_path)
      {:error, reason} -> unavailable_state(ndjson_path, {:directory_unavailable, reason})
    end
  end

  defp replay_and_project(ndjson_path, projection_path) do
    case DecisionLog.replay(ndjson_path, &DecisionProjection.decode_record/1) do
      {:ok, records, corruption} ->
        {%{current: current, history: history, audit_history: audit_history}, transition_corruption} =
          DecisionProjection.reduce_checked(records)

        %{
          ndjson_path: ndjson_path,
          projection_path: projection_path,
          current: current,
          history: history,
          audit_history: audit_history,
          writable?: true,
          health: :writable
        }
        |> repair_projection()
        |> apply_corruption(corruption || transition_corruption)

      {:error, reason} ->
        unavailable_state(ndjson_path, {:replay_failed, reason})
    end
  end

  defp apply_corruption(state, nil), do: state

  defp apply_corruption(state, {:corrupt, line, reason}) do
    Logger.error("aiur_decision_store phase=corruption path=#{state.ndjson_path} line=#{line} reason=#{inspect(reason)}")

    _ =
      Alerts.emit_custom(
        "decision_store.corrupted",
        "DecisionStore audit log corrupt at #{state.ndjson_path} line #{line} (#{inspect(reason)}); store is read-only.",
        needs_attention: true
      )

    %{state | writable?: false, health: {:corrupt, line, reason}}
  end

  defp unavailable_state(ndjson_path, reason) do
    Logger.error("aiur_decision_store phase=unavailable reason=#{inspect(reason)}")

    %{
      ndjson_path: ndjson_path,
      projection_path: nil,
      current: %{},
      history: %{},
      audit_history: %{},
      writable?: false,
      health: {:unavailable, reason}
    }
  end

  defp repair_projection(state) do
    case write_projection(state) do
      :ok ->
        state

      {:error, reason} ->
        Logger.error("aiur_decision_store phase=projection_repair_failed reason=#{inspect(reason)}")

        _ =
          Alerts.emit_custom(
            "decision_store.repair_failed",
            "DecisionStore's decisions.json projection failed to write (#{inspect(reason)}); the audit record stays authoritative, but the store is read-only until repaired.",
            needs_attention: true
          )

        %{state | writable?: false, health: {:repair, reason}}
    end
  end

  defp write_projection(%{projection_path: nil}), do: {:error, :no_projection_path}

  defp write_projection(state) do
    JsonStore.write!(state.projection_path, DecisionProjection.serialize_current(state.current))
    # JsonStore is a shared primitive with no opinion on permissions (other
    # consumers don't need owner-only); Decision content does, so chmod it
    # here rather than widening JsonStore's contract for every caller.
    File.chmod!(state.projection_path, 0o600)
    :ok
  rescue
    error -> {:error, Exception.message(error)}
  end

  @impl true
  def handle_call({:request, _payload, _opts}, _from, %{writable?: false} = state) do
    {:reply, {:error, {:store_unavailable, state.health}}, state}
  end

  def handle_call({:request, payload, opts}, _from, state) do
    handle_request(payload, opts, state)
  end

  def handle_call({:answer, _decision_id, _payload, _opts}, _from, %{writable?: false} = state) do
    {:reply, {:error, {:store_unavailable, state.health}}, state}
  end

  def handle_call({:answer, decision_id, payload, opts}, _from, state) do
    handle_answer(decision_id, payload, opts, state)
  end

  def handle_call({:retry_dispatch, _decision_id, _action_id}, _from, %{writable?: false} = state) do
    {:reply, {:error, {:store_unavailable, state.health}}, state}
  end

  def handle_call({:retry_dispatch, decision_id, action_id}, _from, state) do
    case validate_explicit_retry(state, decision_id, action_id) do
      {:ok, :already_dispatching} ->
        {:reply, {:ok, :already_dispatching}, state}

      {:ok, decision} ->
        schedule_dispatch(decision, true, 0)
        {:reply, {:ok, :scheduled}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:get, decision_id}, _from, state) do
    case Map.fetch(state.current, decision_id) do
      {:ok, decision} -> {:reply, {:ok, decision}, state}
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(:list, _from, state) do
    {:reply, Map.values(state.current), state}
  end

  def handle_call({:history, decision_id}, _from, state) do
    case Map.fetch(state.history, decision_id) do
      {:ok, history} -> {:reply, {:ok, history}, state}
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:audit_history, decision_id}, _from, state) do
    case Map.fetch(state.audit_history, decision_id) do
      {:ok, history} -> {:reply, {:ok, history}, state}
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(:health, _from, state) do
    {:reply, state.health, state}
  end

  defp handle_answer(decision_id, payload, opts, state) do
    with {:ok, decision} <- fetch_decision(state, decision_id),
         :ok <- require_answerable(decision),
         {:ok, actor} <- fetch_actor(opts) do
      case decision.answer do
        nil -> accept_answer(decision, payload, actor, opts, state)
        %DecisionAnswer{} -> replay_answer(decision, payload, actor, opts, state)
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp fetch_decision(state, decision_id) do
    case Map.fetch(state.current, decision_id) do
      {:ok, decision} -> {:ok, decision}
      :error -> {:error, :not_found}
    end
  end

  defp require_answerable(%Decision{decision_status: :resolved}), do: {:error, {:conflict, :resolved}}
  defp require_answerable(%Decision{}), do: :ok

  defp fetch_actor(opts) do
    case Keyword.fetch(opts, :actor) do
      {:ok, actor} when is_map(actor) -> {:ok, actor}
      _other -> {:error, {:answer_invalid, {:actor, :missing}}}
    end
  end

  defp accept_answer(decision, payload, actor, opts, state) do
    case normalize_answer(payload, decision, decision.version, decision.options, actor, opts) do
      {:ok, answer} -> persist_answer(decision, answer, state)
      {:error, reason} -> {:reply, {:error, answer_error(reason)}, state}
    end
  end

  defp replay_answer(decision, payload, actor, opts, state) do
    accepted = decision.answer
    addressed = request_version(state, decision.decision_id, accepted.decision_version) || decision

    case normalize_answer(payload, decision, accepted.decision_version, addressed.options, actor, opts) do
      {:ok, replayed} -> evaluate_answer_replay(decision, accepted, replayed, state)
      {:error, reason} -> {:reply, {:error, answer_error(reason)}, state}
    end
  end

  defp normalize_answer(payload, decision, decision_version, options, actor, opts) do
    DecisionAnswer.normalize(payload,
      decision_id: decision.decision_id,
      decision_version: decision_version,
      options: options,
      actor: actor,
      now: Keyword.get(opts, :now, DateTime.utc_now())
    )
  end

  defp answer_error({:answer_invalid, {:stale_version, expected, current}}),
    do: {:conflict, {:stale_version, expected, current}}

  defp answer_error(reason), do: reason

  defp request_version(state, decision_id, version) do
    state.history
    |> Map.get(decision_id, [])
    |> Enum.find(&(&1.version == version))
  end

  defp evaluate_answer_replay(decision, accepted, replayed, state) do
    cond do
      replayed.action_id == accepted.action_id and replayed.content_hash == accepted.content_hash ->
        next_state = maybe_schedule_after_answer(state, decision, false)

        {:reply,
         {:ok,
          %{
            status: :duplicate,
            decision: decision,
            action: accepted,
            dispatch_status: dispatch_status(decision)
          }}, next_state}

      replayed.action_id == accepted.action_id ->
        {:reply, {:error, {:conflict, {:idempotency_conflict, accepted.action_id}}}, state}

      true ->
        {:reply, {:error, {:conflict, {:already_decided, accepted.action_id}}}, state}
    end
  end

  defp persist_answer(decision, answer, state) do
    case build_and_persist_event(:answer_recorded, decision, answer, answer.accepted_at, state) do
      {:ok, next_state, updated} ->
        next_state = maybe_schedule_after_answer(next_state, updated, false)

        {:reply,
         {:ok,
          %{
            status: :accepted,
            decision: updated,
            action: answer,
            dispatch_status: :dispatch_pending
          }}, next_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp dispatch_status(%Decision{delivery_status: :pending}), do: :dispatch_pending
  defp dispatch_status(%Decision{delivery_status: status}), do: status

  defp handle_request(payload, opts, state) do
    with {:ok, requested_version} <- fetch_requested_version(payload),
         {:ok, decision} <- DecisionValidation.normalize(payload, opts) do
      evaluate_and_apply(decision, requested_version, state)
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp fetch_requested_version(payload) do
    case Map.get(payload, "version", Map.get(payload, :version)) do
      nil -> {:ok, 1}
      version when is_integer(version) and version > 0 -> {:ok, version}
      _other -> {:error, {:version, :invalid_type}}
    end
  end

  defp evaluate_and_apply(decision, requested_version, state) do
    case evaluate(decision, requested_version, state) do
      {:duplicate, existing} -> {:reply, {:ok, %{status: :duplicate, decision: existing}}, state}
      {:reject, reason} -> {:reply, {:error, {:conflict, reason}}, state}
      {:accept, decision} -> accept(decision, state)
    end
  end

  defp evaluate(decision, requested_version, state) do
    case Map.get(state.current, decision.decision_id) do
      nil -> evaluate_fresh(decision, requested_version)
      existing -> evaluate_against_existing(decision, requested_version, existing)
    end
  end

  defp evaluate_fresh(decision, 1), do: {:accept, %{decision | version: 1}}
  defp evaluate_fresh(_decision, requested_version), do: {:reject, {:version_gap, requested_version, nil}}

  defp evaluate_against_existing(decision, requested_version, existing) do
    cond do
      requested_version == existing.version and decision.content_hash == existing.content_hash ->
        {:duplicate, existing}

      requested_version == existing.version ->
        {:reject, {:idempotency_conflict, requested_version}}

      requested_version == existing.version + 1 ->
        {:accept, %{decision | version: requested_version}}

      requested_version < existing.version ->
        {:reject, {:stale_version, requested_version, existing.version}}

      true ->
        {:reject, {:version_gap, requested_version, existing.version}}
    end
  end

  defp accept(decision, state) do
    case IdGenerator.reserve_durable_id() do
      {:ok, event_id} -> persist_and_notify(decision, event_id, state)
      {:error, :not_durable} -> {:reply, {:error, :event_id_not_durable}, state}
    end
  end

  defp persist_and_notify(decision, event_id, state) do
    with {:ok, event} <-
           DecisionEvent.new(:requested, decision.decision_id, decision.version, decision,
             event_id: event_id,
             run_id: Boot.run_id(),
             now: decision.created_at
           ),
         :ok <- DecisionLog.append(state.ndjson_path, DecisionEvent.to_json_safe(event)) do
      current = project_request(state, event)

      new_state =
        %{
          state
          | current: Map.put(state.current, decision.decision_id, current),
            history: Map.update(state.history, decision.decision_id, [decision], &(&1 ++ [decision])),
            audit_history: Map.update(state.audit_history, decision.decision_id, [event], &(&1 ++ [event]))
        }
        |> repair_projection()

      notify(current, event_id)
      {:reply, {:ok, %{status: :accepted, decision: current}}, new_state}
    else
      {:error, reason} -> {:reply, {:error, {:append_failed, reason}}, state}
    end
  end

  defp project_request(state, event) do
    records =
      case Map.get(state.current, event.decision_id) do
        nil -> [event]
        existing -> [existing, event]
      end

    DecisionProjection.reduce(records).current[event.decision_id]
  end

  defp build_and_persist_event(type, decision, data, occurred_at, state) do
    with {:ok, event_id} <- reserve_event_id(),
         {:ok, event} <-
           DecisionEvent.new(type, decision.decision_id, lifecycle_version(decision, data), data,
             event_id: event_id,
             run_id: Boot.run_id(),
             now: occurred_at
           ),
         {:ok, updated} <- validate_transition(decision, event),
         :ok <- DecisionLog.append(state.ndjson_path, DecisionEvent.to_json_safe(event)) do
      next_state =
        %{
          state
          | current: Map.put(state.current, decision.decision_id, updated),
            audit_history: Map.update(state.audit_history, decision.decision_id, [event], &(&1 ++ [event]))
        }
        |> repair_projection()

      if next_state.writable?, do: notify_lifecycle(updated, event)
      {:ok, next_state, updated}
    else
      {:error, :not_durable} -> {:error, :event_id_not_durable}
      {:error, reason} -> {:error, reason}
    end
  end

  defp reserve_event_id, do: IdGenerator.reserve_durable_id()

  defp lifecycle_version(_decision, %DecisionAnswer{decision_version: version}), do: version
  defp lifecycle_version(%Decision{answer: %DecisionAnswer{decision_version: version}}, _data), do: version

  defp validate_transition(decision, event) do
    case DecisionProjection.reduce_checked([decision, event]) do
      {%{current: current}, nil} -> {:ok, current[decision.decision_id]}
      {_projection, {:corrupt, _line, {:invalid_transition, reason}}} -> {:error, {:invalid_transition, reason}}
    end
  end

  defp notify_lifecycle(decision, event) do
    topic = "ticket.#{decision.ticket.identifier}.agent.decision.#{lifecycle_slug(event.type)}"

    try do
      Publisher.publish_persisted(topic, DecisionEvent.to_json_safe(event), event.event_id)
    rescue
      error -> Logger.warning("aiur_decision_store phase=lifecycle_publisher_failed error=#{Exception.message(error)}")
    end

    try do
      DecisionPubSub.broadcast_changed(decision.decision_id, decision.version)
    rescue
      error -> Logger.warning("aiur_decision_store phase=lifecycle_pubsub_failed error=#{Exception.message(error)}")
    end

    :ok
  end

  defp lifecycle_slug(:answer_recorded), do: "answered"
  defp lifecycle_slug(:dispatch_queued), do: "queued"
  defp lifecycle_slug(:delivered), do: "delivered"
  defp lifecycle_slug(:restored), do: "restored"
  defp lifecycle_slug(:consumed), do: "consumed"
  defp lifecycle_slug(:failed), do: "failed"
  defp lifecycle_slug(:acknowledged), do: "acknowledged"
  defp lifecycle_slug(:resolved), do: "resolved"

  @impl true
  def handle_info(:reconcile_dispatches, state) do
    next_state =
      state.current
      |> Map.values()
      |> Enum.reduce(state, &maybe_schedule_after_answer(&2, &1, false))

    {:noreply, next_state}
  end

  def handle_info({:dispatch_action, decision_id, retry_failed?}, state) do
    {:noreply, maybe_start_dispatch(state, decision_id, retry_failed?)}
  end

  def handle_info({:dispatch_result, decision_id, action_id, attempt_id, result}, state) do
    state = %{state | dispatching: MapSet.delete(state.dispatching, action_id)}
    {:noreply, settle_dispatch(state, decision_id, action_id, attempt_id, result)}
  end

  defp maybe_schedule_after_answer(state, %Decision{} = decision, retry_failed?) do
    cond do
      not state.writable? -> state
      not dispatchable?(decision, retry_failed?) -> state
      MapSet.member?(state.dispatching, decision.answer.action_id) -> state

      true ->
        schedule_dispatch(decision, retry_failed?, state.dispatch_delay_ms)
        state
    end
  end

  defp schedule_dispatch(decision, retry_failed?, delay_ms) do
    Process.send_after(self(), {:dispatch_action, decision.decision_id, retry_failed?}, delay_ms)
  end

  defp maybe_start_dispatch(state, decision_id, retry_failed?) do
    with true <- state.writable?,
         {:ok, decision} <- fetch_decision(state, decision_id),
         %DecisionAnswer{} = answer <- decision.answer,
         false <- MapSet.member?(state.dispatching, answer.action_id),
         true <- dispatchable?(decision, retry_failed?) do
      attempt_id = next_attempt_id(decision)
      dispatch_decision = decision_for_dispatch(state, decision)
      store = self()
      dispatcher = state.dispatcher

      task = fn ->
        result = safe_dispatch(dispatcher, dispatch_decision, store, attempt_id, retry_failed?)
        send(store, {:dispatch_result, decision.decision_id, answer.action_id, attempt_id, result})
      end

      case Task.start(task) do
        {:ok, _pid} -> %{state | dispatching: MapSet.put(state.dispatching, answer.action_id)}
        {:error, _reason} ->
          send(self(), {:dispatch_result, decision.decision_id, answer.action_id, attempt_id, {:error, :task_unavailable}})
          %{state | dispatching: MapSet.put(state.dispatching, answer.action_id)}
      end
    else
      _other -> state
    end
  end

  defp safe_dispatch(dispatcher, decision, store, attempt_id, retry_failed?) do
    dispatcher.(decision,
      store: store,
      attempt_id: attempt_id,
      retry_failed: retry_failed?
    )
  rescue
    error ->
      Logger.warning("aiur_decision_store phase=dispatcher_crashed error=#{Exception.message(error)}")
      {:error, :dispatcher_crashed}
  catch
    kind, _reason ->
      Logger.warning("aiur_decision_store phase=dispatcher_crashed kind=#{kind}")
      {:error, :dispatcher_crashed}
  end

  defp settle_dispatch(state, decision_id, action_id, attempt_id, result) do
    with true <- state.writable?,
         {:ok, decision} <- fetch_decision(state, decision_id),
         %DecisionAnswer{action_id: ^action_id} <- decision.answer do
      case result do
        {:ok, %{item: %{id: queue_item_id}}} when is_integer(queue_item_id) and queue_item_id > 0 ->
          settle_queue_acceptance(state, decision, action_id, attempt_id, queue_item_id)

        {:error, reason} ->
          settle_dispatch_failure(state, decision, action_id, attempt_id, reason)

        _other ->
          settle_dispatch_failure(state, decision, action_id, attempt_id, :invalid_dispatch_result)
      end
    else
      _other -> state
    end
  end

  defp settle_queue_acceptance(state, decision, action_id, attempt_id, queue_item_id) do
    data = %{action_id: action_id, attempt_id: attempt_id, queue_item_id: queue_item_id}

    case build_and_persist_event(:dispatch_queued, decision, data, DateTime.utc_now(), state) do
      {:ok, next_state, _updated} -> %{next_state | retry_counts: Map.delete(next_state.retry_counts, action_id)}
      {:error, reason} -> lifecycle_append_failed(state, :dispatch_queued, reason)
    end
  end

  defp settle_dispatch_failure(state, decision, action_id, attempt_id, reason) do
    reason_class = dispatch_failure_class(reason)
    data = %{action_id: action_id, attempt_id: attempt_id, queue_item_id: nil, reason_class: reason_class}

    case build_and_persist_event(:failed, decision, data, DateTime.utc_now(), state) do
      {:ok, next_state, updated} -> maybe_retry_transient(next_state, updated, reason_class)
      {:error, append_reason} -> lifecycle_append_failed(state, :failed, append_reason)
    end
  end

  defp lifecycle_append_failed(state, type, reason) do
    Logger.error("aiur_decision_store phase=lifecycle_append_failed type=#{type} reason=#{inspect(reason)}")
    %{state | writable?: false, health: {:lifecycle_append_failed, type, reason}}
  end

  defp maybe_retry_transient(state, decision, reason_class) when reason_class in @transient_failure_classes do
    action_id = decision.answer.action_id
    retry_count = Map.get(state.retry_counts, action_id, 0)
    next_state = %{state | retry_counts: Map.put(state.retry_counts, action_id, retry_count + 1)}

    case Enum.at(state.retry_delays_ms, retry_count) do
      delay when is_integer(delay) and delay >= 0 ->
        schedule_dispatch(decision, false, delay)
        next_state

      _other ->
        next_state
    end
  end

  defp maybe_retry_transient(state, _decision, _reason_class), do: state

  defp dispatch_failure_class(:unavailable), do: "orchestrator_unavailable"
  defp dispatch_failure_class(:timeout), do: "orchestrator_timeout"
  defp dispatch_failure_class(:no_running_agent), do: "target_agent_unavailable"
  defp dispatch_failure_class(:task_unavailable), do: "dispatch_task_unavailable"
  defp dispatch_failure_class(:dispatcher_crashed), do: "dispatcher_crashed"
  defp dispatch_failure_class(_reason), do: "dispatch_rejected"

  defp next_attempt_id(decision) do
    "#{decision.answer.action_id}:#{length(decision.dispatch_attempts) + 1}"
  end

  defp decision_for_dispatch(state, decision) do
    case request_version(state, decision.decision_id, decision.answer.decision_version) do
      nil ->
        decision

      addressed ->
        %{
          addressed
          | answer: decision.answer,
            decision_status: decision.decision_status,
            delivery_status: decision.delivery_status,
            dispatch_attempts: decision.dispatch_attempts,
            acknowledgement: decision.acknowledgement,
            resolution: decision.resolution
        }
    end
  end

  defp dispatchable?(%Decision{answer: nil}, _retry_failed?), do: false
  defp dispatchable?(%Decision{decision_status: :resolved}, _retry_failed?), do: false
  defp dispatchable?(%Decision{dispatch_attempts: []}, _retry_failed?), do: true

  defp dispatchable?(%Decision{dispatch_attempts: attempts}, true) do
    List.last(attempts).status == :failed
  end

  defp dispatchable?(%Decision{dispatch_attempts: attempts}, false) do
    case List.last(attempts) do
      %{status: :failed, failure_reason_class: reason} when reason in @transient_failure_classes -> true
      _other -> false
    end
  end

  defp validate_explicit_retry(state, decision_id, action_id) do
    with {:ok, decision} <- fetch_decision(state, decision_id),
         %DecisionAnswer{action_id: ^action_id} <- decision.answer,
         :ok <- require_answerable(decision),
         true <- match?(%{status: :failed}, List.last(decision.dispatch_attempts)) do
      if MapSet.member?(state.dispatching, action_id) do
        {:ok, :already_dispatching}
      else
        {:ok, decision}
      end
    else
      nil -> {:error, :answer_missing}
      %DecisionAnswer{} -> {:error, :action_mismatch}
      false -> {:error, :dispatch_not_failed}
      {:error, reason} -> {:error, reason}
    end
  end

  defp notify(decision, event_id) do
    topic = "ticket.#{decision.ticket.identifier}.agent.decision.requested"
    payload = DecisionProjection.to_json_safe(decision)

    try do
      Publisher.publish_persisted(topic, payload, event_id)
    rescue
      error -> Logger.warning("aiur_decision_store phase=notify_publisher_failed error=#{Exception.message(error)}")
    end

    try do
      DecisionPubSub.broadcast_changed(decision.decision_id, decision.version)
    rescue
      error -> Logger.warning("aiur_decision_store phase=notify_pubsub_failed error=#{Exception.message(error)}")
    end

    :ok
  end
end
