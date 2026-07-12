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

  @doc "Synchronously persist the backend-handoff edge for one correlated queue item."
  @spec record_delivery(map(), GenServer.server()) :: {:ok, :accepted | :duplicate | :ignored} | {:error, term()}
  def record_delivery(item, server \\ __MODULE__) when is_map(item) do
    GenServer.call(server, {:transport_transition, :delivered, item, nil}, @request_timeout)
  catch
    :exit, _reason -> {:error, :store_unavailable}
  end

  @doc "Asynchronously report a later queue settlement without blocking the Orchestrator."
  @spec record_transport_async(:restored | :consumed | :failed, map(), term(), GenServer.server()) :: :ok
  def record_transport_async(type, item, reason \\ nil, server \\ __MODULE__)
      when type in [:restored, :consumed, :failed] and is_map(item) do
    GenServer.cast(server, {:transport_transition, type, item, reason})
  catch
    :exit, _reason -> :ok
  end

  @doc "Durably record an exact target-agent acknowledgement or resolution."
  @spec agent_lifecycle(:acknowledged | :resolved, map(), keyword(), GenServer.server()) ::
          {:ok, map()} | {:error, term()}
  def agent_lifecycle(type, payload, opts, server \\ __MODULE__)
      when type in [:acknowledged, :resolved] and is_map(payload) and is_list(opts) do
    GenServer.call(server, {:agent_lifecycle, type, payload, opts}, @request_timeout)
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
      reproject_failure_attentions(state)
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

  def handle_call({:transport_transition, _type, _item, _reason}, _from, %{writable?: false} = state) do
    {:reply, {:error, {:store_unavailable, state.health}}, state}
  end

  def handle_call({:transport_transition, type, item, reason}, _from, state) do
    {reply, next_state} = apply_transport_transition(state, type, item, reason)
    {:reply, reply, next_state}
  end

  def handle_call({:agent_lifecycle, _type, _payload, _opts}, _from, %{writable?: false} = state) do
    {:reply, {:error, {:store_unavailable, state.health}}, state}
  end

  def handle_call({:agent_lifecycle, type, payload, opts}, _from, state) do
    {reply, next_state} = apply_agent_lifecycle(state, type, payload, opts)
    {:reply, reply, next_state}
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

  @impl true
  def handle_cast({:transport_transition, _type, _item, _reason}, %{writable?: false} = state) do
    {:noreply, state}
  end

  def handle_cast({:transport_transition, type, item, reason}, state) do
    {_reply, next_state} = apply_transport_transition(state, type, item, reason)
    {:noreply, next_state}
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

  defp apply_agent_lifecycle(state, type, payload, opts) do
    with {:ok, context} <- normalize_agent_lifecycle(type, payload, opts),
         {:ok, decision} <- fetch_decision(state, context.decision_id),
         :ok <- validate_agent_lifecycle_target(decision, context),
         {:ok, outcome} <- evaluate_agent_lifecycle(decision, type, context.data) do
      persist_or_replay_agent_lifecycle(state, decision, type, context.data, outcome)
    else
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp normalize_agent_lifecycle(type, payload, opts) do
    decision_id = payload_value(payload, :decision_id)
    action_id = payload_value(payload, :action_id)
    expected_version = payload_value(payload, :expected_version)
    detail = payload_value(payload, :detail)
    ticket_identifier = Keyword.get(opts, :ticket_identifier)
    actor = Keyword.get(opts, :actor)
    source = Keyword.get(opts, :source, %{})

    with true <- (is_binary(decision_id) and decision_id != "") or {:error, :invalid_decision_id},
         true <- (is_binary(ticket_identifier) and ticket_identifier != "") or {:error, :invalid_ticket},
         true <- is_map(actor) or {:error, :invalid_actor},
         {:ok, candidate} <-
           DecisionEvent.new(type, decision_id, expected_version, %{action_id: action_id, actor: actor, source: source, detail: detail},
             event_id: "lifecycle-validation",
             run_id: "lifecycle-validation"
           ),
         true <- candidate.data.actor.kind == :agent or {:error, :invalid_actor} do
      {:ok,
       %{
         decision_id: decision_id,
         expected_version: expected_version,
         ticket_identifier: ticket_identifier,
         data: candidate.data
       }}
    else
      false -> {:error, :invalid_lifecycle_payload}
      {:error, reason} -> {:error, reason}
    end
  end

  defp payload_value(payload, key), do: Map.get(payload, key, Map.get(payload, Atom.to_string(key)))

  defp validate_agent_lifecycle_target(decision, context) do
    cond do
      decision.ticket.identifier != context.ticket_identifier ->
        {:error, {:conflict, {:ticket_mismatch, context.ticket_identifier, decision.ticket.identifier}}}

      is_nil(decision.answer) ->
        {:error, {:invalid_transition, :answer_missing}}

      decision.answer.action_id != context.data.action_id ->
        {:error, {:conflict, {:action_mismatch, context.data.action_id, decision.answer.action_id}}}

      decision.answer.decision_version != context.expected_version ->
        {:error, {:conflict, {:stale_version, context.expected_version, decision.answer.decision_version}}}

      true ->
        :ok
    end
  end

  defp evaluate_agent_lifecycle(decision, :acknowledged, data) do
    case decision.acknowledgement do
      nil -> if delivered_once?(decision), do: {:ok, :accept}, else: {:error, {:invalid_transition, :not_delivered}}
      fact -> compare_lifecycle_replay(fact, data, :already_acknowledged)
    end
  end

  defp evaluate_agent_lifecycle(decision, :resolved, data) do
    cond do
      is_nil(decision.acknowledgement) -> {:error, {:invalid_transition, :not_acknowledged}}
      is_nil(decision.resolution) -> {:ok, :accept}
      true -> compare_lifecycle_replay(decision.resolution, data, :already_resolved)
    end
  end

  defp delivered_once?(decision), do: Enum.any?(decision.dispatch_attempts, &(not is_nil(&1.delivered_at)))

  defp compare_lifecycle_replay(fact, data, conflict) do
    if fact.action_id == data.action_id and fact.actor == data.actor and fact.detail == data.detail do
      {:ok, :duplicate}
    else
      {:error, {:conflict, {conflict, fact.action_id}}}
    end
  end

  defp persist_or_replay_agent_lifecycle(state, decision, type, _data, :duplicate) do
    result = agent_lifecycle_result(:duplicate, decision, type)
    {{:ok, result}, state}
  end

  defp persist_or_replay_agent_lifecycle(state, decision, type, data, :accept) do
    case build_and_persist_event(type, decision, data, DateTime.utc_now(), state) do
      {:ok, next_state, updated} ->
        next_state = project_delivery_attention(next_state, decision, updated, type)
        {{:ok, agent_lifecycle_result(:accepted, updated, type)}, next_state}

      {:error, reason} ->
        {{:error, reason}, state}
    end
  end

  defp agent_lifecycle_result(status, decision, type) do
    %{
      status: status,
      lifecycle: type,
      decision_id: decision.decision_id,
      version: decision.version,
      answered_version: decision.answer.decision_version,
      action_id: decision.answer.action_id,
      decision_status: decision.decision_status
    }
  end

  defp apply_transport_transition(state, type, item, reason) do
    case correlated_transport_context(state, item) do
      {:ok, decision, attempt, context} ->
        persist_transport_transition(state, decision, attempt, context, type, reason)

      {:ok, :ignored} ->
        {{:ok, :ignored}, state}

      {:error, reason} ->
        {{:error, reason}, state}
    end
  end

  defp correlated_transport_context(state, item) do
    correlation = Map.get(item, :correlation)
    action_id = Map.get(item, :action_id)

    if is_map(correlation) and is_binary(action_id) do
      with {:ok, context} <- normalize_transport_context(item, correlation, action_id),
           {:ok, decision} <- fetch_decision(state, context.decision_id),
           :ok <- validate_transport_decision(decision, context),
           {:ok, attempt} <- fetch_dispatch_attempt(decision, context) do
        {:ok, decision, attempt, context}
      end
    else
      {:ok, :ignored}
    end
  end

  defp normalize_transport_context(item, correlation, action_id) do
    context = %{
      decision_id: correlation_value(correlation, :decision_id),
      decision_version: correlation_value(correlation, :decision_version),
      action_id: correlation_value(correlation, :action_id),
      attempt_id: correlation_value(correlation, :attempt_id),
      queue_item_id: Map.get(item, :id),
      target: Map.get(item, :target_issue_identifier)
    }

    cond do
      not is_binary(context.decision_id) -> {:error, :invalid_decision_correlation}
      not (is_integer(context.decision_version) and context.decision_version > 0) -> {:error, :invalid_decision_correlation}
      context.action_id != action_id -> {:error, :action_mismatch}
      not is_binary(context.attempt_id) -> {:error, :invalid_decision_correlation}
      not (is_integer(context.queue_item_id) and context.queue_item_id > 0) -> {:error, :invalid_decision_correlation}
      not is_binary(context.target) -> {:error, :invalid_decision_correlation}
      true -> {:ok, context}
    end
  end

  defp correlation_value(correlation, key),
    do: Map.get(correlation, key, Map.get(correlation, Atom.to_string(key)))

  defp validate_transport_decision(decision, context) do
    cond do
      decision.ticket.identifier != context.target -> {:error, :ticket_mismatch}
      is_nil(decision.answer) -> {:error, :answer_missing}
      decision.answer.action_id != context.action_id -> {:error, :action_mismatch}
      decision.answer.decision_version != context.decision_version -> {:error, :version_mismatch}
      true -> :ok
    end
  end

  defp fetch_dispatch_attempt(decision, context) do
    case Enum.find(decision.dispatch_attempts, &(&1.attempt_id == context.attempt_id)) do
      nil -> {:error, :attempt_not_found}
      %{queue_item_id: queue_item_id} = attempt when queue_item_id == context.queue_item_id -> {:ok, attempt}
      _attempt -> {:error, :queue_item_mismatch}
    end
  end

  defp persist_transport_transition(state, decision, attempt, context, type, reason) do
    reason_class = if type == :failed, do: transport_failure_class(reason)

    if duplicate_transport_transition?(attempt, type, reason_class) do
      {{:ok, :duplicate}, state}
    else
      data = %{
        action_id: context.action_id,
        attempt_id: context.attempt_id,
        queue_item_id: context.queue_item_id,
        reason_class: reason_class
      }

      case build_and_persist_event(type, decision, data, DateTime.utc_now(), state) do
        {:ok, next_state, updated} ->
          next_state = project_delivery_attention(next_state, decision, updated, type)
          {{:ok, :accepted}, next_state}

        {:error, transition_reason} ->
          {{:error, transition_reason}, state}
      end
    end
  end

  defp duplicate_transport_transition?(attempt, :delivered, _reason),
    do: attempt.status in [:delivered, :consumed, :failed] and not is_nil(attempt.delivered_at)

  defp duplicate_transport_transition?(attempt, :restored, _reason),
    do: attempt.status == :queued and not is_nil(attempt.restored_at)

  defp duplicate_transport_transition?(attempt, :consumed, _reason), do: attempt.status == :consumed

  defp duplicate_transport_transition?(attempt, :failed, reason),
    do: attempt.status == :failed and attempt.failure_reason_class == reason

  defp transport_failure_class(:response_timeout), do: "response_timeout"
  defp transport_failure_class(:turn_timeout), do: "turn_timeout"
  defp transport_failure_class(:send_failed), do: "send_failed"
  defp transport_failure_class({:turn_start_failed, _reason}), do: "turn_start_failed"
  defp transport_failure_class({:turn_interrupted, _payload}), do: "turn_interrupted"
  defp transport_failure_class({:turn_cancelled, _payload}), do: "turn_cancelled"
  defp transport_failure_class(_reason), do: "turn_failed"

  defp project_delivery_attention(state, _prior, updated, :failed) do
    emit_failure_attention(updated)
    state
  end

  defp project_delivery_attention(state, prior, updated, type)
       when type in [:dispatch_queued, :restored, :delivered, :acknowledged] do
    if prior.delivery_status == :failed, do: emit_failure_resolution(updated)
    state
  end

  defp project_delivery_attention(state, _prior, _updated, _type), do: state

  defp reproject_failure_attentions(state) do
    state.current
    |> Map.values()
    |> Enum.filter(&(&1.delivery_status == :failed and not is_nil(&1.answer)))
    |> Enum.each(&emit_failure_attention/1)

    :ok
  end

  defp emit_failure_attention(decision) do
    reason_class = decision.dispatch_attempts |> List.last() |> Map.get(:failure_reason_class, "delivery_failed")

    Alerts.emit_custom(
      failure_attention_topic(decision),
      "Decision answer delivery failed for #{decision.decision_id} (#{reason_class}).",
      issue: decision.ticket.identifier,
      reason: "Decision #{decision.decision_id} action #{decision.answer.action_id} remains actionable after #{reason_class}.",
      needs_attention: true,
      severity: "warning"
    )
  end

  defp emit_failure_resolution(decision) do
    Alerts.emit_custom(
      failure_attention_topic(decision) <> ".resolved",
      "Decision answer delivery recovered for #{decision.decision_id}.",
      issue: decision.ticket.identifier,
      reason: "Decision #{decision.decision_id} action #{decision.answer.action_id} delivery recovered.",
      needs_attention: false,
      severity: "info"
    )
  end

  defp failure_attention_topic(decision) do
    action_slug = String.replace(decision.answer.action_id, "_", "-")
    "ticket.#{decision.ticket.identifier}.agent.attention.decision-delivery-#{action_slug}"
  end

  @impl true
  def handle_info(:reconcile_dispatches, state) do
    next_state =
      state.current
      |> Map.values()
      |> Enum.reduce(state, fn decision, state_acc ->
        state_acc
        |> maybe_schedule_after_answer(decision, false)
        |> maybe_schedule_queue_reconciliation(decision)
      end)

    {:noreply, next_state}
  end

  def handle_info({:dispatch_action, decision_id, retry_failed?}, state) do
    {:noreply, maybe_start_dispatch(state, decision_id, retry_failed?)}
  end

  def handle_info({:reconcile_queue_action, decision_id}, state) do
    {:noreply, maybe_start_dispatch(state, decision_id, false, :reconcile_queue)}
  end

  def handle_info({:dispatch_result, decision_id, action_id, attempt_id, result}, state) do
    state = %{state | dispatching: MapSet.delete(state.dispatching, action_id)}
    {:noreply, settle_dispatch(state, decision_id, action_id, attempt_id, result)}
  end

  defp maybe_schedule_after_answer(state, %Decision{} = decision, retry_failed?) do
    cond do
      not state.writable? ->
        state

      not dispatchable?(decision, retry_failed?) ->
        state

      MapSet.member?(state.dispatching, decision.answer.action_id) ->
        state

      true ->
        schedule_dispatch(decision, retry_failed?, state.dispatch_delay_ms)
        state
    end
  end

  defp maybe_schedule_queue_reconciliation(state, %Decision{} = decision) do
    cond do
      not state.writable? ->
        state

      not queue_reconcilable?(decision) ->
        state

      MapSet.member?(state.dispatching, decision.answer.action_id) ->
        state

      true ->
        Process.send_after(self(), {:reconcile_queue_action, decision.decision_id}, 0)
        state
    end
  end

  defp schedule_dispatch(decision, retry_failed?, delay_ms) do
    Process.send_after(self(), {:dispatch_action, decision.decision_id, retry_failed?}, delay_ms)
  end

  defp maybe_start_dispatch(state, decision_id, retry_failed?, mode \\ :normal) do
    with true <- state.writable?,
         {:ok, decision} <- fetch_decision(state, decision_id),
         %DecisionAnswer{} = answer <- decision.answer,
         false <- MapSet.member?(state.dispatching, answer.action_id),
         true <- dispatch_allowed?(decision, retry_failed?, mode) do
      attempt_id = next_attempt_id(decision)
      dispatch_decision = decision_for_dispatch(state, decision)
      store = self()
      dispatcher = state.dispatcher

      task = fn ->
        result = safe_dispatch(dispatcher, dispatch_decision, store, attempt_id, retry_failed?)
        send(store, {:dispatch_result, decision.decision_id, answer.action_id, attempt_id, result})
      end

      case Task.start(task) do
        {:ok, _pid} ->
          %{state | dispatching: MapSet.put(state.dispatching, answer.action_id)}

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
        {:ok, %{status: status, item: %{id: queue_item_id} = item}}
        when status in [:accepted, :duplicate, :retried] and is_integer(queue_item_id) and queue_item_id > 0 ->
          settle_queue_result(state, decision, action_id, attempt_id, status, item)

        {:error, reason} ->
          settle_dispatch_failure(state, decision, action_id, attempt_id, reason)

        _other ->
          settle_dispatch_failure(state, decision, action_id, attempt_id, :invalid_dispatch_result)
      end
    else
      _other -> state
    end
  end

  defp settle_queue_result(state, decision, action_id, attempt_id, :retried, item) do
    restored_attempt_id = item_attempt_id(item) || attempt_id

    data = %{
      action_id: action_id,
      attempt_id: restored_attempt_id,
      queue_item_id: item.id
    }

    case build_and_persist_event(:restored, decision, data, DateTime.utc_now(), state) do
      {:ok, next_state, updated} ->
        next_state
        |> project_delivery_attention(decision, updated, :restored)
        |> then(&%{&1 | retry_counts: Map.delete(&1.retry_counts, action_id)})

      {:error, reason} ->
        lifecycle_append_failed(state, :restored, reason)
    end
  end

  defp settle_queue_result(state, decision, action_id, attempt_id, :duplicate, item) do
    accepted_attempt_id = item_attempt_id(item) || attempt_id

    case Enum.find(decision.dispatch_attempts, &(&1.attempt_id == accepted_attempt_id and &1.queue_item_id == item.id)) do
      nil -> settle_queue_acceptance(state, decision, action_id, accepted_attempt_id, item)
      attempt -> reconcile_existing_queue_snapshot(state, decision, attempt, item)
    end
  end

  defp settle_queue_result(state, decision, action_id, attempt_id, _status, item) do
    accepted_attempt_id = item_attempt_id(item) || attempt_id
    settle_queue_acceptance(state, decision, action_id, accepted_attempt_id, item)
  end

  defp item_attempt_id(item) do
    case Map.get(item, :correlation) do
      correlation when is_map(correlation) -> correlation_value(correlation, :attempt_id)
      _other -> nil
    end
  end

  defp settle_queue_acceptance(state, decision, action_id, attempt_id, item) do
    data = %{action_id: action_id, attempt_id: attempt_id, queue_item_id: item.id}

    case build_and_persist_event(:dispatch_queued, decision, data, DateTime.utc_now(), state) do
      {:ok, next_state, updated} ->
        next_state
        |> project_delivery_attention(decision, updated, :dispatch_queued)
        |> then(&%{&1 | retry_counts: Map.delete(&1.retry_counts, action_id)})
        |> reconcile_queue_snapshot(updated, item, data)

      {:error, reason} ->
        lifecycle_append_failed(state, :dispatch_queued, reason)
    end
  end

  defp reconcile_queue_snapshot(state, decision, %{status: :delivered}, data) do
    persist_snapshot_transitions(state, decision, data, [:delivered])
  end

  defp reconcile_queue_snapshot(state, decision, %{status: :consumed}, data) do
    persist_snapshot_transitions(state, decision, data, [:delivered, :consumed])
  end

  defp reconcile_queue_snapshot(state, decision, %{status: :failed} = item, data) do
    persist_snapshot_transitions(state, decision, Map.put(data, :reason_class, transport_failure_class(Map.get(item, :failure_reason))), [:failed])
  end

  defp reconcile_queue_snapshot(state, _decision, _item, _data), do: state

  defp reconcile_existing_queue_snapshot(state, decision, attempt, item) do
    data = %{
      action_id: decision.answer.action_id,
      attempt_id: attempt.attempt_id,
      queue_item_id: attempt.queue_item_id
    }

    data =
      if Map.get(item, :status) == :failed do
        Map.put(data, :reason_class, transport_failure_class(Map.get(item, :failure_reason)))
      else
        data
      end

    types = missing_snapshot_transitions(attempt.status, Map.get(item, :status))
    persist_snapshot_transitions(state, decision, data, types)
  end

  defp missing_snapshot_transitions(status, :delivered) when status in [:queued, :restored], do: [:delivered]
  defp missing_snapshot_transitions(status, :consumed) when status in [:queued, :restored], do: [:delivered, :consumed]
  defp missing_snapshot_transitions(:delivered, :consumed), do: [:consumed]
  defp missing_snapshot_transitions(status, :failed) when status in [:queued, :restored, :delivered], do: [:failed]
  defp missing_snapshot_transitions(_current, _snapshot), do: []

  defp persist_snapshot_transitions(state, decision, data, types) do
    Enum.reduce_while(types, {state, decision}, fn type, {state_acc, decision_acc} ->
      event_data = if type == :failed, do: data, else: Map.delete(data, :reason_class)

      case build_and_persist_event(type, decision_acc, event_data, DateTime.utc_now(), state_acc) do
        {:ok, next_state, updated} ->
          next_state = project_delivery_attention(next_state, decision_acc, updated, type)
          {:cont, {next_state, updated}}

        {:error, reason} ->
          {:halt, {lifecycle_append_failed(state_acc, type, reason), decision_acc}}
      end
    end)
    |> elem(0)
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

  defp dispatch_allowed?(decision, retry_failed?, :normal), do: dispatchable?(decision, retry_failed?)
  defp dispatch_allowed?(decision, _retry_failed?, :reconcile_queue), do: queue_reconcilable?(decision)

  defp queue_reconcilable?(%Decision{decision_status: :decided, dispatch_attempts: attempts}) do
    match?(%{status: status} when status in [:queued, :restored], List.last(attempts))
  end

  defp queue_reconcilable?(%Decision{}), do: false

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
