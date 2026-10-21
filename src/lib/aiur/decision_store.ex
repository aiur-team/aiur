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

  On boot, replays the canonical `decisions.ndjson` audit stream via `Aiur.Journal`,
  rebuilds the projection, and repairs `decisions.json` if it doesn't already match.
  Well-formed unfamiliar records remain intact across version skew via `Aiur.DecisionEvent.Unrecognized`.
  Interior corruption puts the store into read-only mode: reads serve the validated prefix,
  every mutation is rejected, and one Executor alert is emitted — never silently skipped.

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

  alias Aiur.Decision
  alias Aiur.DecisionEvent
  alias Aiur.DecisionStore.Audit
  alias Aiur.DecisionStore.Boot
  alias Aiur.DecisionStore.Calls
  alias Aiur.DecisionStore.FailureAttention
  alias Aiur.DecisionStore.Index
  alias Aiur.DecisionStore.Info
  alias Aiur.DecisionStore.Persistence

  @request_timeout 60_000
  @recent_decision_limit 50

  @type accept_result :: %{status: :accepted | :duplicate, decision: Decision.t()}

  @doc """
  Starts the store.

  Only the application singleton may use the configured default state
  directory. Every other instance must receive its own `:state_dir` so it
  cannot contend with the application's durable decision audit stream.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    with :ok <- Boot.validate_start_options(opts) do
      GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
    end
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

  @doc "Durably lets the Executor reclassify a human-required decision as answerable, with rationale."
  @spec reclassify_authority(String.t(), map(), GenServer.server(), timeout()) :: {:ok, map()} | {:error, term()}
  def reclassify_authority(decision_id, payload, server \\ __MODULE__, timeout \\ @request_timeout)
      when is_binary(decision_id) and is_map(payload) do
    GenServer.call(server, {:reclassify_authority, decision_id, payload}, timeout)
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

  @doc """
  Durably retires a Command whose question is moot — its ticket closed, its
  originating agent is gone, or the operator changed direction before the
  answer reached any agent.

  Unlike `dismiss`, this is the disposition for a question that is void, so a
  blocking Command may be retired here: a closed ticket or a gone agent makes
  the block moot too, and a moot record delivers nothing to a waiting agent.
  An open or deferred Command is retired with no answer, so it stays
  distinguishable in the durable record from a real decision.

  A `:decided` Command can also be mooted while its answer is undelivered and
  not yet handed to a worker (`Aiur.Decision.delivered?/1` and
  `Aiur.Decision.send_in_flight?/1` are false). The recorded answer stays in the
  audit trail, but a mooted Command is never dispatched and a queued copy is
  refused at the delivery gate (#2711). Refusals: `{:conflict,
  :answer_delivered}`, `{:conflict, :answer_in_flight}`, and for an Executor
  actor an `:executor_scope` error unless an Executor recorded the answer or
  could have recorded it. A payload `expected_version` must match the current
  version.

  `opts[:actor]` is trusted runtime identity and is attributed in the event.
  `payload` carries a bounded `reason_class` (required) and an optional
  free-text `reason`/`detail` explaining why it was voided.
  """
  @spec moot(String.t(), map(), keyword(), GenServer.server(), timeout()) ::
          {:ok, map()} | {:error, term()}
  def moot(decision_id, payload, opts \\ [], server \\ __MODULE__, timeout \\ @request_timeout)
      when is_binary(decision_id) and is_map(payload) and is_list(opts) do
    GenServer.call(server, {:moot, decision_id, payload, opts}, timeout)
  end

  @doc """
  Durably replaces the undelivered answer of a `:decided` Command with a new
  answer (#2711).

  The new answer is recorded as an ordered revision of the active action, so
  the replaced answer stays in the audit trail. Only the newest answer is
  dispatched, and a queued copy of a replaced answer is refused at the
  delivery gate. The revision correlation (`expected_action_id`,
  `expected_revision_sequence`) is taken from the current record, so the
  caller supplies only the answer fields, `expected_version`, `rationale` and
  `idempotency_key`. A retry with the same idempotency key replays the
  recorded revision.

  Refusals: `{:conflict, :answer_delivered}` once any answer reached the
  agent, `{:conflict, :answer_in_flight}` once the delivery gate handed an
  answer to a worker, `{:not_decided, status}` for a Command with no answer yet (answer it
  instead), and `{:conflict, status}` for a retired Command.
  """
  @spec supersede(String.t(), map(), keyword(), GenServer.server(), timeout()) ::
          {:ok, map()} | {:error, term()}
  def supersede(decision_id, payload, opts \\ [], server \\ __MODULE__, timeout \\ @request_timeout)
      when is_binary(decision_id) and is_map(payload) and is_list(opts) do
    GenServer.call(server, {:supersede, decision_id, payload, opts}, timeout)
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

  @doc """
  Redelivers a ticket's undelivered answers to the worker that just started for
  it (#2713).

  An agent that files a blocking Command ends its run, so an answer recorded
  later has no worker to reach: the dispatch fails `target_agent_unavailable`
  and the bounded retry ladder is spent within seconds. The answer itself is
  durable in this store. The Orchestrator calls this when it spawns a worker
  for the ticket, and each `:decided` Command of that ticket whose newest
  (active) answer failed delivery and never reached an agent is dispatched
  again, with a fresh retry ladder. The new worker then receives the answer
  through its queue.

  Delivery stays exactly once: an answer with provider-confirmed delivery, an
  answer that is queued or in flight, and a Command that is no longer
  `:decided` (mooted, acknowledged or resolved) are skipped. Only the active
  answer is dispatched, so an answer replaced by a revision is never
  redelivered. The call is a cast, so a spawn never waits on this store.
  """
  @spec deliver_pending_answers(String.t(), GenServer.server()) :: :ok
  def deliver_pending_answers(ticket_identifier, server \\ __MODULE__) when is_binary(ticket_identifier) do
    GenServer.cast(server, {:deliver_pending_answers, ticket_identifier})
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

  @doc false
  @spec await_failure_attention_reprojection(GenServer.server()) :: :ok
  def await_failure_attention_reprojection(server \\ __MODULE__) do
    GenServer.call(server, :await_failure_attention_reprojection, @request_timeout)
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

  @doc """
  Returns the set of ticket identifiers that currently have an open blocking
  Command, from one serialized store snapshot.

  A Decision gates dispatch when it is both `blocking` and still open or
  deferred (the operator has not chosen the next action, so dispatching the
  ticket would duplicate or contradict that pending choice — #1965). Internal
  delivery/persistence alerts are deliberately excluded, mirroring
  `Aiur.DecisionStore.RetainedIndex.operator_command?/1`, so an operational
  failure notice never becomes a second operator-facing block.

  Fail-closed callers treat `{:error, :store_unavailable}` as *unknown* and
  hold dispatch: an open blocking Command is indistinguishable from an empty
  store when the store cannot be read.
  """
  @spec blocked_ticket_ids(GenServer.server()) ::
          {:ok, MapSet.t(String.t())} | {:error, :store_unavailable}
  def blocked_ticket_ids(server \\ __MODULE__) do
    GenServer.call(server, :blocked_ticket_ids)
  catch
    :exit, _reason -> {:error, :store_unavailable}
  end

  @doc """
  Returns the ids of the open blocking Commands that gate dispatch for any of
  `ticket_identifiers`, by the same rule as `blocked_ticket_ids/1`.

  The operator resume path uses it to name the Decision that holds a ticket
  instead of refusing with a bare reason (#2699). It runs inside an operator
  control call, so the default timeout is short: a slow store degrades the
  refusal to "store unavailable" rather than timing out the whole resume.
  """
  @spec open_blocking_decision_ids([String.t()], GenServer.server(), timeout()) ::
          {:ok, [String.t()]} | {:error, :store_unavailable}
  def open_blocking_decision_ids(ticket_identifiers, server \\ __MODULE__, timeout \\ 1_000)
      when is_list(ticket_identifiers) do
    GenServer.call(server, {:open_blocking_decision_ids, ticket_identifiers}, timeout)
  catch
    :exit, _reason -> {:error, :store_unavailable}
  end

  @doc "Returns whether an optional agent question, with no open blocking Command, explains a ticket's self-pause."
  @spec nonblocking_question_pause?(String.t(), GenServer.server(), timeout()) ::
          {:ok, boolean()} | {:error, :store_unavailable}
  def nonblocking_question_pause?(ticket_identifier, server \\ __MODULE__, timeout \\ 100)
      when is_binary(ticket_identifier) do
    GenServer.call(server, {:nonblocking_question_pause, ticket_identifier}, timeout)
  catch
    :exit, _reason -> {:error, :store_unavailable}
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
  def recent_audit_history(limit \\ Audit.recent_limit(), server \\ __MODULE__)
      when is_integer(limit) and limit >= 0 do
    GenServer.call(server, {:recent_audit_history, min(limit, Audit.recent_limit())})
  end

  @doc "Complete ordered audit history, including request and lifecycle events."
  @spec audit_history(String.t(), GenServer.server()) ::
          {:ok, [Decision.t() | DecisionEvent.t()]} | {:error, :not_found}
  def audit_history(decision_id, server \\ __MODULE__) when is_binary(decision_id) do
    GenServer.call(server, {:audit_history, decision_id})
  end

  @doc "`:writable`, `{:projection_stale, since}`, or a journal read-only/unavailable reason."
  @spec health(GenServer.server()) :: :writable | tuple()
  def health(server \\ __MODULE__) do
    GenServer.call(server, :health)
  end

  @impl true
  def init(opts) do
    state =
      case Boot.state_dir(opts) do
        {:ok, dir} -> Boot.boot(dir, Keyword.get(opts, :filesystem_sync_fun, &Aiur.Fs.sync_filesystem/0))
        {:error, reason} -> Boot.unavailable_state(nil, {:path_unresolved, reason})
      end
      |> Map.put(:legacy_question_version_limit, Index.legacy_question_version_limit(opts))
      |> Boot.configure_dispatch(opts)
      |> Persistence.repair_projection()

    {:ok, state, {:continue, :schedule_reconciliation}}
  end

  @impl true
  def handle_continue(message, state), do: Boot.handle_continue(message, state)

  @impl true
  def handle_call(message, from, state), do: Calls.handle_call(message, from, state)

  @impl true
  def handle_cast(message, state), do: Calls.handle_cast(message, state)

  @impl true
  def handle_info(message, state), do: Info.handle_info(message, state)

  @doc "Terminal ticket identities among `issues`; see `Aiur.DecisionStore.FailureAttention`."
  defdelegate terminal_identities(issues, terminal_states), to: FailureAttention
end
