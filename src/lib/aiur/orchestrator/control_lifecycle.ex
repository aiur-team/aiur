defmodule Aiur.Orchestrator.ControlLifecycle do
  @moduledoc """
  In-memory projection for correlated per-unit control requests.

  The Orchestrator owns this projection. Worker messages may move a request
  from `:accepted` to `:applied` only when they carry the exact request ID and
  worker generation that were admitted by the control plane.

  The same durable journal also carries bounded daemon lifecycle events
  (`:start` / `:stop` with the invoking process's identity), so a second
  instance or a crash is identifiable after the fact from
  `<repo>.control-lifecycle.json` in the durable repository Executor state.
  """

  alias Aiur.TrackerIdentity

  alias Aiur.Orchestrator.ControlLifecycle.Restore
  import Aiur.Orchestrator.ControlLifecycle.Validation, only: [validate_request: 1, rejection: 2, rejection: 3, rejection_message: 1]

  import Aiur.Orchestrator.ControlLifecycle.Records,
    only: [build_request: 2, same_intent?: 2, supersede_pending: 3, put_new_request: 2, put_record: 2, clear_pending: 3, pending_request?: 2, put_snapshot_request: 2]

  @protocol_version 1
  @default_history_limit 32
  # Daemon lifecycle events (daemon start/stop) are carried in the same durable
  # journal as control requests so a second instance or a crash is identifiable
  # after the fact. The journal is deliberately bounded so an always-on daemon
  # cannot grow it without limit.
  @daemon_kinds [:start, :stop]
  @daemon_event_limit 64
  @pending_statuses [:requested, :accepted]
  @statuses [:requested, :accepted, :applied, :rejected, :expired]
  @actions [:pause, :resume]
  @requesters [:operator, :automatic, :system]
  @expected_statuses [:working, :paused, :sleeping, :completed, :deactivated]
  @rejection_classes [
    :not_found,
    :not_eligible,
    :unsupported,
    :stale_generation,
    :worker_unavailable,
    :already_in_state,
    :control_failed,
    :pause_release_failed,
    :superseded
  ]
  @expiry_reasons [:timeout, :daemon_restart, :generation_loss, :worker_unavailable]

  @type status :: :requested | :accepted | :applied | :rejected | :expired

  @type request :: %{
          protocol_version: pos_integer(),
          request_id: String.t() | pos_integer(),
          issue_id: term(),
          tracker_identity: TrackerIdentity.t(),
          action: :pause | :resume,
          generation: String.t() | pos_integer(),
          expected_status: atom(),
          expected_version: non_neg_integer(),
          requester: atom(),
          status: status(),
          requested_at: DateTime.t(),
          accepted_at: DateTime.t() | nil,
          applied_at: DateTime.t() | nil,
          rejected_at: DateTime.t() | nil,
          rejection: %{class: atom(), message: String.t()} | nil,
          expiry: %{reason: atom(), at: DateTime.t()} | nil
        }

  defstruct protocol_version: @protocol_version,
            created_at: nil,
            history_limit: @default_history_limit,
            records: %{},
            history_ids: %{},
            pending: %{},
            daemon_events: []

  @type daemon_event :: %{
          kind: :start | :stop,
          at: DateTime.t(),
          run_id: String.t(),
          os_pid: String.t(),
          ppid: String.t() | nil,
          ppid_comm: String.t() | nil,
          hostname: String.t() | nil
        }

  @type t :: %__MODULE__{
          protocol_version: pos_integer(),
          created_at: DateTime.t() | nil,
          history_limit: pos_integer(),
          records: %{optional(String.t() | pos_integer()) => request()},
          history_ids: %{optional(term()) => [String.t() | pos_integer()]},
          pending: %{optional(term()) => String.t() | pos_integer()},
          daemon_events: [daemon_event()]
        }

  @doc "Creates an empty, bounded lifecycle projection."
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      created_at: Keyword.get(opts, :now),
      history_limit: positive_integer(Keyword.get(opts, :history_limit, @default_history_limit))
    }
  end

  @doc """
  Admits a control request or returns its existing record for a safe retry.

  A distinct request for the same unit replaces the prior unresolved request;
  the old record remains in history with a structured `:superseded` rejection.
  """
  @spec request(t(), map(), keyword()) ::
          {:ok, request(), t()} | {:duplicate, request(), t()} | {:error, map(), t()}
  def request(lifecycle, attrs, opts \\ [])

  def request(%__MODULE__{} = lifecycle, attrs, opts) when is_map(attrs) do
    now = now!(opts)

    with :ok <- validate_request(attrs),
         :error <- Map.fetch(lifecycle.records, Map.fetch!(attrs, :request_id)) do
      request = build_request(attrs, now)

      lifecycle
      |> supersede_pending(request.issue_id, now)
      |> put_new_request(request)
      |> then(&{:ok, request, &1})
    else
      {:ok, existing} ->
        if same_intent?(existing, attrs) do
          {:duplicate, existing, lifecycle}
        else
          {:error, rejection(:control_failed, "request ID is already bound to a different control intent"), lifecycle}
        end

      {:error, rejection} ->
        {:error, rejection, lifecycle}
    end
  end

  def request(%__MODULE__{} = lifecycle, _attrs, _opts) do
    {:error, rejection(:control_failed, "control request must be a map"), lifecycle}
  end

  @doc "Marks a request as routed to its expected live worker generation."
  @spec accept(t(), String.t() | pos_integer(), String.t() | pos_integer(), keyword()) ::
          {:ok, request(), t()} | {:ignored, t()}
  def accept(%__MODULE__{} = lifecycle, request_id, generation, opts \\ []) do
    now = now!(opts)

    case Map.get(lifecycle.records, request_id) do
      %{status: :requested, generation: ^generation} = request ->
        if pending_request?(lifecycle, request) do
          accepted = %{request | status: :accepted, accepted_at: now}
          {:ok, accepted, put_record(lifecycle, accepted)}
        else
          {:ignored, lifecycle}
        end

      %{status: :accepted, generation: ^generation} = request ->
        if pending_request?(lifecycle, request), do: {:ok, request, lifecycle}, else: {:ignored, lifecycle}

      _ ->
        {:ignored, lifecycle}
    end
  end

  @doc """
  Accepts worker application evidence for a routed request.

  Evidence for another generation, an unresolved request, or a terminal
  request is ignored rather than changing authoritative state.
  """
  @spec apply(t(), String.t() | pos_integer(), String.t() | pos_integer(), keyword()) ::
          {:ok, request(), t()} | {:ignored, t()}
  def apply(%__MODULE__{} = lifecycle, request_id, generation, opts \\ []) do
    now = now!(opts)

    case Map.get(lifecycle.records, request_id) do
      %{status: :accepted, generation: ^generation} = request ->
        if pending_request?(lifecycle, request) do
          applied = %{request | status: :applied, applied_at: now}

          lifecycle =
            lifecycle
            |> put_record(applied)
            |> clear_pending(applied.issue_id, request_id)

          {:ok, applied, lifecycle}
        else
          {:ignored, lifecycle}
        end

      _ ->
        {:ignored, lifecycle}
    end
  end

  @doc "Rejects a still-unresolved request with a stable, redacted class."
  @spec reject(t(), String.t() | pos_integer(), atom(), keyword()) :: {:ok, request(), t()} | {:ignored, t()}
  def reject(lifecycle, request_id, class, opts \\ [])

  def reject(%__MODULE__{} = lifecycle, request_id, class, opts) when class in @rejection_classes do
    now = now!(opts)

    case Map.get(lifecycle.records, request_id) do
      %{status: status} = request when status in @pending_statuses ->
        if pending_request?(lifecycle, request) do
          rejected = %{
            request
            | status: :rejected,
              rejected_at: now,
              rejection: rejection(class, rejection_message(class), opts)
          }

          lifecycle =
            lifecycle
            |> put_record(rejected)
            |> clear_pending(rejected.issue_id, request_id)

          {:ok, rejected, lifecycle}
        else
          {:ignored, lifecycle}
        end

      _ ->
        {:ignored, lifecycle}
    end
  end

  def reject(%__MODULE__{} = lifecycle, _request_id, _class, _opts), do: {:ignored, lifecycle}

  @doc "Expires a still-unresolved request without claiming it applied."
  @spec expire(t(), String.t() | pos_integer(), atom(), keyword()) :: {:ok, request(), t()} | {:ignored, t()}
  def expire(lifecycle, request_id, reason, opts \\ [])

  def expire(%__MODULE__{} = lifecycle, request_id, reason, opts) when is_atom(reason) do
    now = now!(opts)

    case Map.get(lifecycle.records, request_id) do
      %{status: status} = request when status in @pending_statuses ->
        if pending_request?(lifecycle, request) do
          expired = %{request | status: :expired, expiry: %{reason: reason, at: now}}

          lifecycle =
            lifecycle
            |> put_record(expired)
            |> clear_pending(expired.issue_id, request_id)

          {:ok, expired, lifecycle}
        else
          {:ignored, lifecycle}
        end

      _ ->
        {:ignored, lifecycle}
    end
  end

  def expire(%__MODULE__{} = lifecycle, _request_id, _reason, _opts), do: {:ignored, lifecycle}

  @doc "Expires every outstanding request, for example during daemon recovery."
  @spec expire_unresolved(t(), atom(), keyword()) :: {[request()], t()}
  def expire_unresolved(%__MODULE__{} = lifecycle, reason, opts \\ []) when is_atom(reason) do
    now = now!(opts)

    lifecycle.pending
    |> Map.values()
    |> Enum.sort()
    |> Enum.reduce({[], lifecycle}, fn request_id, {expired, state} ->
      case expire(state, request_id, reason, now: now) do
        {:ok, request, state} -> {[request | expired], state}
        {:ignored, state} -> {expired, state}
      end
    end)
    |> then(fn {expired, state} -> {Enum.reverse(expired), state} end)
  end

  @doc "Expires admitted requests whose bounded acknowledgement window elapsed."
  @spec expire_due(t(), non_neg_integer(), keyword()) :: {[request()], t()}
  def expire_due(%__MODULE__{} = lifecycle, timeout_ms, opts \\ []) when is_integer(timeout_ms) and timeout_ms >= 0 do
    now = now!(opts)

    lifecycle.pending
    |> Map.values()
    |> Enum.filter(fn request_id ->
      case Map.get(lifecycle.records, request_id) do
        %{requested_at: %DateTime{} = requested_at} -> DateTime.diff(now, requested_at, :millisecond) > timeout_ms
        _ -> false
      end
    end)
    |> Enum.sort()
    |> Enum.reduce({[], lifecycle}, fn request_id, {expired, state} ->
      case expire(state, request_id, :timeout, now: now) do
        {:ok, request, state} -> {[request | expired], state}
        {:ignored, state} -> {expired, state}
      end
    end)
    |> then(fn {expired, state} -> {Enum.reverse(expired), state} end)
  end

  @doc "Returns a request by its stable request ID."
  @spec get(t(), String.t() | pos_integer()) :: request() | nil
  def get(%__MODULE__{} = lifecycle, request_id), do: Map.get(lifecycle.records, request_id)

  @doc "Returns bounded request history for one local unit identifier."
  @spec history(t(), term()) :: [request()]
  def history(%__MODULE__{} = lifecycle, issue_id) do
    lifecycle.history_ids
    |> Map.get(issue_id, [])
    |> Enum.map(&Map.fetch!(lifecycle.records, &1))
  end

  @doc "Returns the newest retained request for one local unit identifier."
  @spec latest(t(), term()) :: request() | nil
  def latest(%__MODULE__{} = lifecycle, issue_id) do
    with request_id when not is_nil(request_id) <- lifecycle.history_ids |> Map.get(issue_id, []) |> List.last() do
      Map.get(lifecycle.records, request_id)
    end
  end

  @doc "Returns the newest retained request for one unit and action."
  @spec latest_for_action(t(), term(), :pause | :resume) :: request() | nil
  def latest_for_action(%__MODULE__{} = lifecycle, issue_id, action) when action in @actions do
    lifecycle.history_ids
    |> Map.get(issue_id, [])
    |> Enum.reverse()
    |> Enum.find_value(fn request_id ->
      case Map.get(lifecycle.records, request_id) do
        %{action: ^action} = request -> request
        _request -> nil
      end
    end)
  end

  @doc "Builds a row-scoped projection retaining bounded control history."
  @spec snapshot_for(t(), [term()]) :: t()
  def snapshot_for(%__MODULE__{} = lifecycle, issue_ids) when is_list(issue_ids) do
    snapshot = %__MODULE__{
      protocol_version: lifecycle.protocol_version,
      created_at: lifecycle.created_at,
      history_limit: lifecycle.history_limit
    }

    Enum.reduce(issue_ids, snapshot, fn issue_id, acc ->
      acc = Enum.reduce(history(lifecycle, issue_id), acc, &put_snapshot_request(&2, &1))

      case current_pending(lifecycle, issue_id) do
        %{request_id: request_id} -> %{acc | pending: Map.put(acc.pending, issue_id, request_id)}
        nil -> acc
      end
    end)
  end

  @doc "Returns the one unresolved request for a unit, if one exists."
  @spec current_pending(t(), term()) :: request() | nil
  def current_pending(%__MODULE__{} = lifecycle, issue_id) do
    with request_id when not is_nil(request_id) <- Map.get(lifecycle.pending, issue_id),
         request when not is_nil(request) <- Map.get(lifecycle.records, request_id),
         true <- request.status in @pending_statuses do
      request
    else
      _ -> nil
    end
  end

  @doc "Returns a redacted, JSON-safe projection for the durable audit journal."
  @spec dump(t()) :: %{version: pos_integer(), records: [map()], daemon_events: [map()]}
  def dump(%__MODULE__{} = lifecycle) do
    records =
      lifecycle.history_ids
      |> Map.values()
      |> List.flatten()
      |> Enum.uniq()
      |> Enum.map(&Map.fetch!(lifecycle.records, &1))
      |> Enum.map(&event_payload/1)

    %{
      version: @protocol_version,
      records: records,
      daemon_events: Enum.map(lifecycle.daemon_events, &Restore.daemon_event_payload/1)
    }
  end

  @doc """
  Appends a daemon lifecycle event (`:start` or `:stop`) to the durable journal.

  The event identifies the invoking process so a later incident review can tell
  which instance booted, when, and from which parent. Recording is idempotent
  per run: a second event with the same `kind` and `run_id` (a re-marked boot,
  or a stop recorded on both the `prep_stop` and `stop` shutdown paths) is a
  no-op rather than a duplicate. The journal is bounded to `@daemon_event_limit`
  events, keeping the most recent entries.
  """
  @spec record_daemon_event(t(), :start | :stop, map()) :: t()
  def record_daemon_event(%__MODULE__{} = lifecycle, kind, attrs)
      when kind in @daemon_kinds and is_map(attrs) do
    event = Restore.build_daemon_event(kind, attrs)

    if Enum.any?(lifecycle.daemon_events, &(&1.kind == kind and &1.run_id == event.run_id)) do
      lifecycle
    else
      %{lifecycle | daemon_events: (lifecycle.daemon_events ++ [event]) |> Enum.take(-@daemon_event_limit)}
    end
  end

  @doc "Returns the recorded daemon lifecycle events, oldest first."
  @spec daemon_events(t()) :: [daemon_event()]
  def daemon_events(%__MODULE__{} = lifecycle), do: lifecycle.daemon_events

  @doc false
  @spec merge_daemon_events(t(), t()) :: t()
  def merge_daemon_events(%__MODULE__{} = lifecycle, %__MODULE__{} = other) do
    events =
      (lifecycle.daemon_events ++ other.daemon_events)
      |> Enum.uniq_by(&{&1.kind, &1.run_id})
      |> Enum.sort_by(&DateTime.to_unix(&1.at, :microsecond))
      |> Enum.take(-@daemon_event_limit)

    %{lifecycle | daemon_events: events}
  end

  @doc false
  @spec merge(t(), t()) :: t()
  defdelegate merge(lifecycle, other), to: Restore

  @doc "Restores a previously redacted lifecycle projection, skipping invalid records."
  @spec restore(term(), keyword()) :: t()
  def restore(%{"version" => @protocol_version, "records" => records} = persisted, opts) when is_list(records) do
    Restore.restore(records, persisted, opts)
  end

  def restore(%{version: @protocol_version, records: records} = persisted, opts) when is_list(records) do
    Restore.restore(records, persisted, opts)
  end

  def restore(_persisted, opts), do: new(opts)

  @doc "Builds a normalized audit/event payload from allowlisted request fields."
  @spec event_payload(request()) :: map()
  def event_payload(request) when is_map(request) do
    %{
      protocol_version: request.protocol_version,
      request_id: request.request_id,
      issue_id: request.issue_id,
      tracker_identity: identity_payload(request.tracker_identity),
      action: request.action,
      generation: request.generation,
      expected_status: request.expected_status,
      expected_version: request.expected_version,
      requester: request.requester,
      status: request.status,
      requested_at: request.requested_at,
      accepted_at: request.accepted_at,
      applied_at: request.applied_at,
      rejected_at: request.rejected_at,
      rejection: request.rejection,
      expiry: request.expiry
    }
  end

  defp identity_payload(%TrackerIdentity{} = identity) do
    Map.take(identity, [:version, :status, :kind, :owner, :repository, :provider_id, :identifier, :reason])
  end

  defp positive_integer(value) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value), do: @default_history_limit

  defp now!(opts) do
    case Keyword.fetch(opts, :now) do
      {:ok, %DateTime{} = now} -> now
      _ -> DateTime.utc_now()
    end
  end

  @doc false
  @spec allowed_values(atom()) :: pos_integer() | [atom()]
  def allowed_values(:protocol_version), do: @protocol_version
  def allowed_values(:actions), do: @actions
  def allowed_values(:requesters), do: @requesters
  def allowed_values(:expected_statuses), do: @expected_statuses
  def allowed_values(:statuses), do: @statuses
  def allowed_values(:pending_statuses), do: @pending_statuses
  def allowed_values(:rejection_classes), do: @rejection_classes
  def allowed_values(:expiry_reasons), do: @expiry_reasons
  def allowed_values(:daemon_kinds), do: @daemon_kinds
  def allowed_values(:daemon_event_limit), do: @daemon_event_limit
end
