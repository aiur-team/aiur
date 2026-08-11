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
  and one Executor alert is emitted — never silently skipped.

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

  alias Aiur.{
    Alerts,
    Boot,
    Config,
    Decision,
    DecisionAnswer,
    DecisionDispatch,
    DecisionEnrichment,
    DecisionEvent,
    DecisionLog,
    DecisionProjection,
    DecisionPubSub,
    DecisionRevision,
    DecisionRevisionDispatch,
    DecisionValidation,
    ExecutorCommandAttention,
    ExecutorEvents,
    JsonStore,
    SecretRedactor
  }

  alias Aiur.DecisionEvent.Unrecognized
  alias Aiur.DecisionQuery.Params, as: DecisionQueryParams
  alias Aiur.DecisionStore.RetainedSnapshot
  alias Aiur.Events.{IdGenerator, Publisher}

  @ndjson_filename "decisions.ndjson"
  @projection_filename "decisions.json"
  @request_timeout 60_000
  @default_legacy_question_version_limit 25
  @default_dispatch_delay_ms 0
  @default_reconcile_delay_ms 250
  @default_retry_delays_ms [250, 1_000, 5_000]
  # Code-enforced ceiling on what the Executor may answer without the operator.
  # Kept as explicit allowlists so an unknown or missing value fails closed.
  @executor_answerable_authorities [:supervisor_allowed, :supervisor_preferred]
  @executor_answerable_reversibilities [:reversible]
  @recent_audit_limit 50
  @recent_decision_limit 50
  @maximum_legacy_page_limit 200
  @maximum_legacy_page_offset 1_000_000
  @transient_failure_classes ["orchestrator_unavailable", "orchestrator_timeout"]
  @revision_transient_failure_classes @transient_failure_classes ++
                                        ["target_agent_unavailable", "target_revalidation_failed"]
  @system_follow_up_actor %{kind: :system, id: "decision-store"}

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

  @doc "Projects one legacy attention into the canonical Decision history."
  @spec project_attention(map(), keyword(), GenServer.server(), timeout()) ::
          {:ok, accept_result()} | {:error, term()}
  def project_attention(payload, opts \\ [], server \\ __MODULE__, timeout \\ @request_timeout)
      when is_map(payload) and is_list(opts) do
    GenServer.call(server, {:project_attention, payload, opts}, timeout)
  end

  @doc "Enriches an existing legacy-attention Decision with structured request content."
  @spec enrich_attention(map(), keyword(), GenServer.server(), timeout()) ::
          {:ok, accept_result()} | {:error, term()}
  def enrich_attention(payload, opts \\ [], server \\ __MODULE__, timeout \\ @request_timeout)
      when is_map(payload) and is_list(opts) do
    GenServer.call(server, {:enrich_attention, payload, opts}, timeout)
  end

  @doc "Appends one constrained, attributed supervisor enrichment to a Decision."
  @spec enrich(String.t(), map(), keyword(), GenServer.server(), timeout()) ::
          {:ok, accept_result()} | {:error, term()}
  def enrich(decision_id, patch, opts \\ [], server \\ __MODULE__, timeout \\ @request_timeout)
      when is_binary(decision_id) and is_map(patch) and is_list(opts) do
    GenServer.call(server, {:enrich, decision_id, patch, opts}, timeout)
  end

  @doc """
  Durably accepts one Executor answer before scheduling its correlated
  delivery. `opts[:actor]` is trusted runtime identity; actor fields in the
  payload are ignored.
  """
  @spec answer(String.t(), map(), keyword(), GenServer.server(), timeout()) ::
          {:ok, map()} | {:error, term()}
  def answer(decision_id, payload, opts \\ [], server \\ __MODULE__, timeout \\ @request_timeout)
      when is_binary(decision_id) and is_map(payload) and is_list(opts) do
    GenServer.call(server, {:answer, decision_id, payload, opts}, timeout)
  end

  @doc """
  Durably records that the Executor deferred one still-undecided Command to
  the operator, then opens the keyed operator attention.

  The Command's status is deliberately unchanged: it stays exactly as
  answerable as it was, so the operator can still answer it and can still
  override the Executor. What changes is the audit trail — the escalation is
  appended as an attributed `:executor_escalated` event, so a later reader can
  see that the Executor deferred rather than decided.
  """
  @spec escalate_executor_command(String.t(), map(), GenServer.server(), timeout()) ::
          {:ok, map()} | {:error, term()}
  def escalate_executor_command(decision_id, payload, server \\ __MODULE__, timeout \\ @request_timeout)
      when is_binary(decision_id) and is_map(payload) do
    GenServer.call(server, {:escalate_executor_command, decision_id, payload}, timeout)
  end

  @doc "Durably dismisses an open Decision without recording an answer."
  @spec dismiss(String.t(), keyword(), GenServer.server(), timeout()) ::
          {:ok, map()} | {:error, term()}
  def dismiss(decision_id, opts \\ [], server \\ __MODULE__, timeout \\ @request_timeout)
      when is_binary(decision_id) and is_list(opts) do
    GenServer.call(server, {:dismiss, decision_id, opts}, timeout)
  end

  @doc "Durably defers an open Decision to the Executor without recording an answer."
  @spec defer(String.t(), keyword(), GenServer.server(), timeout()) :: {:ok, map()} | {:error, term()}
  def defer(decision_id, opts \\ [], server \\ __MODULE__, timeout \\ @request_timeout)
      when is_binary(decision_id) and is_list(opts) do
    GenServer.call(server, {:defer, decision_id, opts}, timeout)
  end

  @doc "Durably expires an open Decision that no live agent can act on."
  @spec expire(String.t(), String.t(), keyword(), GenServer.server(), timeout()) ::
          {:ok, map()} | {:error, term()}
  def expire(decision_id, reason_class, opts \\ [], server \\ __MODULE__, timeout \\ @request_timeout)
      when is_binary(decision_id) and is_binary(reason_class) and is_list(opts) do
    GenServer.call(server, {:expire, decision_id, reason_class, opts}, timeout)
  end

  @doc "Durably records an ordered correction to the active Decision action."
  @spec revise(String.t(), map(), keyword(), GenServer.server(), timeout()) ::
          {:ok, map()} | {:error, term()}
  def revise(decision_id, payload, opts \\ [], server \\ __MODULE__, timeout \\ @request_timeout)
      when is_binary(decision_id) and is_map(payload) and is_list(opts) do
    GenServer.call(server, {:revise, decision_id, payload, opts}, timeout)
  end

  @doc "Durably handles a blocking revision follow-up before clearing its reminder."
  @spec handle_revision_follow_up(String.t(), String.t(), keyword(), GenServer.server(), timeout()) ::
          {:ok, map()} | {:error, term()}
  def handle_revision_follow_up(
        decision_id,
        action_id,
        opts \\ [],
        server \\ __MODULE__,
        timeout \\ @request_timeout
      )
      when is_binary(decision_id) and is_binary(action_id) and is_list(opts) do
    GenServer.call(server, {:handle_revision_follow_up, decision_id, action_id, opts}, timeout)
  end

  @doc "Explicitly retries a failed action or an interrupted lifecycle append."
  @spec retry_dispatch(String.t(), String.t(), GenServer.server()) ::
          {:ok, :scheduled | :already_dispatching} | {:error, term()}
  def retry_dispatch(decision_id, action_id, server \\ __MODULE__)
      when is_binary(decision_id) and is_binary(action_id) do
    GenServer.call(server, {:retry_dispatch, decision_id, action_id})
  end

  @doc "Synchronously validate one correlated item before attempting provider delivery."
  @spec validate_delivery(map(), GenServer.server()) ::
          {:ok, :accepted | :ignored} | {:error, term()}
  def validate_delivery(item, server \\ __MODULE__) when is_map(item) do
    GenServer.call(server, {:validate_delivery, item}, @request_timeout)
  catch
    :exit, _reason -> {:error, :store_unavailable}
  end

  @doc "Synchronously persist provider-confirmed delivery for one correlated queue item."
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
    record_transport_batch_async(type, [item], reason, server)
  end

  @doc "Asynchronously report one queue mutation's correlated settlements as a single batch."
  @spec record_transport_batch_async(:restored | :consumed | :failed, [map()], term(), GenServer.server()) :: :ok
  def record_transport_batch_async(type, items, reason \\ nil, server \\ __MODULE__)
      when type in [:restored, :consumed, :failed] and is_list(items) do
    GenServer.cast(server, {:transport_transitions, type, items, reason})
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

  @doc "Returns one exact retained Decision and its health from one serialized store snapshot."
  @spec retained_lookup(String.t(), GenServer.server()) ::
          {:ok, %{decision: Decision.t() | nil, health: term()}} | {:error, :store_unavailable}
  def retained_lookup(decision_id, server \\ __MODULE__) when is_binary(decision_id) do
    GenServer.call(server, {:retained_lookup, decision_id})
  end

  @doc "Returns a bounded retained Decision page, available total metadata, and canonical counts atomically."
  @spec retained_query(map(), GenServer.server()) :: {:ok, map()} | {:error, :store_unavailable | :invalid_query}
  def retained_query(query, server \\ __MODULE__) when is_map(query) do
    GenServer.call(server, {:retained_query, query})
  end

  @doc false
  @spec retained_legacy_page(map(), non_neg_integer(), pos_integer(), GenServer.server()) ::
          {:ok, map()} | {:error, :store_unavailable | :invalid_query}
  def retained_legacy_page(query, offset, limit, server \\ __MODULE__)
      when is_map(query) and is_integer(offset) and is_integer(limit) do
    GenServer.call(server, {:retained_legacy_page, query, offset, limit})
  end

  @doc "Returns canonical retained open and blocking counts from one serialized store snapshot."
  @spec retained_counts(GenServer.server()) ::
          {:ok,
           %{
             counts: %{
               open: non_neg_integer(),
               blocking: non_neg_integer(),
               total: non_neg_integer()
             },
             health: term()
           }}
          | {:error, :store_unavailable}
  def retained_counts(server \\ __MODULE__) do
    GenServer.call(server, :retained_counts)
  end

  @doc "Returns a bounded dashboard window, prioritizing unresolved and blocking Decisions."
  @spec recent_decisions(non_neg_integer(), GenServer.server()) :: [Decision.t()]
  def recent_decisions(limit \\ @recent_decision_limit, server \\ __MODULE__)
      when is_integer(limit) and limit >= 0 do
    GenServer.call(server, {:recent_decisions, min(limit, @recent_decision_limit)})
  end

  @spec history(String.t(), GenServer.server()) :: {:ok, [Decision.t()]} | {:error, :not_found}
  def history(decision_id, server \\ __MODULE__) when is_binary(decision_id) do
    GenServer.call(server, {:history, decision_id})
  end

  @doc "Returns every Decision's immutable history in audit order in one serialized read."
  @spec all_history(GenServer.server()) :: %{String.t() => [Decision.t()]}
  def all_history(server \\ __MODULE__) do
    GenServer.call(server, :all_history)
  end

  @doc "Returns every Decision's complete immutable audit history in one serialized read."
  @spec all_audit_history(GenServer.server()) :: %{String.t() => [Decision.t() | DecisionEvent.t()]}
  def all_audit_history(server \\ __MODULE__) do
    GenServer.call(server, :all_audit_history)
  end

  @doc "Returns a bounded newest-first audit window with only the contexts needed to project it."
  @spec recent_audit_history(non_neg_integer(), GenServer.server()) :: %{
          records: [Decision.t() | DecisionEvent.t()],
          contexts: map(),
          actions: map(),
          revisions: map()
        }
  def recent_audit_history(limit \\ @recent_audit_limit, server \\ __MODULE__)
      when is_integer(limit) and limit >= 0 do
    GenServer.call(server, {:recent_audit_history, min(limit, @recent_audit_limit)})
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
      |> Map.put(:legacy_question_version_limit, legacy_question_version_limit(opts))
      |> configure_dispatch(opts)

    {:ok, state, {:continue, :schedule_reconciliation}}
  end

  defp configure_dispatch(state, opts) do
    revision_projector =
      Keyword.get(opts, :revision_follow_up_projector, &DecisionRevisionDispatch.project_follow_up/2)

    revision_resolver =
      Keyword.get(opts, :revision_follow_up_resolver, &DecisionRevisionDispatch.resolve_follow_up/2)

    Map.merge(state, %{
      dispatcher: Keyword.get(opts, :dispatcher, &DecisionDispatch.dispatch/2),
      dispatch_delay_ms: Keyword.get(opts, :dispatch_delay_ms, @default_dispatch_delay_ms),
      reconcile_delay_ms: Keyword.get(opts, :reconcile_delay_ms, @default_reconcile_delay_ms),
      retry_delays_ms: Keyword.get(opts, :retry_delays_ms, @default_retry_delays_ms),
      dispatch_scheduler: Keyword.get(opts, :dispatch_scheduler, &Process.send_after/3),
      revision_follow_up_projector: revision_projector,
      revision_follow_up_resolver: revision_resolver,
      event_id_reserver: Keyword.get(opts, :event_id_reserver, &IdGenerator.reserve_durable_id/0),
      executor_attention_opener: Keyword.get(opts, :executor_attention_opener, &ExecutorCommandAttention.open/3),
      executor_request_boot_reconciler: Keyword.get(opts, :executor_request_boot_reconciler, &ExecutorEvents.reconcile_requested/1),
      executor_request_publisher: Keyword.get(opts, :executor_request_publisher, &ExecutorEvents.publish_requested/1),
      executor_request_reconciler: Keyword.get(opts, :executor_request_reconciler, &ExecutorEvents.ensure_requested/1),
      dispatching: MapSet.new(),
      retry_counts: %{},
      projecting_revision_follow_ups: MapSet.new(),
      resolving_revision_follow_ups: MapSet.new(),
      append_retry_counts: %{},
      lifecycle_append_failures: MapSet.new(),
      dispatching_decisions: MapSet.new()
    })
  end

  @impl true
  def handle_continue(:schedule_reconciliation, state) do
    if state.writable? do
      reconcile_requested_executor_notifications(state)
      reconcile_deferred_executor_notifications(state)
      reproject_failure_attentions(state)

      schedule_dispatch_work(
        state,
        {:reconcile_dispatches, dispatch_fences(state)},
        state.reconcile_delay_ms
      )
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
          decision_index: build_decision_index(current),
          retained_index: RetainedSnapshot.build_index(current, history),
          # The store keeps histories newest-first so every accepted append is
          # O(1). The public history call reverses them back to audit order.
          history: reverse_histories(history),
          audit_history: audit_history,
          # Unrecognized records are retained on disk and in `records`, but
          # they are not shown: this binary cannot render an event whose shape
          # it does not know, and guessing would be worse than omitting.
          recent_audit:
            records
            |> Enum.reject(&match?(%Unrecognized{}, &1))
            |> Enum.reverse()
            |> Enum.take(@recent_audit_limit),
          writable?: true,
          health: :writable
        }
        |> repair_projection()
        |> report_unrecognized_records(records, ndjson_path)
        |> apply_corruption(transition_corruption || corruption)

      {:error, reason} ->
        unavailable_state(ndjson_path, {:replay_failed, reason})
    end
  end

  # A newer binary wrote event types this one cannot interpret. That is version
  # skew, not damage, so the store stays writable and keeps answering Commands
  # — but the operator is told, because their projection is silently missing
  # whatever those events said. Deliberately not `needs_attention`: the fix is
  # to roll forward again, and nothing is lost by waiting.
  defp report_unrecognized_records(state, records, path) do
    types =
      records
      |> Enum.filter(&match?(%Unrecognized{}, &1))
      |> Enum.map(& &1.event_type)
      |> Enum.uniq()
      |> Enum.sort()

    if types == [] do
      state
    else
      listed = Enum.join(types, ", ")

      Logger.warning(
        "aiur_decision_store phase=unrecognized_event_types path=#{path} types=#{listed} " <>
          "action=retained_and_skipped"
      )

      _ =
        Alerts.emit_custom(
          "decision_store.unrecognized_event_types",
          "DecisionStore replayed audit records this build does not understand (#{listed}) at #{path}. " <>
            "They are retained on disk and skipped; the store stays writable. " <>
            "This build is older than the one that wrote them — roll forward to project them.",
          needs_attention: false,
          severity: "warning"
        )

      state
    end
  end

  defp apply_corruption(state, nil), do: state

  defp apply_corruption(state, {:corrupt, line, reason}) do
    inspected_reason = inspect(reason)
    path = state.ndjson_path

    Logger.error("aiur_decision_store phase=corruption path=#{path} line=#{line} reason=#{inspected_reason}")

    _ =
      Alerts.emit_custom(
        "decision_store.corrupted",
        "DecisionStore audit log corrupt at #{path} line #{line} " <>
          "(#{inspected_reason}); store is read-only.",
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
      decision_index: :gb_sets.empty(),
      retained_index: RetainedSnapshot.build_index(%{}),
      history: %{},
      audit_history: %{},
      recent_audit: [],
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
            "DecisionStore's decisions.json projection failed to write (#{inspect(reason)}); " <>
              "the audit record stays authoritative, but the store is read-only until repaired.",
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

  defp handle_executor_escalation(decision_id, payload, state) do
    expected_version = Map.get(payload, :expected_version, Map.get(payload, "expected_version"))
    executor_id = present_executor_field(payload, :executor_id)
    reason = present_executor_field(payload, :reason)

    with true <- is_integer(expected_version) and expected_version > 0,
         executor_id when is_binary(executor_id) <- executor_id,
         reason when is_binary(reason) <- reason,
         {:ok, decision} <- fetch_decision(state, decision_id),
         :ok <- validate_executor_escalation(decision, expected_version) do
      record_executor_escalation(state, decision, executor_id, reason)
    else
      false -> {:reply, {:error, :invalid_expected_version}, state}
      nil -> {:reply, {:error, :invalid_escalation}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  # "The Executor decided" and "the Executor deferred to the human" are both
  # decisions about the same Command, so both are appended to the same durable
  # event log before any alert is attempted. The alert marker can be cleaned
  # up, replaced, or lost; the DecisionEvent is what makes the escalation
  # auditable and attributable afterwards.
  defp record_executor_escalation(state, decision, executor_id, reason) do
    if executor_escalation_recorded?(state, decision) do
      open_and_reply(state, decision, executor_id, reason)
    else
      data = %{actor: %{kind: :executor, id: executor_id}, detail: reason}

      case build_and_persist_event(:executor_escalated, decision, data, DateTime.utc_now(), state) do
        {:ok, next_state, updated} -> open_and_reply(next_state, updated, executor_id, reason)
        {:error, reason} -> {:reply, {:error, reason}, state}
      end
    end
  end

  # Re-escalating an already-recorded Command version is a no-op append: the
  # attention opener is separately idempotent and reports `:already_open`.
  defp executor_escalation_recorded?(state, decision) do
    state.audit_history
    |> Map.get(decision.decision_id, [])
    |> Enum.any?(&(&1.type == :executor_escalated and &1.decision_version == decision.version))
  end

  defp open_and_reply(state, decision, executor_id, reason) do
    case open_executor_attention(state, decision, executor_id, reason) do
      {:ok, status} -> {:reply, {:ok, %{status: status, decision: decision}}, state}
      {:error, failure} -> {:reply, {:error, failure}, state}
    end
  end

  defp validate_executor_escalation(decision, expected_version) do
    cond do
      decision.version != expected_version ->
        {:error, {:stale_version, expected_version, decision.version}}

      not is_nil(decision.answer) ->
        {:error, :already_answered}

      decision.decision_status not in [:open, :deferred] ->
        {:error, {:not_open, decision.decision_status}}

      true ->
        :ok
    end
  end

  defp open_executor_attention(state, decision, executor_id, reason) do
    state.executor_attention_opener.(decision, executor_id, reason)
  rescue
    error -> {:error, {:attention_unavailable, Exception.message(error)}}
  catch
    :exit, reason -> {:error, {:attention_unavailable, reason}}
  end

  defp present_executor_field(payload, key) do
    case Map.get(payload, key, Map.get(payload, Atom.to_string(key))) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          value -> value
        end

      _value ->
        nil
    end
  end

  @impl true
  def handle_call({:request, _payload, _opts}, _from, %{writable?: false} = state) do
    {:reply, {:error, {:store_unavailable, state.health}}, state}
  end

  def handle_call({operation, _payload, _opts}, _from, %{writable?: false} = state)
      when operation in [:project_attention, :enrich_attention] do
    {:reply, {:error, {:store_unavailable, state.health}}, state}
  end

  def handle_call({:request, payload, opts}, _from, state) do
    handle_request(payload, opts, state)
  end

  def handle_call({:project_attention, payload, opts}, _from, state) do
    handle_attention_projection(payload, opts, state)
  end

  def handle_call({:enrich_attention, payload, opts}, _from, state) do
    handle_attention_enrichment(payload, opts, state)
  end

  def handle_call({:enrich, _decision_id, _patch, _opts}, _from, %{writable?: false} = state) do
    {:reply, {:error, {:store_unavailable, state.health}}, state}
  end

  def handle_call({:enrich, decision_id, patch, opts}, _from, state) do
    handle_enrichment(decision_id, patch, opts, state)
  end

  def handle_call({:answer, _decision_id, _payload, _opts}, _from, %{writable?: false} = state) do
    {:reply, {:error, {:store_unavailable, state.health}}, state}
  end

  def handle_call({:answer, decision_id, payload, opts}, _from, state) do
    handle_answer(decision_id, payload, opts, state)
  end

  def handle_call({:escalate_executor_command, _decision_id, _payload}, _from, %{writable?: false} = state) do
    {:reply, {:error, {:store_unavailable, state.health}}, state}
  end

  def handle_call({:escalate_executor_command, decision_id, payload}, _from, state) do
    handle_executor_escalation(decision_id, payload, state)
  end

  def handle_call({:dismiss, _decision_id, _opts}, _from, %{writable?: false} = state) do
    {:reply, {:error, {:store_unavailable, state.health}}, state}
  end

  def handle_call({:dismiss, decision_id, opts}, _from, state) do
    handle_dismiss(decision_id, opts, state)
  end

  def handle_call({:defer, _decision_id, _opts}, _from, %{writable?: false} = state) do
    {:reply, {:error, {:store_unavailable, state.health}}, state}
  end

  def handle_call({:defer, decision_id, opts}, _from, state) do
    handle_defer(decision_id, opts, state)
  end

  def handle_call({:expire, _decision_id, _reason_class, _opts}, _from, %{writable?: false} = state) do
    {:reply, {:error, {:store_unavailable, state.health}}, state}
  end

  def handle_call({:expire, decision_id, reason_class, opts}, _from, state) do
    handle_expire(decision_id, reason_class, opts, state)
  end

  def handle_call({:revise, _decision_id, _payload, _opts}, _from, %{writable?: false} = state) do
    {:reply, {:error, {:store_unavailable, state.health}}, state}
  end

  def handle_call({:revise, decision_id, payload, opts}, _from, state) do
    handle_revision(decision_id, payload, opts, state)
  end

  def handle_call({:handle_revision_follow_up, _decision_id, _action_id, _opts}, _from, %{writable?: false} = state) do
    {:reply, {:error, {:store_unavailable, state.health}}, state}
  end

  def handle_call({:handle_revision_follow_up, decision_id, action_id, opts}, _from, state) do
    do_handle_revision_follow_up(decision_id, action_id, opts, state)
  end

  def handle_call({:retry_dispatch, _decision_id, _action_id}, _from, %{writable?: false} = state) do
    {:reply, {:error, {:store_unavailable, state.health}}, state}
  end

  def handle_call({:retry_dispatch, decision_id, action_id}, _from, state) do
    case validate_explicit_retry(state, decision_id, action_id) do
      {:ok, :already_dispatching} ->
        {:reply, {:ok, :already_dispatching}, state}

      {:ok, decision} ->
        if lifecycle_append_failed?(state, action_id) do
          schedule_append_reconciliation(state, decision, action_id, 0)
        else
          schedule_dispatch(state, decision, true, 0)
        end

        {:reply, {:ok, :scheduled}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:transport_transition, _type, _item, _reason}, _from, %{writable?: false} = state) do
    {:reply, {:error, {:store_unavailable, state.health}}, state}
  end

  def handle_call({:validate_delivery, _item}, _from, %{writable?: false} = state) do
    {:reply, {:error, {:store_unavailable, state.health}}, state}
  end

  def handle_call({:validate_delivery, item}, _from, state) do
    {:reply, validate_transport_delivery(state, item), state}
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

  def handle_call({:retained_lookup, decision_id}, _from, state) do
    {:reply, RetainedSnapshot.lookup(state.current, state.health, decision_id), state}
  end

  def handle_call({:retained_query, query}, _from, state) do
    {ordering, query} = Map.pop(query, :ordering, :audit)

    reply =
      case DecisionQueryParams.parse(query) do
        {:ok, normalized} ->
          RetainedSnapshot.query(
            state.current,
            state.retained_index,
            state.health,
            Map.put(normalized, :ordering, ordering)
          )

        {:error, _reason} ->
          {:error, :invalid_query}
      end

    {:reply, reply, state}
  end

  def handle_call({:retained_legacy_page, query, offset, limit}, _from, state) do
    reply =
      with :ok <- valid_legacy_page?(offset, limit),
           {:ok, normalized} <- DecisionQueryParams.parse(legacy_query_params(query)),
           true <- is_nil(normalized.cursor) do
        RetainedSnapshot.legacy_page(
          state.current,
          state.retained_index,
          state.health,
          Map.merge(normalized, %{limit: limit, ordering: :current}),
          offset
        )
      else
        _invalid -> {:error, :invalid_query}
      end

    {:reply, reply, state}
  end

  def handle_call(:retained_counts, _from, state) do
    {:reply, RetainedSnapshot.counts(state.retained_index, state.health), state}
  end

  def handle_call({:recent_decisions, limit}, _from, state) do
    decisions = take_indexed_decisions(state.decision_index, state.current, limit)
    {:reply, decisions, state}
  end

  def handle_call({:history, decision_id}, _from, state) do
    case Map.fetch(state.history, decision_id) do
      {:ok, history} -> {:reply, {:ok, Enum.reverse(history)}, state}
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(:all_history, _from, state) do
    {:reply, reverse_histories(state.history), state}
  end

  def handle_call(:all_audit_history, _from, state) do
    {:reply, state.audit_history, state}
  end

  def handle_call({:recent_audit_history, limit}, _from, state) do
    records = Enum.take(state.recent_audit, limit)
    {:reply, recent_audit_payload(state, records), state}
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

  def handle_cast({:transport_transitions, _type, _items, _reason}, %{writable?: false} = state) do
    {:noreply, state}
  end

  def handle_cast({:transport_transitions, type, items, reason}, state) do
    {:noreply, apply_transport_transitions(state, type, items, reason)}
  end

  defp handle_answer(decision_id, payload, opts, state) do
    with {:ok, decision} <- fetch_decision(state, decision_id),
         {:ok, actor} <- fetch_actor(opts) do
      accept_or_replay_answer(decision, payload, actor, opts, state)
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp accept_or_replay_answer(%Decision{answer: nil} = decision, payload, actor, opts, state) do
    case require_answerable(decision) do
      :ok -> accept_answer(decision, payload, actor, opts, state)
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp accept_or_replay_answer(%Decision{answer: %DecisionAnswer{}} = decision, payload, actor, opts, state) do
    replay_answer(decision, payload, actor, opts, state)
  end

  defp handle_revision(decision_id, payload, opts, state) do
    with {:ok, decision} <- fetch_decision(state, decision_id),
         %DecisionAnswer{} <- Decision.active_answer(decision),
         {:ok, actor} <- fetch_actor(opts) do
      case find_revision_replay(decision, payload) do
        %DecisionRevision{} = accepted -> replay_revision(decision, accepted, payload, actor, opts, state)
        nil -> accept_revision(decision, payload, actor, opts, state)
      end
    else
      nil -> {:reply, {:error, :answer_missing}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp find_revision_replay(decision, payload) do
    case payload_value(payload, :idempotency_key) do
      token when is_binary(token) ->
        action_id =
          token
          |> String.trim()
          |> SecretRedactor.redact()
          |> then(&DecisionAnswer.action_id(decision.decision_id, &1))

        Enum.find(decision.revisions, &(&1.action_id == action_id))

      _other ->
        nil
    end
  end

  defp accept_revision(decision, payload, actor, opts, state) do
    active_answer = Decision.active_answer(decision)

    case normalize_revision(
           decision,
           payload,
           actor,
           opts,
           state,
           active_answer.action_id,
           decision.revision_sequence
         ) do
      {:ok, revision} -> persist_revision(decision, revision, state)
      {:error, reason} -> {:reply, {:error, revision_error(reason, decision)}, state}
    end
  end

  defp replay_revision(decision, accepted, payload, actor, opts, state) do
    case normalize_revision(
           decision,
           payload,
           actor,
           opts,
           state,
           accepted.prior_action_id,
           accepted.sequence - 1,
           accepted.decision_version
         ) do
      {:ok, replayed}
      when replayed.action_id == accepted.action_id and
             replayed.content_hash == accepted.content_hash ->
        next_state = maybe_schedule_after_answer(state, decision, false)
        {:reply, {:ok, revision_result(:duplicate, decision, accepted)}, next_state}

      {:ok, replayed} when replayed.action_id == accepted.action_id ->
        {:reply, {:error, {:conflict, {:idempotency_conflict, accepted.action_id}}}, state}

      {:ok, _replayed} ->
        {:reply, {:error, {:conflict, {:revision_token_conflict, accepted.action_id}}}, state}

      {:error, reason} ->
        {:reply, {:error, revision_error(reason, decision)}, state}
    end
  end

  defp normalize_revision(
         decision,
         payload,
         actor,
         opts,
         state,
         current_action_id,
         current_revision_sequence,
         decision_version \\ nil
       ) do
    decision_version = decision_version || decision.version
    addressed = request_version(state, decision.decision_id, decision_version)
    options = if addressed, do: addressed.options, else: decision.options
    now = Keyword.get(opts, :now, DateTime.utc_now())
    request = addressed || decision
    normalization_opts = Keyword.put(opts, :now, now)

    answer_normalizer = fn answer_payload, _revision_opts ->
      normalize_answer(answer_payload, request, decision_version, options, actor, normalization_opts)
    end

    DecisionRevision.normalize(payload,
      decision_id: decision.decision_id,
      decision_version: decision_version,
      current_action_id: current_action_id,
      current_revision_sequence: current_revision_sequence,
      actor: actor,
      now: now,
      answer_normalizer: answer_normalizer
    )
  end

  defp revision_error({:revision_invalid, {:stale_action, correlation}}, decision),
    do: {:conflict, {:stale_action, Map.put(correlation, :revision_sequence, decision.revision_sequence)}}

  defp revision_error({:revision_invalid, {:stale_sequence, correlation}}, decision),
    do: {:conflict, {:stale_sequence, Map.put(correlation, :action_id, decision.active_action_id)}}

  defp revision_error({:revision_invalid, {:answer_invalid, {:stale_version, expected, current}}}, _decision),
    do: {:conflict, {:stale_version, expected, current}}

  defp revision_error(reason, _decision), do: reason

  defp persist_revision(decision, revision, state) do
    case build_and_persist_event(:revision_recorded, decision, revision, revision.recorded_at, state) do
      {:ok, next_state, updated} ->
        next_state = ensure_superseded_revision_follow_ups(next_state, updated)
        current = Map.fetch!(next_state.current, updated.decision_id)
        next_state = maybe_schedule_after_answer(next_state, current, false)
        {:reply, {:ok, revision_result(:accepted, current, revision)}, next_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp revision_result(status, decision, revision) do
    %{
      status: status,
      decision: decision,
      action: revision,
      revision_result: Map.get(decision.revision_outcomes, revision.action_id, %{result: :recorded}).result,
      dispatch_status: dispatch_status(decision)
    }
  end

  defp do_handle_revision_follow_up(decision_id, action_id, opts, state) do
    with {:ok, decision} <- fetch_decision(state, decision_id),
         {:ok, follow_up} <- fetch_revision_follow_up(decision, action_id),
         {:ok, actor} <- fetch_actor(opts) do
      case follow_up.handled_at do
        nil -> persist_follow_up_handled(state, decision, follow_up, actor, Keyword.get(opts, :detail))
        %DateTime{} -> {:reply, {:ok, follow_up_result(:duplicate, decision, follow_up)}, state}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp fetch_revision_follow_up(decision, action_id) do
    case Map.get(decision.revision_follow_ups, action_id) do
      nil -> {:error, :follow_up_not_required}
      follow_up -> {:ok, follow_up}
    end
  end

  defp persist_follow_up_handled(state, decision, follow_up, actor, detail) do
    data = %{action_id: follow_up.action_id, slug: follow_up.slug, actor: actor, detail: detail}

    case build_and_persist_event(:follow_up_handled, decision, data, DateTime.utc_now(), state) do
      {:ok, next_state, updated} ->
        next_state = maybe_schedule_revision_follow_up_resolution(next_state, updated, follow_up.action_id)
        handled = Map.fetch!(updated.revision_follow_ups, follow_up.action_id)
        {:reply, {:ok, follow_up_result(:accepted, updated, handled)}, next_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp follow_up_result(status, decision, follow_up) do
    %{
      status: status,
      decision_id: decision.decision_id,
      action_id: follow_up.action_id,
      slug: follow_up.slug,
      handled_at: follow_up.handled_at
    }
  end

  defp fetch_decision(state, decision_id) do
    case Map.fetch(state.current, decision_id) do
      {:ok, decision} -> {:ok, decision}
      :error -> {:error, :not_found}
    end
  end

  defp require_answerable(%Decision{decision_status: status}) when status in [:expired, :resolved],
    do: {:error, {:conflict, status}}

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

    case normalize_answer(payload, addressed, accepted.decision_version, addressed.options, actor, opts) do
      {:ok, replayed} -> evaluate_answer_replay(decision, accepted, replayed, state)
      {:error, reason} -> {:reply, {:error, answer_error(reason)}, state}
    end
  end

  defp normalize_answer(payload, request, decision_version, options, actor, opts) do
    with {:ok, answer} <-
           DecisionAnswer.normalize(payload,
             decision_id: request.decision_id,
             decision_version: decision_version,
             options: options,
             actor: actor,
             supervisor_basis: Keyword.get(opts, :supervisor_basis),
             now: Keyword.get(opts, :now, DateTime.utc_now())
           ),
         :ok <- validate_answer_policy_context(answer, request) do
      {:ok, answer}
    end
  end

  defp validate_answer_policy_context(
         %DecisionAnswer{
           actor: %{kind: :supervisor},
           supervisor_basis: %{policy_basis: policy_basis}
         },
         %Decision{} = request
       ) do
    request_kind = request.kind && String.downcase(String.trim(request.kind))

    if policy_basis.authority == request.authority and policy_basis.kind == request_kind and
         policy_basis.reversibility == request.reversibility do
      :ok
    else
      {:error, {:answer_invalid, {:supervisor_basis, :decision_mismatch}}}
    end
  end

  defp validate_answer_policy_context(%DecisionAnswer{actor: %{kind: :supervisor}}, %Decision{}),
    do: {:error, {:answer_invalid, {:supervisor_basis, :decision_mismatch}}}

  # The Executor may answer a Command directly, but "obvious" needs a floor the
  # code enforces rather than one the Executor's prompt is trusted to observe.
  # The Command's own author declares how consequential it is, so that
  # declaration is the gate: only an already-delegable authority and a fully
  # reversible outcome may be auto-answered. Everything else — human_required,
  # irreversible or partially reversible work, and any unrecognized or missing
  # value — is refused here so the Executor must escalate it to the operator
  # instead. This mirrors the supervisor basis check directly above: both bind
  # a non-operator answer to the Decision's own declared policy fields.
  defp validate_answer_policy_context(%DecisionAnswer{actor: %{kind: :executor}}, %Decision{} = request) do
    cond do
      request.authority not in @executor_answerable_authorities ->
        {:error, {:answer_invalid, {:executor_scope, {:authority, request.authority}}}}

      request.reversibility not in @executor_answerable_reversibilities ->
        {:error, {:answer_invalid, {:executor_scope, {:reversibility, request.reversibility}}}}

      true ->
        :ok
    end
  end

  defp validate_answer_policy_context(%DecisionAnswer{}, %Decision{}), do: :ok

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

  defp handle_dismiss(decision_id, opts, state) do
    with {:ok, decision} <- fetch_decision(state, decision_id),
         {:ok, actor} <- fetch_actor(opts) do
      cond do
        decision.decision_status == :dismissed ->
          {:reply, {:ok, %{status: :duplicate, decision: decision}}, state}

        decision.decision_status not in [:open, :deferred] ->
          {:reply, {:error, {:conflict, decision.decision_status}}, state}

        unresolvable_block?(decision) ->
          {:reply, {:error, {:conflict, :blocking_requires_answer}}, state}

        true ->
          persist_dismissal(decision, actor, state)
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  # Dismissal records a status and stops: it delivers nothing to the waiting
  # agent. That is honest for a non-blocking notice, and honest for a legacy
  # attention because the caller resolves the underlying attention alongside
  # it. For an agent-filed blocking Command neither holds — the ticket stays
  # blocked while the row leaves the operator's inbox, which turns a visible
  # block into an invisible one. Refuse instead: the answer path (including a
  # custom response) is what actually releases the agent.
  defp unresolvable_block?(%Decision{blocking: true, legacy_attention: nil}), do: true
  defp unresolvable_block?(_decision), do: false

  defp persist_dismissal(decision, actor, state) do
    case build_and_persist_event(:decision_dismissed, decision, %{actor: actor}, DateTime.utc_now(), state) do
      {:ok, next_state, updated} ->
        {:reply, {:ok, %{status: :accepted, decision: updated}}, next_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp handle_defer(decision_id, opts, state) do
    with {:ok, decision} <- fetch_decision(state, decision_id),
         {:ok, actor} <- fetch_actor(opts) do
      case decision.decision_status do
        :open -> persist_deferral(decision, actor, state)
        :deferred -> {:reply, {:ok, %{status: :duplicate, decision: decision}}, state}
        status -> {:reply, {:error, {:conflict, status}}, state}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp persist_deferral(decision, actor, state) do
    case build_and_persist_event(:decision_deferred, decision, %{actor: actor}, DateTime.utc_now(), state) do
      {:ok, next_state, updated} ->
        {:reply, {:ok, %{status: :accepted, decision: updated}}, next_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp handle_expire(decision_id, reason_class, opts, state) do
    case fetch_decision(state, decision_id) do
      {:ok, %{decision_status: :open} = decision} ->
        persist_expiration(decision, reason_class, opts, state)

      {:ok, %{decision_status: :expired} = decision} ->
        {:reply, {:ok, %{status: :duplicate, decision: decision}}, state}

      {:ok, decision} ->
        {:reply, {:error, {:conflict, decision.decision_status}}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp persist_expiration(decision, reason_class, opts, state) do
    occurred_at = Keyword.get(opts, :now, DateTime.utc_now())
    data = %{reason_class: reason_class, actor: @system_follow_up_actor}

    case build_and_persist_event(:decision_expired, decision, data, occurred_at, state) do
      {:ok, next_state, updated} ->
        {:reply, {:ok, %{status: :accepted, decision: updated}}, next_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp dispatch_status(%Decision{delivery_status: :pending}), do: :dispatch_pending
  defp dispatch_status(%Decision{delivery_status: status}), do: status

  defp handle_enrichment(decision_id, patch, opts, state) do
    with {:ok, current} <- fetch_decision(state, decision_id),
         {:ok, expected_version} <- enrichment_expected_version(opts),
         {:ok, base} <- enrichment_base(state, current, expected_version),
         normalization_opts <-
           opts
           |> Keyword.put(:expected_version, expected_version)
           |> Keyword.put_new(:now, DateTime.utc_now()),
         {:ok, enrichment} <- DecisionEnrichment.normalize(base, patch, normalization_opts) do
      apply_enrichment(state, current, enrichment, normalization_opts[:now])
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp enrichment_expected_version(opts) do
    case Keyword.get(opts, :expected_version) do
      version when is_integer(version) and version > 0 -> {:ok, version}
      _invalid -> {:error, {:enrichment_invalid, {:expected_version, :invalid}}}
    end
  end

  defp enrichment_base(state, current, expected_version) do
    cond do
      expected_version == current.version ->
        {:ok, current}

      base = request_version(state, current.decision_id, expected_version) ->
        {:ok, base}

      true ->
        {:error, {:conflict, {:stale_version, expected_version, current.version}}}
    end
  end

  defp apply_enrichment(state, current, enrichment, occurred_at) do
    case prior_enrichment(state, current.decision_id, enrichment.expected_version) do
      %DecisionEvent{} = prior ->
        evaluate_enrichment_replay(state, prior, enrichment)

      nil when enrichment.expected_version != current.version ->
        {:reply, {:error, {:conflict, {:stale_version, enrichment.expected_version, current.version}}}, state}

      nil when not enrichment.changed ->
        {:reply, {:ok, %{status: :duplicate, decision: current}}, state}

      nil ->
        persist_enrichment(state, current, enrichment, occurred_at)
    end
  end

  defp prior_enrichment(state, decision_id, expected_version) do
    state.audit_history
    |> Map.get(decision_id, [])
    |> Enum.find(fn
      %DecisionEvent{type: :enriched, data: %{expected_version: ^expected_version}} -> true
      _other -> false
    end)
  end

  defp evaluate_enrichment_replay(state, prior, enrichment) do
    if prior.data.actor == enrichment.actor and
         prior.data.decision.content_hash == enrichment.decision.content_hash do
      decision = enrichment_replay_decision(state, prior)
      {:reply, {:ok, %{status: :duplicate, decision: decision}}, state}
    else
      {:reply, {:error, {:conflict, {:idempotency_conflict, enrichment.expected_version}}}, state}
    end
  end

  defp enrichment_replay_decision(state, prior) do
    current = Map.fetch!(state.current, prior.decision_id)

    if current.version == prior.data.decision.version,
      do: current,
      else: prior.data.decision
  end

  defp persist_enrichment(state, current, enrichment, occurred_at) do
    data = %{
      decision: enrichment.decision,
      actor: enrichment.actor,
      expected_version: enrichment.expected_version
    }

    with {:ok, event_id} <- state.event_id_reserver.(),
         {:ok, event} <-
           DecisionEvent.new(:enriched, current.decision_id, enrichment.decision.version, data,
             event_id: event_id,
             run_id: Boot.run_id(),
             now: occurred_at
           ),
         {:ok, updated} <- validate_transition(current, event),
         :ok <- DecisionLog.append(state.ndjson_path, DecisionEvent.to_json_safe(event)) do
      next_state =
        %{
          state
          | current: Map.put(state.current, current.decision_id, updated),
            decision_index: update_decision_index(state.decision_index, current, updated),
            retained_index: RetainedSnapshot.update_index(state.retained_index, current, updated),
            history: Map.update(state.history, current.decision_id, [event.data.decision], &[event.data.decision | &1]),
            audit_history: Map.update(state.audit_history, current.decision_id, [event], &(&1 ++ [event])),
            recent_audit: remember_recent_audit(state.recent_audit, event)
        }
        |> repair_projection()

      if next_state.writable?, do: notify_lifecycle(updated, event, event_id)
      {:reply, {:ok, %{status: :accepted, decision: updated}}, next_state}
    else
      {:error, :not_durable} -> {:reply, {:error, :event_id_not_durable}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp handle_request(payload, opts, state) do
    with {:ok, requested_version} <- fetch_requested_version(payload),
         {:ok, decision} <- DecisionValidation.normalize(payload, opts) do
      evaluate_and_apply(decision, requested_version, state)
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp handle_attention_projection(payload, opts, state) do
    case normalize_legacy_attention(payload, opts) do
      {:ok, decision} -> apply_attention_projection_for_source(decision, opts, state)
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp apply_attention_projection_for_source(decision, opts, state) do
    case prior_source_event_result(decision, state) do
      {:duplicate, prior} ->
        {:reply, {:ok, %{status: :duplicate, decision: prior}}, state}

      {:conflict, event_id} ->
        {:reply, {:error, {:conflict, {:source_event_conflict, event_id}}}, state}

      :new ->
        case Map.get(state.current, decision.decision_id) do
          nil -> accept(%{decision | version: 1}, state)
          existing -> apply_attention_projection(existing, decision, opts, state)
        end
    end
  end

  defp apply_attention_projection(existing, decision, opts, state) do
    cond do
      existing.legacy_attention != decision.legacy_attention ->
        {:reply, {:error, {:legacy_attention, :provenance_mismatch}}, state}

      Keyword.get(opts, :legacy_import, false) ->
        {:reply, {:ok, %{status: :duplicate, decision: existing}}, state}

      existing.question == decision.question ->
        {:reply, {:ok, %{status: :duplicate, decision: existing}}, state}

      legacy_question_version_limit_reached?(existing, state) ->
        limit = state.legacy_question_version_limit
        {:reply, {:error, {:legacy_attention, {:version_limit, limit}}}, state}

      true ->
        merge_attention_question(existing, decision, opts, state)
    end
  end

  defp merge_attention_question(existing, incoming, opts, state) do
    source_created_at = earliest_source_created_at(existing.source_created_at, incoming.source_created_at)

    payload =
      existing
      |> DecisionProjection.to_request_payload()
      |> Map.put("question", incoming.question)
      |> replace_source_created_at(source_created_at)

    normalize_opts =
      opts
      |> Keyword.put(:ticket, existing.ticket)
      |> Keyword.put(:source, incoming.source)
      |> Keyword.put(:now, incoming.created_at)
      |> Keyword.put(:legacy_attention, existing.legacy_attention)

    case DecisionValidation.normalize(payload, normalize_opts) do
      {:ok, merged} -> accept(%{merged | version: existing.version + 1}, state)
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp handle_attention_enrichment(payload, opts, state) do
    with {:ok, decision} <- normalize_legacy_attention(payload, opts),
         {:ok, existing} <- fetch_legacy_attention(state, decision) do
      decision = preserve_source_created_at(existing, decision)
      apply_attention_enrichment(existing, decision, payload, state)
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp apply_attention_enrichment(existing, decision, payload, state) do
    case prior_source_event_result(decision, state) do
      {:duplicate, prior} ->
        {:reply, {:ok, %{status: :duplicate, decision: prior}}, state}

      {:conflict, event_id} ->
        {:reply, {:error, {:conflict, {:source_event_conflict, event_id}}}, state}

      :new ->
        apply_new_attention_enrichment(existing, decision, payload, state)
    end
  end

  defp apply_new_attention_enrichment(existing, decision, payload, state) do
    if explicit_version?(payload) or existing.content_hash != decision.content_hash do
      evaluate_attention_enrichment(existing, decision, payload, state)
    else
      {:reply, {:ok, %{status: :duplicate, decision: existing}}, state}
    end
  end

  defp evaluate_attention_enrichment(existing, decision, payload, state) do
    case fetch_attention_enrichment_version(payload, existing.version) do
      {:ok, requested_version} -> evaluate_and_apply(decision, requested_version, state)
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp normalize_legacy_attention(payload, opts) do
    with {:ok, decision} <- DecisionValidation.normalize(payload, opts),
         %{} <- decision.legacy_attention do
      {:ok, decision}
    else
      nil -> {:error, {:legacy_attention, :missing_provenance}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_legacy_attention(state, decision) do
    case Map.get(state.current, decision.decision_id) do
      nil ->
        {:error, {:legacy_attention, :not_found}}

      %{legacy_attention: legacy_attention} = existing
      when legacy_attention == decision.legacy_attention ->
        {:ok, existing}

      _existing ->
        {:error, {:legacy_attention, :provenance_mismatch}}
    end
  end

  defp prior_source_event_result(decision, state) do
    case source_event_key(decision) do
      nil ->
        :new

      key ->
        state.history
        |> Map.get(decision.decision_id, [])
        |> Enum.find(&(source_event_key(&1) == key))
        |> case do
          nil -> :new
          %{content_hash: hash} = prior when hash == decision.content_hash -> {:duplicate, prior}
          _prior -> {:conflict, elem(key, 2)}
        end
    end
  end

  defp source_event_key(%{source: %{agent_id: agent_id, session_id: session_id, event_id: event_id}})
       when is_binary(event_id) and event_id != "" do
    {agent_id, session_id, event_id}
  end

  defp source_event_key(_decision), do: nil

  defp fetch_attention_enrichment_version(payload, current_version) do
    fetch_requested_version(payload, current_version + 1)
  end

  defp explicit_version?(payload) do
    not is_nil(raw_version(payload))
  end

  defp replace_source_created_at(payload, nil), do: Map.delete(payload, "created_at")

  defp replace_source_created_at(payload, source_created_at) do
    Map.put(payload, "created_at", DateTime.to_iso8601(source_created_at))
  end

  defp preserve_source_created_at(existing, incoming) do
    %{incoming | source_created_at: earliest_source_created_at(existing.source_created_at, incoming.source_created_at)}
  end

  defp earliest_source_created_at(nil, incoming), do: incoming
  defp earliest_source_created_at(existing, nil), do: existing

  defp earliest_source_created_at(existing, incoming) do
    if DateTime.compare(existing, incoming) == :gt, do: incoming, else: existing
  end

  defp fetch_requested_version(payload, default \\ 1) do
    case raw_version(payload) do
      nil -> {:ok, default}
      version when is_integer(version) and version > 0 -> {:ok, version}
      _other -> {:error, {:version, :invalid_type}}
    end
  end

  defp raw_version(payload), do: Map.get(payload, "version", Map.get(payload, :version))

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
            decision_index:
              update_decision_index(
                state.decision_index,
                Map.get(state.current, decision.decision_id),
                current
              ),
            retained_index:
              RetainedSnapshot.update_index(
                state.retained_index,
                Map.get(state.current, decision.decision_id),
                current
              ),
            history: Map.update(state.history, decision.decision_id, [decision], &[decision | &1]),
            audit_history: Map.update(state.audit_history, decision.decision_id, [event], &(&1 ++ [event])),
            recent_audit: remember_recent_audit(state.recent_audit, event)
        }
        |> repair_projection()

      notify(current, event_id, state)
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
    with {:ok, next_state, updated, event} <-
           build_and_append_event(type, decision, data, occurred_at, state) do
      finalized = repair_and_notify_lifecycle(next_state, [{updated, event}])
      {:ok, finalized, updated}
    end
  end

  defp build_and_append_event(type, decision, data, occurred_at, state) do
    with {:ok, event_id} <- state.event_id_reserver.(),
         {:ok, event} <-
           DecisionEvent.new(type, decision.decision_id, lifecycle_version(decision, data), data,
             event_id: event_id,
             run_id: Boot.run_id(),
             now: occurred_at
           ),
         {:ok, updated} <- validate_transition(decision, event),
         :ok <- DecisionLog.append(state.ndjson_path, DecisionEvent.to_json_safe(event)) do
      next_state = %{
        state
        | current: Map.put(state.current, decision.decision_id, updated),
          decision_index: update_decision_index(state.decision_index, decision, updated),
          retained_index: RetainedSnapshot.update_index(state.retained_index, decision, updated),
          audit_history: Map.update(state.audit_history, decision.decision_id, [event], &(&1 ++ [event])),
          recent_audit: remember_recent_audit(state.recent_audit, event)
      }

      {:ok, next_state, updated, event}
    else
      {:error, :not_durable} -> {:error, :event_id_not_durable}
      {:error, reason} -> {:error, reason}
    end
  end

  defp repair_and_notify_lifecycle(state, lifecycle_events) do
    next_state = repair_projection(state)

    next_state =
      Enum.reduce(lifecycle_events, next_state, fn {decision, event}, state_acc ->
        case Map.get(event.data, :action_id) do
          action_id when is_binary(action_id) ->
            resolve_lifecycle_append_failure(state_acc, decision, action_id)

          _action_id ->
            state_acc
        end
      end)

    if next_state.writable? do
      Enum.each(lifecycle_events, fn {decision, event} -> notify_lifecycle(decision, event) end)
    end

    next_state
  end

  defp lifecycle_version(_decision, %DecisionAnswer{decision_version: version}), do: version
  defp lifecycle_version(_decision, %DecisionRevision{decision_version: version}), do: version

  defp lifecycle_version(decision, %{action_id: action_id}) do
    case Decision.answer_for_action(decision, action_id) do
      %DecisionAnswer{decision_version: version} -> version
      nil -> decision.version
    end
  end

  defp lifecycle_version(decision, %{actor: _actor}), do: decision.version
  defp lifecycle_version(decision, %{reason_class: _reason_class}), do: decision.version

  defp lifecycle_version(decision, _data), do: Decision.active_answer(decision).decision_version

  defp validate_transition(decision, event) do
    case DecisionProjection.reduce_checked([decision, event]) do
      {%{current: current}, nil} -> {:ok, current[decision.decision_id]}
      {_projection, {:corrupt, _line, {:invalid_transition, reason}}} -> {:error, {:invalid_transition, reason}}
    end
  end

  defp notify_lifecycle(decision, event), do: notify_lifecycle(decision, event, event.event_id)

  defp notify_lifecycle(decision, event, cursor_event_id) do
    topic = "ticket.#{decision.ticket.identifier}.agent.decision.#{lifecycle_slug(event.type)}"

    try do
      Publisher.publish_persisted(topic, DecisionEvent.to_json_safe(event), cursor_event_id, digest_source: :orchestrator)
    rescue
      error -> Logger.warning("aiur_decision_store phase=lifecycle_publisher_failed error=#{Exception.message(error)}")
    end

    if event.type == :decision_deferred do
      notify_deferred_executor(decision)
    end

    if event.type in [:answer_recorded, :decision_dismissed, :decision_expired] do
      resolve_executor_escalation(decision)
    end

    try do
      DecisionPubSub.broadcast_changed(decision.decision_id, decision.version)
    rescue
      error -> Logger.warning("aiur_decision_store phase=lifecycle_pubsub_failed error=#{Exception.message(error)}")
    end

    :ok
  end

  defp resolve_executor_escalation(decision) do
    case ExecutorCommandAttention.resolve(decision) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("aiur_decision_store phase=executor_escalation_resolution_failed reason=#{inspect(reason)}")
    end
  rescue
    error -> Logger.warning("aiur_decision_store phase=executor_escalation_resolution_failed error=#{Exception.message(error)}")
  end

  defp reconcile_deferred_executor_notifications(state) do
    state.current
    |> Map.values()
    |> Enum.filter(&(&1.decision_status == :deferred))
    |> Enum.each(&notify_deferred_executor/1)
  end

  defp reconcile_requested_executor_notifications(state) do
    decisions =
      state.current
      |> Map.values()
      |> Enum.filter(&(&1.decision_status in [:open, :deferred]))

    reconcile_requested_executor_notifications(decisions, state)
  end

  defp reconcile_requested_executor_notifications(decisions, state) do
    case state.executor_request_boot_reconciler.(decisions) do
      {:ok, _published_count} ->
        :ok

      {:error, reason} ->
        Logger.warning("aiur_decision_store phase=executor_request_reconciliation_failed reason=#{inspect(reason)}")
        Enum.each(decisions, &schedule_executor_request_retry(&1, state, 0))
    end
  rescue
    error ->
      Logger.warning("aiur_decision_store phase=executor_request_reconciliation_failed error=#{Exception.message(error)}")
      Enum.each(decisions, &schedule_executor_request_retry(&1, state, 0))
  catch
    :exit, reason ->
      Logger.warning("aiur_decision_store phase=executor_request_reconciliation_failed exit=#{inspect(reason)}")
      Enum.each(decisions, &schedule_executor_request_retry(&1, state, 0))
  end

  defp notify_deferred_executor(decision) do
    case ExecutorEvents.publish_deferred(decision) do
      {:ok, _id, _subscribers} -> :ok
      {:error, reason} -> Logger.warning("aiur_decision_store phase=executor_notification_failed reason=#{inspect(reason)}")
    end
  rescue
    error -> Logger.warning("aiur_decision_store phase=executor_notification_failed error=#{Exception.message(error)}")
  end

  defp lifecycle_slug(:answer_recorded), do: "answered"
  defp lifecycle_slug(:decision_expired), do: "expired"
  defp lifecycle_slug(:decision_dismissed), do: "dismissed"
  defp lifecycle_slug(:decision_deferred), do: "deferred"
  defp lifecycle_slug(:executor_escalated), do: "executor-escalated"
  defp lifecycle_slug(:enriched), do: "enriched"
  defp lifecycle_slug(:revision_recorded), do: "revision-recorded"
  defp lifecycle_slug(:dispatch_queued), do: "queued"
  defp lifecycle_slug(:revision_dispatched), do: "revision-dispatched"
  defp lifecycle_slug(:revision_no_longer_applicable), do: "revision-no-longer-applicable"
  defp lifecycle_slug(:follow_up_required), do: "revision-follow-up-required"
  defp lifecycle_slug(:follow_up_handled), do: "revision-follow-up-handled"
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
    event_data = %{action_id: action_id, actor: actor, source: source, detail: detail}

    with true <- (is_binary(decision_id) and decision_id != "") or {:error, :invalid_decision_id},
         true <- (is_binary(ticket_identifier) and ticket_identifier != "") or {:error, :invalid_ticket},
         true <- is_map(actor) or {:error, :invalid_actor},
         {:ok, candidate} <-
           DecisionEvent.new(type, decision_id, expected_version, event_data,
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
      {:error, reason} -> {:error, reason}
    end
  end

  defp payload_value(payload, key), do: Map.get(payload, key, Map.get(payload, Atom.to_string(key)))

  defp validate_agent_lifecycle_target(decision, context) do
    active_answer = Decision.active_answer(decision)

    cond do
      decision.ticket.identifier != context.ticket_identifier ->
        {:error, {:conflict, {:ticket_mismatch, context.ticket_identifier, decision.ticket.identifier}}}

      is_nil(active_answer) ->
        {:error, {:invalid_transition, :answer_missing}}

      active_answer.action_id != context.data.action_id ->
        {:error, {:conflict, {:action_mismatch, context.data.action_id, active_answer.action_id}}}

      active_answer.decision_version != context.expected_version ->
        {:error, {:conflict, {:stale_version, context.expected_version, active_answer.decision_version}}}

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

  defp delivered_once?(decision) do
    Enum.any?(Decision.active_dispatch_attempts(decision), &(not is_nil(&1.delivered_at)))
  end

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
    active_answer = Decision.active_answer(decision)

    %{
      status: status,
      lifecycle: type,
      decision_id: decision.decision_id,
      version: decision.version,
      answered_version: active_answer.decision_version,
      action_id: active_answer.action_id,
      decision_status: decision.decision_status
    }
  end

  defp apply_transport_transition(state, type, item, reason) do
    case correlated_transport_context(state, item) do
      {:ok, decision, attempt, context} when is_map(attempt) ->
        if type == :delivered and attempt.status == :failed do
          persist_restored_attempt_delivery(state, decision, context)
        else
          persist_transport_transition(state, decision, attempt, context, type, reason)
        end

      {:ok, decision, :missing_attempt, context} when type == :delivered ->
        persist_missing_attempt_delivery(state, decision, context)

      {:ok, _decision, :missing_attempt, _context} ->
        {{:error, :attempt_not_found}, state}

      {:ok, :ignored} ->
        {{:ok, :ignored}, state}

      {:error, reason} ->
        {{:error, reason}, state}
    end
  end

  defp validate_transport_delivery(state, item) do
    case correlated_transport_context(state, item) do
      {:ok, _decision, %{status: status}, _context}
      when status in [:queued, :restored, :delivered] ->
        {:ok, :accepted}

      {:ok, _decision, %{status: status}, _context} ->
        {:error, {:delivery_attempt_not_ready, status}}

      {:ok, _decision, :missing_attempt, _context} ->
        {:ok, :accepted}

      {:ok, :ignored} ->
        {:ok, :ignored}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp correlated_transport_context(state, item) do
    correlation = Map.get(item, :correlation)
    action_id = Map.get(item, :action_id)

    if is_map(correlation) and is_binary(action_id) do
      with {:ok, context} <- normalize_transport_context(item, correlation, action_id),
           {:ok, decision} <- fetch_decision(state, context.decision_id),
           :ok <- validate_transport_decision(decision, context),
           {:ok, attempt} <- resolve_dispatch_attempt(decision, context) do
        {:ok, decision, attempt, context}
      end
    else
      {:ok, :ignored}
    end
  end

  defp resolve_dispatch_attempt(decision, context) do
    case fetch_dispatch_attempt(decision, context) do
      {:error, :attempt_not_found} -> resolve_missing_dispatch_attempt(decision, context.action_id)
      result -> result
    end
  end

  defp resolve_missing_dispatch_attempt(decision, action_id) do
    if Enum.any?(decision.dispatch_attempts, &(&1.action_id == action_id)),
      do: {:error, :attempt_not_found},
      else: {:ok, :missing_attempt}
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

    case validate_transport_context(context, action_id) do
      :ok -> {:ok, context}
      error -> error
    end
  end

  defp validate_transport_context(context, action_id) do
    cond do
      not is_binary(context.decision_id) -> {:error, :invalid_decision_correlation}
      not positive_integer?(context.decision_version) -> {:error, :invalid_decision_correlation}
      context.action_id != action_id -> {:error, :action_mismatch}
      not is_binary(context.attempt_id) -> {:error, :invalid_decision_correlation}
      not positive_integer?(context.queue_item_id) -> {:error, :invalid_decision_correlation}
      not is_binary(context.target) -> {:error, :invalid_decision_correlation}
      true -> :ok
    end
  end

  defp positive_integer?(value), do: is_integer(value) and value > 0

  defp correlation_value(correlation, key),
    do: Map.get(correlation, key, Map.get(correlation, Atom.to_string(key)))

  defp validate_transport_decision(decision, context) do
    answer = Decision.answer_for_action(decision, context.action_id)

    cond do
      decision.ticket.identifier != context.target -> {:error, :ticket_mismatch}
      is_nil(answer) -> {:error, :action_mismatch}
      answer.decision_version != context.decision_version -> {:error, :version_mismatch}
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

  defp persist_missing_attempt_delivery(state, decision, context) do
    data = %{
      action_id: context.action_id,
      attempt_id: context.attempt_id,
      queue_item_id: context.queue_item_id
    }

    event_type = if revision_action?(decision, context.action_id), do: :revision_dispatched, else: :dispatch_queued

    case build_and_persist_event(event_type, decision, data, DateTime.utc_now(), state) do
      {:ok, %{writable?: true} = queued_state, queued_decision} ->
        {:ok, attempt} = fetch_dispatch_attempt(queued_decision, context)
        persist_transport_transition(queued_state, queued_decision, attempt, context, :delivered, nil)

      {:ok, queued_state, _queued_decision} ->
        {{:error, {:store_unavailable, queued_state.health}}, queued_state}

      {:error, reason} ->
        {{:error, reason}, state}
    end
  end

  defp persist_restored_attempt_delivery(state, decision, context) do
    data = %{
      action_id: context.action_id,
      attempt_id: context.attempt_id,
      queue_item_id: context.queue_item_id
    }

    case build_and_persist_event(:restored, decision, data, DateTime.utc_now(), state) do
      {:ok, %{writable?: true} = restored_state, restored_decision} ->
        {:ok, restored_attempt} = fetch_dispatch_attempt(restored_decision, context)
        persist_transport_transition(restored_state, restored_decision, restored_attempt, context, :delivered, nil)

      {:ok, restored_state, _restored_decision} ->
        {{:error, {:store_unavailable, restored_state.health}}, restored_state}

      {:error, reason} ->
        {{:error, reason}, state}
    end
  end

  defp persist_transport_transition(state, decision, attempt, context, type, reason) do
    case append_transport_transition(state, decision, attempt, context, type, reason) do
      {:ok, :duplicate, next_state, nil} ->
        {{:ok, :duplicate}, next_state}

      {:ok, :accepted, next_state, {updated, event}} ->
        finalized = repair_and_notify_lifecycle(next_state, [{updated, event}])
        finalized = maybe_project_delivery_attention(finalized, decision, updated, type, context.action_id)
        {{:ok, :accepted}, finalized}

      {:error, transition_reason} ->
        {{:error, transition_reason}, state}
    end
  end

  defp append_transport_transition(state, decision, attempt, context, type, reason) do
    reason_class = if type == :failed, do: transport_failure_class(reason)

    if duplicate_transport_transition?(attempt, type, reason_class) do
      {:ok, :duplicate, state, nil}
    else
      data = %{
        action_id: context.action_id,
        attempt_id: context.attempt_id,
        queue_item_id: context.queue_item_id,
        reason_class: reason_class
      }

      case build_and_append_event(type, decision, data, DateTime.utc_now(), state) do
        {:ok, next_state, updated, event} ->
          {:ok, :accepted, next_state, {updated, event}}

        {:error, transition_reason} ->
          {:error, transition_reason}
      end
    end
  end

  defp apply_transport_transitions(state, type, items, reason) do
    items
    |> Enum.reduce({state, []}, &apply_transport_transition_item(&1, &2, type, reason))
    |> finalize_transport_transitions(type)
  end

  defp apply_transport_transition_item(item, {state, events}, type, reason) do
    case correlated_transport_context(state, item) do
      {:ok, decision, attempt, context} when is_map(attempt) ->
        append_transport_transition_item(state, events, decision, attempt, context, type, reason)

      {:ok, _decision, :missing_attempt, _context} ->
        Logger.warning("aiur_decision_store phase=transport_batch_missing_attempt type=#{type}")
        {state, events}

      {:ok, :ignored} ->
        {state, events}

      {:error, context_reason} ->
        Logger.warning("aiur_decision_store phase=transport_batch_rejected type=#{type} reason=#{inspect(context_reason)}")
        {state, events}
    end
  end

  defp append_transport_transition_item(state, events, decision, attempt, context, type, reason) do
    case append_transport_transition(state, decision, attempt, context, type, reason) do
      {:ok, :duplicate, duplicate_state, nil} ->
        {duplicate_state, events}

      {:ok, :accepted, appended_state, {updated, event}} ->
        {appended_state, [{decision, updated, event} | events]}

      {:error, append_reason} ->
        {recover_background_append(state, decision, context.action_id, type, append_reason), events}
    end
  end

  defp finalize_transport_transitions({next_state, lifecycle_events}, type) do
    ordered_events = Enum.reverse(lifecycle_events)

    finalized =
      case ordered_events do
        [] -> next_state
        events -> repair_and_notify_lifecycle(next_state, lifecycle_event_pairs(events))
      end

    Enum.reduce(ordered_events, finalized, fn {prior, updated, event}, state_acc ->
      maybe_project_delivery_attention(state_acc, prior, updated, type, event.data.action_id)
    end)
  end

  defp lifecycle_event_pairs(events) do
    Enum.map(events, fn {_prior, updated, event} -> {updated, event} end)
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

  defp maybe_project_delivery_attention(state, prior, updated, type, action_id) do
    if prior.active_action_id == action_id,
      do: project_delivery_attention(state, prior, updated, type),
      else: state
  end

  defp reproject_failure_attentions(state) do
    state.current
    |> Map.values()
    |> Enum.filter(&(&1.delivery_status == :failed and not is_nil(Decision.active_answer(&1))))
    |> Enum.each(&emit_failure_attention/1)

    :ok
  end

  defp emit_failure_attention(decision) do
    active_answer = Decision.active_answer(decision)

    reason_class =
      case List.last(Decision.active_dispatch_attempts(decision)) do
        %{failure_reason_class: reason_class} when is_binary(reason_class) -> reason_class
        _attempt -> "delivery_failed"
      end

    Alerts.emit_custom(
      failure_attention_topic(decision),
      "Decision answer delivery failed for #{decision.decision_id} (#{reason_class}).",
      issue: decision.ticket.identifier,
      reason:
        "Decision #{decision.decision_id} action #{active_answer.action_id} " <>
          "remains actionable after #{reason_class}.",
      needs_attention: true,
      severity: "warning"
    )
  end

  defp emit_failure_resolution(decision) do
    active_answer = Decision.active_answer(decision)

    Alerts.emit_custom(
      failure_attention_topic(decision) <> ".resolved",
      "Decision answer delivery recovered for #{decision.decision_id}.",
      issue: decision.ticket.identifier,
      reason: "Decision #{decision.decision_id} action #{active_answer.action_id} delivery recovered.",
      needs_attention: false,
      severity: "info"
    )
  end

  defp failure_attention_topic(decision) do
    action_slug = decision |> Decision.active_answer() |> Map.fetch!(:action_id) |> String.replace("_", "-")
    "ticket.#{decision.ticket.identifier}.agent.attention.decision-delivery-#{action_slug}"
  end

  @impl true
  def handle_info({:retry_executor_request_notification, decision_id, version, attempt}, state) do
    case Map.get(state.current, decision_id) do
      %Decision{version: ^version, decision_status: status} = decision when status in [:open, :deferred] ->
        notify_requested_executor(decision, state, :executor_request_reconciler, attempt)

      _terminal_or_replaced ->
        :ok
    end

    {:noreply, state}
  end

  def handle_info({:reconcile_dispatches, fences}, state) do
    next_state =
      Enum.reduce(fences, state, &reconcile_scheduled_decision/2)

    {:noreply, next_state}
  end

  def handle_info({:dispatch_action, fence, retry_failed?}, state) do
    {:noreply, maybe_start_dispatch(state, fence, retry_failed?)}
  end

  def handle_info({:reconcile_queue_action, fence}, state) do
    {:noreply, maybe_start_dispatch(state, fence, false, :reconcile_queue)}
  end

  def handle_info({:reconcile_lifecycle_append, fence, action_id}, state) do
    {:noreply, maybe_reconcile_lifecycle_append(state, fence, action_id)}
  end

  def handle_info({:dispatch_result, decision_id, action_id, attempt_id, result}, state) do
    state = %{
      state
      | dispatching: MapSet.delete(state.dispatching, action_id),
        dispatching_decisions: MapSet.delete(state.dispatching_decisions, decision_id)
    }

    state = settle_dispatch(state, decision_id, action_id, attempt_id, result)
    {:noreply, maybe_schedule_superseding_dispatch(state, decision_id, action_id)}
  end

  def handle_info({:project_revision_follow_up, decision_id, action_id}, state) do
    {:noreply, start_revision_follow_up_task(state, :project, decision_id, action_id)}
  end

  def handle_info({:resolve_revision_follow_up, decision_id, action_id}, state) do
    {:noreply, start_revision_follow_up_task(state, :resolve, decision_id, action_id)}
  end

  def handle_info({:revision_follow_up_result, operation, decision_id, action_id, :ok}, state) do
    {:noreply, clear_revision_follow_up_inflight(state, operation, {decision_id, action_id})}
  end

  def handle_info({:revision_follow_up_result, operation, decision_id, action_id, {:error, reason}}, state) do
    key = {decision_id, action_id}

    if retry_revision_follow_up?(state, operation, decision_id, action_id) do
      Logger.warning(
        "aiur_decision_store phase=revision_follow_up_#{operation}_failed " <>
          "decision_id=#{decision_id} action_id=#{action_id} reason=#{inspect(reason)}"
      )

      message = revision_follow_up_message(operation, decision_id, action_id)
      Process.send_after(self(), message, state.reconcile_delay_ms)
      {:noreply, state}
    else
      {:noreply, clear_revision_follow_up_inflight(state, operation, key)}
    end
  end

  defp reconcile_scheduled_decision(%{decision_id: decision_id} = fence, state) do
    case fetch_decision(state, decision_id) do
      {:ok, current} ->
        dispatch_current? = dispatch_fence_current?(fence, current, :normal)
        reconcile_queue? = dispatch_current? and fence.request_version == current.version
        reconcile_decision(current, state, dispatch_current?, reconcile_queue?)

      {:error, _reason} ->
        state
    end
  end

  defp reconcile_decision(decision, state, dispatch_current?, reconcile_queue?) do
    state = ensure_revision_follow_up_required(state, decision)
    current = Map.fetch!(state.current, decision.decision_id)
    state = ensure_superseded_revision_follow_ups(state, current)
    current = Map.fetch!(state.current, decision.decision_id)
    state = schedule_revision_follow_up_work(state, current)

    state = if dispatch_current?, do: maybe_schedule_after_answer(state, current, false), else: state

    # Request enrichment may advance the version without changing delivery state.
    # Pending first delivery can follow it; queued reconciliation cannot.
    if reconcile_queue?, do: maybe_schedule_queue_reconciliation(state, current), else: state
  end

  defp schedule_revision_follow_up_work(state, decision) do
    Enum.reduce(decision.revision_follow_ups, state, fn {action_id, follow_up}, state_acc ->
      if is_nil(follow_up.handled_at),
        do: maybe_schedule_revision_follow_up_projection(state_acc, decision, action_id),
        else: maybe_schedule_revision_follow_up_resolution(state_acc, decision, action_id)
    end)
  end

  defp maybe_schedule_revision_follow_up_projection(state, decision, action_id) do
    key = {decision.decision_id, action_id}

    if MapSet.member?(state.projecting_revision_follow_ups, key) do
      state
    else
      send(self(), {:project_revision_follow_up, decision.decision_id, action_id})
      %{state | projecting_revision_follow_ups: MapSet.put(state.projecting_revision_follow_ups, key)}
    end
  end

  defp maybe_schedule_revision_follow_up_resolution(state, decision, action_id) do
    key = {decision.decision_id, action_id}

    if MapSet.member?(state.resolving_revision_follow_ups, key) do
      state
    else
      send(self(), {:resolve_revision_follow_up, decision.decision_id, action_id})
      %{state | resolving_revision_follow_ups: MapSet.put(state.resolving_revision_follow_ups, key)}
    end
  end

  defp start_revision_follow_up_task(state, operation, decision_id, action_id) do
    case fetch_decision(state, decision_id) do
      {:ok, decision} ->
        do_start_revision_follow_up_task(state, operation, decision, action_id)

      {:error, _reason} ->
        clear_revision_follow_up_inflight(state, operation, {decision_id, action_id})
    end
  end

  defp do_start_revision_follow_up_task(state, operation, decision, action_id) do
    owner = self()
    callback = revision_follow_up_callback(state, operation)

    task = fn ->
      result = safe_revision_follow_up_call(callback, decision, action_id)
      send(owner, {:revision_follow_up_result, operation, decision.decision_id, action_id, result})
    end

    {:ok, _pid} = Task.start(task)
    state
  end

  defp revision_follow_up_callback(state, :project), do: state.revision_follow_up_projector
  defp revision_follow_up_callback(state, :resolve), do: state.revision_follow_up_resolver

  defp safe_revision_follow_up_call(callback, decision, action_id) do
    case callback.(decision, action_id) do
      :ok -> :ok
      {:error, _reason} = error -> error
      other -> {:error, {:invalid_result, other}}
    end
  rescue
    error -> {:error, {:callback_crashed, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:callback_crashed, {kind, reason}}}
  end

  defp clear_revision_follow_up_inflight(state, :project, key) do
    %{state | projecting_revision_follow_ups: MapSet.delete(state.projecting_revision_follow_ups, key)}
  end

  defp clear_revision_follow_up_inflight(state, :resolve, key) do
    %{state | resolving_revision_follow_ups: MapSet.delete(state.resolving_revision_follow_ups, key)}
  end

  defp retry_revision_follow_up?(state, operation, decision_id, action_id) do
    case Map.get(state.current, decision_id) do
      %Decision{} = decision ->
        case Map.get(decision.revision_follow_ups, action_id) do
          %{handled_at: nil} -> operation == :project
          %{handled_at: %DateTime{}} -> operation == :resolve
          nil -> false
        end

      nil ->
        false
    end
  end

  defp revision_follow_up_message(:project, decision_id, action_id),
    do: {:project_revision_follow_up, decision_id, action_id}

  defp revision_follow_up_message(:resolve, decision_id, action_id),
    do: {:resolve_revision_follow_up, decision_id, action_id}

  defp maybe_schedule_after_answer(state, %Decision{} = decision, retry_failed?) do
    active_answer = Decision.active_answer(decision)

    cond do
      not state.writable? ->
        state

      not dispatchable?(decision, retry_failed?) ->
        state

      is_nil(active_answer) or MapSet.member?(state.dispatching, active_answer.action_id) ->
        state

      true ->
        schedule_dispatch(state, decision, retry_failed?, state.dispatch_delay_ms)
        state
    end
  end

  defp maybe_schedule_queue_reconciliation(state, %Decision{} = decision) do
    active_answer = Decision.active_answer(decision)

    cond do
      not state.writable? ->
        state

      not queue_reconcilable?(decision) ->
        state

      is_nil(active_answer) or MapSet.member?(state.dispatching, active_answer.action_id) ->
        state

      true ->
        schedule_dispatch_work(state, {:reconcile_queue_action, dispatch_fence(decision)}, 0)
        state
    end
  end

  defp schedule_dispatch(state, decision, retry_failed?, delay_ms) do
    schedule_dispatch_work(state, {:dispatch_action, dispatch_fence(decision), retry_failed?}, delay_ms)
  end

  defp schedule_dispatch_work(state, message, delay_ms) do
    state.dispatch_scheduler.(self(), message, delay_ms)
  end

  defp dispatch_fences(state) do
    Enum.map(state.current, fn {_decision_id, decision} -> dispatch_fence(decision) end)
  end

  defp dispatch_fence(decision) do
    %{
      decision_id: decision.decision_id,
      request_version: decision.version,
      lifecycle: dispatch_lifecycle(decision)
    }
  end

  defp dispatch_lifecycle(decision) do
    {
      dispatch_answer_identity(decision),
      decision.active_action_id,
      decision.revision_sequence,
      decision.revision_result,
      decision.decision_status,
      decision.delivery_status,
      dispatch_attempt_identity(decision)
    }
  end

  defp dispatch_attempt_identity(decision) do
    case List.last(Decision.active_dispatch_attempts(decision)) do
      nil ->
        nil

      attempt ->
        {
          attempt.action_id,
          attempt.attempt_id,
          attempt.queue_item_id,
          attempt.run_id,
          attempt.status,
          attempt.failure_reason_class
        }
    end
  end

  defp dispatch_answer_identity(decision) do
    case Decision.active_answer(decision) do
      nil -> nil
      answer -> {answer.action_id, answer.decision_version, answer.content_hash}
    end
  end

  defp dispatch_fence_current?(fence, decision, mode) do
    lifecycle_current? =
      fence.decision_id == decision.decision_id and
        fence.lifecycle == dispatch_lifecycle(decision)

    lifecycle_current? and
      (mode != :reconcile_queue or fence.request_version == decision.version)
  end

  defp maybe_reconcile_lifecycle_append(state, %{decision_id: decision_id} = fence, action_id) do
    with {:ok, decision} <- fetch_decision(state, decision_id),
         true <- dispatch_fence_current?(fence, decision, :recover_append),
         %DecisionAnswer{action_id: ^action_id} <- Decision.active_answer(decision),
         true <- lifecycle_append_failed?(state, action_id) do
      maybe_start_dispatch(state, fence, true, :recover_append)
    else
      _other -> state
    end
  end

  defp maybe_start_dispatch(state, %{decision_id: decision_id} = fence, retry_failed?, mode \\ :normal) do
    with true <- state.writable?,
         {:ok, decision} <- fetch_decision(state, decision_id),
         true <- dispatch_fence_current?(fence, decision, mode),
         %DecisionAnswer{} = answer <- Decision.active_answer(decision),
         false <- MapSet.member?(state.dispatching_decisions, decision_id),
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

      {:ok, _pid} = Task.start(task)

      %{
        state
        | dispatching: MapSet.put(state.dispatching, answer.action_id),
          dispatching_decisions: MapSet.put(state.dispatching_decisions, decision_id)
      }
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

  defp maybe_schedule_superseding_dispatch(state, decision_id, completed_action_id) do
    case fetch_decision(state, decision_id) do
      {:ok, %Decision{active_action_id: active_action_id} = decision}
      when is_binary(active_action_id) and active_action_id != completed_action_id ->
        maybe_schedule_after_answer(state, decision, false)

      _other ->
        state
    end
  end

  defp settle_dispatch(state, decision_id, action_id, attempt_id, result) do
    with true <- state.writable?,
         {:ok, decision} <- fetch_decision(state, decision_id),
         %DecisionAnswer{action_id: ^action_id} <- Decision.answer_for_action(decision, action_id) do
      case result do
        {:ok, %{status: status, item: %{id: queue_item_id} = item}}
        when status in [:accepted, :duplicate, :retried] and is_integer(queue_item_id) and queue_item_id > 0 ->
          settle_queue_result(state, decision, action_id, attempt_id, status, item)

        {:no_longer_applicable, reason} ->
          settle_revision_no_longer_applicable(state, decision, action_id, reason)

        {:error, reason} ->
          settle_dispatch_failure(state, decision, action_id, attempt_id, reason)

        _other ->
          settle_dispatch_failure(state, decision, action_id, attempt_id, :invalid_dispatch_result)
      end
    else
      _other -> state
    end
  end

  defp settle_revision_no_longer_applicable(state, decision, action_id, reason) do
    if decision.active_action_id == action_id and revision_action?(decision, action_id) do
      data = %{action_id: action_id, reason_class: revision_non_applicability_reason(reason)}

      case build_and_persist_event(:revision_no_longer_applicable, decision, data, DateTime.utc_now(), state) do
        {:ok, next_state, updated} ->
          ensure_revision_follow_up_required(next_state, updated)

        {:error, append_reason} ->
          recover_background_append(state, decision, action_id, :revision_no_longer_applicable, append_reason)
      end
    else
      state
    end
  end

  defp revision_non_applicability_reason(:missing), do: "target_missing"
  defp revision_non_applicability_reason({:terminal, _state}), do: "target_terminal"
  defp revision_non_applicability_reason(_reason), do: "target_no_longer_applicable"

  defp ensure_revision_follow_up_required(
         state,
         %Decision{revision_result: :no_longer_applicable, active_action_id: action_id} = decision
       ) do
    case Map.get(decision.revision_follow_ups, action_id) do
      nil -> persist_revision_follow_up_required(state, decision, action_id)
      _follow_up -> maybe_schedule_revision_follow_up_projection(state, decision, action_id)
    end
  end

  defp ensure_revision_follow_up_required(state, _decision), do: state

  defp persist_revision_follow_up_required(state, decision, action_id) do
    revision = Enum.find(decision.revisions, &(&1.action_id == action_id))

    data = %{
      action_id: action_id,
      slug: DecisionRevision.follow_up_slug(revision),
      question: DecisionRevision.follow_up_question(revision, decision.ticket.identifier)
    }

    case build_and_persist_event(:follow_up_required, decision, data, DateTime.utc_now(), state) do
      {:ok, next_state, updated} -> maybe_schedule_revision_follow_up_projection(next_state, updated, action_id)
      {:error, reason} -> fatal_lifecycle_append_failed(state, :follow_up_required, reason)
    end
  end

  defp ensure_superseded_revision_follow_ups(state, decision) do
    decision.revision_follow_ups
    |> Enum.filter(fn {action_id, follow_up} ->
      action_id != decision.active_action_id and is_nil(follow_up.handled_at)
    end)
    |> Enum.reduce(state, fn {action_id, follow_up}, state_acc ->
      current = Map.fetch!(state_acc.current, decision.decision_id)

      data = %{
        action_id: action_id,
        slug: follow_up.slug,
        actor: @system_follow_up_actor,
        detail: "Superseded by revision #{decision.active_action_id}"
      }

      case build_and_persist_event(:follow_up_handled, current, data, DateTime.utc_now(), state_acc) do
        {:ok, next_state, updated} -> maybe_schedule_revision_follow_up_resolution(next_state, updated, action_id)
        {:error, reason} -> fatal_lifecycle_append_failed(state_acc, :follow_up_handled, reason)
      end
    end)
  end

  defp settle_queue_result(state, decision, action_id, attempt_id, :retried, item) do
    restored_attempt_id = item_attempt_id(item) || attempt_id

    case find_queue_attempt(decision, restored_attempt_id, item.id) do
      nil ->
        data = %{
          action_id: action_id,
          attempt_id: restored_attempt_id,
          queue_item_id: item.id
        }

        case build_and_persist_event(:restored, decision, data, DateTime.utc_now(), state) do
          {:ok, next_state, updated} ->
            next_state
            |> maybe_project_delivery_attention(decision, updated, :restored, action_id)
            |> then(&%{&1 | retry_counts: Map.delete(&1.retry_counts, action_id)})

          {:error, reason} ->
            recover_background_append(state, decision, action_id, :restored, reason)
        end

      attempt ->
        reconcile_existing_queue_snapshot(state, decision, attempt, item)
    end
  end

  defp settle_queue_result(state, decision, action_id, attempt_id, :duplicate, item) do
    accepted_attempt_id = item_attempt_id(item) || attempt_id

    case find_queue_attempt(decision, accepted_attempt_id, item.id) do
      nil -> settle_queue_acceptance(state, decision, action_id, accepted_attempt_id, item)
      attempt -> reconcile_existing_queue_snapshot(state, decision, attempt, item)
    end
  end

  defp settle_queue_result(state, decision, action_id, attempt_id, _status, item) do
    accepted_attempt_id = item_attempt_id(item) || attempt_id

    case find_queue_attempt(decision, accepted_attempt_id, item.id) do
      nil -> settle_queue_acceptance(state, decision, action_id, accepted_attempt_id, item)
      attempt -> reconcile_existing_queue_snapshot(state, decision, attempt, item)
    end
  end

  defp item_attempt_id(item) do
    case Map.get(item, :correlation) do
      correlation when is_map(correlation) -> correlation_value(correlation, :attempt_id)
      _other -> nil
    end
  end

  defp find_queue_attempt(decision, attempt_id, queue_item_id) do
    Enum.find(decision.dispatch_attempts, fn attempt ->
      attempt.attempt_id == attempt_id and attempt.queue_item_id == queue_item_id
    end)
  end

  defp revision_action?(decision, action_id) do
    Enum.any?(decision.revisions, &(&1.action_id == action_id))
  end

  defp settle_queue_acceptance(state, decision, action_id, attempt_id, item) do
    data = %{action_id: action_id, attempt_id: attempt_id, queue_item_id: item.id}
    event_type = if revision_action?(decision, action_id), do: :revision_dispatched, else: :dispatch_queued

    case build_and_persist_event(event_type, decision, data, DateTime.utc_now(), state) do
      {:ok, next_state, updated} ->
        next_state
        |> maybe_project_delivery_attention(decision, updated, event_type, action_id)
        |> then(&%{&1 | retry_counts: Map.delete(&1.retry_counts, action_id)})
        |> reconcile_queue_snapshot(updated, item, data)

      {:error, reason} ->
        recover_background_append(state, decision, action_id, event_type, reason)
    end
  end

  defp reconcile_queue_snapshot(%{writable?: false} = state, _decision, _item, _data), do: state

  defp reconcile_queue_snapshot(state, decision, %{status: :delivered}, data) do
    persist_snapshot_transitions(state, decision, data, [:delivered])
  end

  defp reconcile_queue_snapshot(state, decision, %{status: :consumed}, data) do
    persist_snapshot_transitions(state, decision, data, [:delivered, :consumed])
  end

  defp reconcile_queue_snapshot(state, decision, %{status: :failed} = item, data) do
    reason_class = item |> Map.get(:failure_reason) |> transport_failure_class()
    persist_snapshot_transitions(state, decision, Map.put(data, :reason_class, reason_class), [:failed])
  end

  defp reconcile_queue_snapshot(state, _decision, _item, _data), do: state

  defp reconcile_existing_queue_snapshot(state, decision, attempt, item) do
    data = %{
      action_id: attempt.action_id,
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
          next_state = maybe_project_delivery_attention(next_state, decision_acc, updated, type, data.action_id)
          {:cont, {next_state, updated}}

        {:error, reason} ->
          {:halt, {recover_background_append(state_acc, decision_acc, data.action_id, type, reason), decision_acc}}
      end
    end)
    |> elem(0)
  end

  defp settle_dispatch_failure(state, decision, action_id, attempt_id, reason) do
    reason_class = dispatch_failure_class(reason)
    data = %{action_id: action_id, attempt_id: attempt_id, queue_item_id: nil, reason_class: reason_class}

    case build_and_persist_event(:failed, decision, data, DateTime.utc_now(), state) do
      {:ok, next_state, updated} ->
        next_state
        |> maybe_project_delivery_attention(decision, updated, :failed, action_id)
        |> maybe_retry_transient(updated, action_id, reason_class)

      {:error, append_reason} ->
        recover_background_append(state, decision, action_id, :failed, append_reason)
    end
  end

  defp recover_background_append(state, decision, action_id, type, reason) do
    state
    |> lifecycle_append_failed(decision, action_id, type, reason)
    |> schedule_append_retry(decision, action_id)
  end

  defp lifecycle_append_failed(state, decision, action_id, type, reason) do
    Logger.error("aiur_decision_store phase=lifecycle_append_failed type=#{type} reason=#{inspect(reason)}")

    failures = Map.get(state, :lifecycle_append_failures, MapSet.new())

    unless MapSet.member?(failures, action_id) do
      _ =
        Alerts.emit_custom(
          lifecycle_append_failure_topic(decision, action_id),
          "Decision delivery persistence is temporarily unavailable for #{decision.decision_id}.",
          issue: decision.ticket.identifier,
          reason:
            "Decision #{decision.decision_id} action #{action_id} could not record #{type}; " <>
              "retry is bounded and the store remains available.",
          needs_attention: true,
          severity: "warning"
        )
    end

    %{state | lifecycle_append_failures: MapSet.put(failures, action_id)}
  end

  defp schedule_append_retry(state, decision, action_id) do
    retry_counts = Map.get(state, :append_retry_counts, %{})
    retry_count = Map.get(retry_counts, action_id, 0)
    next_state = %{state | append_retry_counts: Map.put(retry_counts, action_id, retry_count + 1)}

    case Enum.at(state.retry_delays_ms, retry_count) do
      delay when is_integer(delay) and delay >= 0 ->
        schedule_append_reconciliation(state, decision, action_id, delay)
        next_state

      _other ->
        next_state
    end
  end

  defp resolve_lifecycle_append_failure(state, decision, action_id) when is_binary(action_id) do
    failures = Map.get(state, :lifecycle_append_failures, MapSet.new())

    if MapSet.member?(failures, action_id) do
      _ =
        Alerts.emit_custom(
          lifecycle_append_failure_topic(decision, action_id) <> ".resolved",
          "Decision delivery persistence recovered for #{decision.decision_id}.",
          issue: decision.ticket.identifier,
          reason:
            "Decision #{decision.decision_id} action #{action_id} " <>
              "resumed durable lifecycle recording.",
          needs_attention: false,
          severity: "info"
        )

      %{
        state
        | lifecycle_append_failures: MapSet.delete(failures, action_id),
          append_retry_counts: Map.delete(Map.get(state, :append_retry_counts, %{}), action_id)
      }
    else
      state
    end
  end

  defp schedule_append_reconciliation(state, decision, action_id, delay_ms) do
    schedule_dispatch_work(state, {:reconcile_lifecycle_append, dispatch_fence(decision), action_id}, delay_ms)
  end

  defp lifecycle_append_failure_topic(decision, action_id) do
    action_slug = String.replace(action_id, "_", "-")
    "ticket.#{decision.ticket.identifier}.agent.attention.decision-lifecycle-persistence-#{action_slug}"
  end

  defp fatal_lifecycle_append_failed(state, type, reason) do
    Logger.error("aiur_decision_store phase=lifecycle_append_failed type=#{type} reason=#{inspect(reason)}")
    %{state | writable?: false, health: {:lifecycle_append_failed, type, reason}}
  end

  defp maybe_retry_transient(state, decision, action_id, reason_class) do
    if decision.active_action_id == action_id and transient_failure?(decision, reason_class) do
      schedule_transient_retry(state, decision, action_id)
    else
      state
    end
  end

  defp schedule_transient_retry(state, decision, action_id) do
    retry_count = Map.get(state.retry_counts, action_id, 0)
    next_state = %{state | retry_counts: Map.put(state.retry_counts, action_id, retry_count + 1)}

    case Enum.at(state.retry_delays_ms, retry_count) do
      delay when is_integer(delay) and delay >= 0 ->
        schedule_dispatch(state, decision, false, delay)
        next_state

      _other ->
        next_state
    end
  end

  defp transient_failure?(%Decision{revision_sequence: sequence}, reason_class) when sequence > 0,
    do: reason_class in @revision_transient_failure_classes

  defp transient_failure?(%Decision{}, reason_class), do: reason_class in @transient_failure_classes

  defp dispatch_failure_class(:unavailable), do: "orchestrator_unavailable"
  defp dispatch_failure_class(:timeout), do: "orchestrator_timeout"
  defp dispatch_failure_class(:no_running_agent), do: "target_agent_unavailable"
  defp dispatch_failure_class(:task_unavailable), do: "dispatch_task_unavailable"
  defp dispatch_failure_class(:dispatcher_crashed), do: "dispatcher_crashed"
  defp dispatch_failure_class({:target_revalidation_failed, _reason}), do: "target_revalidation_failed"
  defp dispatch_failure_class(_reason), do: "dispatch_rejected"

  defp next_attempt_id(decision) do
    active_answer = Decision.active_answer(decision)
    "#{active_answer.action_id}:#{length(Decision.active_dispatch_attempts(decision)) + 1}"
  end

  defp dispatch_allowed?(decision, retry_failed?, :normal), do: dispatchable?(decision, retry_failed?)
  defp dispatch_allowed?(decision, _retry_failed?, :reconcile_queue), do: queue_reconcilable?(decision)
  defp dispatch_allowed?(%Decision{decision_status: status}, _retry_failed?, :recover_append), do: status != :resolved

  defp queue_reconcilable?(%Decision{decision_status: :decided} = decision) do
    attempts = Decision.active_dispatch_attempts(decision)
    match?(%{status: status} when status in [:queued, :restored], List.last(attempts))
  end

  defp queue_reconcilable?(%Decision{}), do: false

  defp decision_for_dispatch(state, decision) do
    active_answer = Decision.active_answer(decision)

    case request_version(state, decision.decision_id, active_answer.decision_version) do
      nil ->
        decision

      addressed ->
        %{
          addressed
          | answer: decision.answer,
            active_action_id: decision.active_action_id,
            revision_sequence: decision.revision_sequence,
            revisions: decision.revisions,
            revision_result: decision.revision_result,
            revision_outcomes: decision.revision_outcomes,
            revision_follow_ups: decision.revision_follow_ups,
            decision_status: decision.decision_status,
            delivery_status: decision.delivery_status,
            dispatch_attempts: decision.dispatch_attempts,
            acknowledgement: decision.acknowledgement,
            resolution: decision.resolution,
            acknowledgements: decision.acknowledgements,
            resolutions: decision.resolutions
        }
    end
  end

  defp dispatchable?(%Decision{} = decision, _retry_failed?) when is_nil(decision.answer), do: false
  defp dispatchable?(%Decision{decision_status: :resolved}, _retry_failed?), do: false
  defp dispatchable?(%Decision{revision_result: :no_longer_applicable}, _retry_failed?), do: false

  defp dispatchable?(%Decision{} = decision, retry_failed?) do
    case List.last(Decision.active_dispatch_attempts(decision)) do
      nil -> true
      %{status: :failed} when retry_failed? -> true
      %{status: :failed, failure_reason_class: reason} -> transient_failure?(decision, reason)
      _other -> false
    end
  end

  defp validate_explicit_retry(state, decision_id, action_id) do
    with {:ok, decision} <- fetch_decision(state, decision_id),
         %DecisionAnswer{action_id: ^action_id} <- Decision.active_answer(decision),
         :ok <- require_answerable(decision),
         true <- retryable_dispatch?(state, decision, action_id) do
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

  defp retryable_dispatch?(state, decision, action_id) do
    match?(%{status: :failed}, List.last(Decision.active_dispatch_attempts(decision))) or
      lifecycle_append_failed?(state, action_id)
  end

  defp lifecycle_append_failed?(state, action_id) do
    MapSet.member?(Map.get(state, :lifecycle_append_failures, MapSet.new()), action_id)
  end

  defp notify(decision, event_id, state) do
    topic = "ticket.#{decision.ticket.identifier}.agent.decision.requested"
    payload = DecisionProjection.to_json_safe(decision)

    try do
      Publisher.publish_persisted(topic, payload, event_id, digest_source: :orchestrator)
    rescue
      error -> Logger.warning("aiur_decision_store phase=notify_publisher_failed error=#{Exception.message(error)}")
    end

    notify_requested_executor(decision, state, :executor_request_publisher)

    try do
      DecisionPubSub.broadcast_changed(decision.decision_id, decision.version)
    rescue
      error -> Logger.warning("aiur_decision_store phase=notify_pubsub_failed error=#{Exception.message(error)}")
    end

    :ok
  end

  defp notify_requested_executor(decision, state, publisher_key, attempt \\ 0) do
    case state[publisher_key].(decision) do
      {:ok, _id, _subscribers} ->
        :ok

      {:error, reason} ->
        Logger.warning("aiur_decision_store phase=executor_request_notification_failed reason=#{inspect(reason)}")
        schedule_executor_request_retry(decision, state, attempt)
    end
  rescue
    error ->
      Logger.warning("aiur_decision_store phase=executor_request_notification_failed error=#{Exception.message(error)}")
      schedule_executor_request_retry(decision, state, attempt)
  catch
    :exit, reason ->
      Logger.warning("aiur_decision_store phase=executor_request_notification_failed exit=#{inspect(reason)}")
      schedule_executor_request_retry(decision, state, attempt)
  end

  # Bounded exactly like every sibling retry path (`schedule_append_retry`,
  # `schedule_transient_retry`): once the configured delay ladder is exhausted
  # the store gives up rather than reconciling the whole journal forever.
  defp schedule_executor_request_retry(decision, state, attempt) do
    case Enum.at(state.retry_delays_ms, attempt) do
      delay when is_integer(delay) and delay >= 0 ->
        state.dispatch_scheduler.(
          self(),
          {:retry_executor_request_notification, decision.decision_id, decision.version, attempt + 1},
          delay
        )

        :ok

      _exhausted ->
        Logger.warning(
          "aiur_decision_store phase=executor_request_notification_retry_exhausted " <>
            "decision_id=#{decision.decision_id} version=#{decision.version} attempts=#{attempt}"
        )

        :ok
    end
  end

  defp recent_audit_payload(state, records) do
    Enum.reduce(records, %{records: records, contexts: %{}, actions: %{}, revisions: %{}}, fn record, payload ->
      case audit_identity(record) do
        {decision_id, version} ->
          payload
          |> put_audit_context(state, decision_id, version)
          |> put_audit_action(state, decision_id, audit_action_id(record))

        nil ->
          payload
      end
    end)
  end

  defp put_audit_context(payload, state, decision_id, version) do
    case request_version(state, decision_id, version) || Map.get(state.current, decision_id) do
      %Decision{} = decision ->
        context = %{
          version: decision.version,
          ticket: decision.ticket,
          question: decision.question,
          provenance: decision.provenance
        }

        contexts = Map.update(payload.contexts, decision_id, %{version => context}, &Map.put(&1, version, context))
        %{payload | contexts: contexts}

      _other ->
        payload
    end
  end

  defp put_audit_action(payload, _state, _decision_id, nil), do: payload

  defp put_audit_action(payload, state, decision_id, action_id) do
    action =
      state.current
      |> Map.get(decision_id)
      |> case do
        %Decision{answer: %DecisionAnswer{action_id: ^action_id} = answer} -> answer
        %Decision{revisions: revisions} -> Enum.find(revisions, &(&1.action_id == action_id))
        _other -> nil
      end

    case action do
      %DecisionAnswer{} = answer ->
        actions =
          Map.update(payload.actions, decision_id, %{action_id => answer}, &Map.put(&1, action_id, answer))

        %{payload | actions: actions}

      %DecisionRevision{} = revision ->
        actions =
          Map.update(payload.actions, decision_id, %{action_id => revision}, &Map.put(&1, action_id, revision))

        revisions =
          Map.update(payload.revisions, decision_id, %{action_id => revision}, &Map.put(&1, action_id, revision))

        %{payload | actions: actions, revisions: revisions}

      _other ->
        payload
    end
  end

  defp audit_identity(%DecisionEvent{decision_id: decision_id, decision_version: version}),
    do: {decision_id, version}

  defp audit_identity(%Decision{decision_id: decision_id, version: version}), do: {decision_id, version}
  defp audit_identity(_record), do: nil

  defp audit_action_id(%DecisionEvent{data: %DecisionRevision{action_id: action_id}}), do: action_id
  defp audit_action_id(%DecisionEvent{data: %{action_id: action_id}}), do: action_id
  defp audit_action_id(_record), do: nil

  defp remember_recent_audit(records, event), do: Enum.take([event | records], @recent_audit_limit)

  defp build_decision_index(current) do
    current
    |> Map.values()
    |> Enum.map(&recent_decision_sort_key/1)
    |> :gb_sets.from_list()
  end

  defp update_decision_index(index, prior, %Decision{} = decision) do
    updated_index = delete_decision_index(index, prior)
    :gb_sets.add(recent_decision_sort_key(decision), updated_index)
  end

  defp delete_decision_index(index, %Decision{} = decision),
    do: :gb_sets.delete_any(recent_decision_sort_key(decision), index)

  defp delete_decision_index(index, _prior), do: index

  defp take_indexed_decisions(index, current, limit),
    do: take_indexed_decisions(:gb_sets.iterator(index), current, limit, [])

  defp take_indexed_decisions(_iterator, _current, 0, decisions), do: Enum.reverse(decisions)

  defp take_indexed_decisions(iterator, current, remaining, decisions) do
    case :gb_sets.next(iterator) do
      {{_resolved, _non_blocking, _urgency, _created_at, decision_id}, next_iterator} ->
        take_indexed_decisions(
          next_iterator,
          current,
          remaining - 1,
          [Map.fetch!(current, decision_id) | decisions]
        )

      :none ->
        Enum.reverse(decisions)
    end
  end

  defp recent_decision_sort_key(%Decision{} = decision) do
    {
      decision.decision_status in [:expired, :dismissed, :resolved],
      not decision.blocking,
      -urgency_rank(decision.urgency),
      -datetime_sort_key(decision.created_at),
      decision.decision_id
    }
  end

  defp urgency_rank(:critical), do: 3
  defp urgency_rank(:high), do: 2
  defp urgency_rank(:normal), do: 1
  defp urgency_rank(_urgency), do: 0

  defp datetime_sort_key(%DateTime{} = datetime), do: DateTime.to_unix(datetime, :microsecond)
  defp datetime_sort_key(_datetime), do: 0

  defp reverse_histories(histories) do
    Map.new(histories, fn {decision_id, history} -> {decision_id, Enum.reverse(history)} end)
  end

  defp legacy_question_version_limit_reached?(decision, state) do
    decision.version >= state.legacy_question_version_limit
  end

  defp legacy_question_version_limit(opts) do
    case Keyword.get(opts, :legacy_question_version_limit, @default_legacy_question_version_limit) do
      limit when is_integer(limit) and limit > 0 -> limit
      _invalid -> @default_legacy_question_version_limit
    end
  end

  defp valid_legacy_page?(offset, limit)
       when offset >= 0 and offset <= @maximum_legacy_page_offset and limit >= 1 and
              limit <= @maximum_legacy_page_limit,
       do: :ok

  defp valid_legacy_page?(_offset, _limit), do: {:error, :invalid_query}

  defp legacy_query_params(query) do
    query
    |> Map.drop([:limit, "limit", :ordering])
    |> Map.put(:limit, 1)
  end
end
