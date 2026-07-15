defmodule Aiur.Orchestrator.ControlLifecycle do
  @moduledoc """
  In-memory projection for correlated per-unit control requests.

  The Orchestrator owns this projection. Worker messages may move a request
  from `:accepted` to `:applied` only when they carry the exact request ID and
  worker generation that were admitted by the control plane.
  """

  alias Aiur.TrackerIdentity

  @protocol_version 1
  @default_history_limit 32
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
            pending: %{}

  @type t :: %__MODULE__{
          protocol_version: pos_integer(),
          created_at: DateTime.t() | nil,
          history_limit: pos_integer(),
          records: %{optional(String.t() | pos_integer()) => request()},
          history_ids: %{optional(term()) => [String.t() | pos_integer()]},
          pending: %{optional(term()) => String.t() | pos_integer()}
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

  def reject(%__MODULE__{} = lifecycle, request_id, class, opts) when is_atom(class) do
    now = now!(opts)

    case Map.get(lifecycle.records, request_id) do
      %{status: status} = request when status in @pending_statuses ->
        if pending_request?(lifecycle, request) do
          rejected = %{
            request
            | status: :rejected,
              rejected_at: now,
              rejection: rejection(class, rejection_message(class))
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
  @spec dump(t()) :: %{version: pos_integer(), records: [map()]}
  def dump(%__MODULE__{} = lifecycle) do
    records =
      lifecycle.history_ids
      |> Map.values()
      |> List.flatten()
      |> Enum.uniq()
      |> Enum.map(&Map.fetch!(lifecycle.records, &1))
      |> Enum.map(&event_payload/1)

    %{version: @protocol_version, records: records}
  end

  @doc "Restores a previously redacted lifecycle projection, skipping invalid records."
  @spec restore(term(), keyword()) :: t()
  def restore(%{"version" => @protocol_version, "records" => records}, opts) when is_list(records) do
    restore_records(records, opts)
  end

  def restore(%{version: @protocol_version, records: records}, opts) when is_list(records) do
    restore_records(records, opts)
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

  defp validate_request(attrs) do
    attrs
    |> request_validations()
    |> Enum.find(:ok, &match?({:error, _}, &1))
  end

  defp request_validations(attrs) do
    [
      validate_request_id(attrs),
      validate_issue_id(attrs),
      validate_tracker_identity(attrs),
      validate_action(attrs),
      validate_generation(attrs),
      validate_expected_status(attrs),
      validate_expected_version(attrs),
      validate_requester(attrs)
    ]
  end

  defp validate_request_id(attrs) do
    if valid_request_id?(Map.get(attrs, :request_id)),
      do: :ok,
      else: {:error, rejection(:control_failed, "request ID must be a non-empty string or positive integer")}
  end

  defp validate_issue_id(attrs) do
    if valid_issue_id?(Map.get(attrs, :issue_id)),
      do: :ok,
      else: {:error, rejection(:not_found, "unit identifier is required")}
  end

  defp validate_tracker_identity(attrs) do
    if TrackerIdentity.joinable?(Map.get(attrs, :tracker_identity)),
      do: :ok,
      else: {:error, rejection(:not_eligible, "unit does not have a joinable repository-qualified identity")}
  end

  defp validate_action(attrs) do
    if Map.get(attrs, :action) in @actions,
      do: :ok,
      else: {:error, rejection(:unsupported, "control action must be pause or resume")}
  end

  defp validate_generation(attrs) do
    if valid_generation?(Map.get(attrs, :generation)),
      do: :ok,
      else: {:error, rejection(:stale_generation, "worker generation is required")}
  end

  defp validate_expected_status(attrs) do
    if is_atom(Map.get(attrs, :expected_status)),
      do: :ok,
      else: {:error, rejection(:control_failed, "expected authoritative status is required")}
  end

  defp validate_expected_version(attrs) do
    if valid_expected_version?(Map.get(attrs, :expected_version)),
      do: :ok,
      else: {:error, rejection(:control_failed, "expected authoritative version must be a non-negative integer")}
  end

  defp validate_requester(attrs) do
    if Map.get(attrs, :requester) in @requesters,
      do: :ok,
      else: {:error, rejection(:control_failed, "requester class is required")}
  end

  defp build_request(attrs, now) do
    %{
      protocol_version: @protocol_version,
      request_id: attrs.request_id,
      issue_id: attrs.issue_id,
      tracker_identity: attrs.tracker_identity,
      action: attrs.action,
      generation: attrs.generation,
      expected_status: attrs.expected_status,
      expected_version: attrs.expected_version,
      requester: attrs.requester,
      status: :requested,
      requested_at: now,
      accepted_at: nil,
      applied_at: nil,
      rejected_at: nil,
      rejection: nil,
      expiry: nil
    }
  end

  defp same_intent?(record, attrs) do
    Enum.all?(
      [:issue_id, :tracker_identity, :action, :generation, :expected_status, :expected_version, :requester],
      &(Map.get(record, &1) == Map.get(attrs, &1))
    )
  end

  defp supersede_pending(lifecycle, issue_id, now) do
    case current_pending(lifecycle, issue_id) do
      nil ->
        lifecycle

      request ->
        superseded = %{
          request
          | status: :rejected,
            rejected_at: now,
            rejection: rejection(:superseded, "a newer control intent superseded this pending request")
        }

        lifecycle
        |> put_record(superseded)
        |> clear_pending(issue_id, request.request_id)
    end
  end

  defp put_new_request(lifecycle, request) do
    history_ids = Map.update(lifecycle.history_ids, request.issue_id, [request.request_id], &(&1 ++ [request.request_id]))

    lifecycle
    |> Map.put(:history_ids, history_ids)
    |> put_record(request)
    |> put_in([Access.key(:pending), request.issue_id], request.request_id)
    |> trim_history(request.issue_id)
  end

  defp put_record(lifecycle, request), do: put_in(lifecycle.records[request.request_id], request)

  defp clear_pending(lifecycle, issue_id, request_id) do
    if lifecycle.pending[issue_id] == request_id do
      update_in(lifecycle.pending, &Map.delete(&1, issue_id))
    else
      lifecycle
    end
  end

  defp pending_request?(lifecycle, request), do: lifecycle.pending[request.issue_id] == request.request_id

  defp trim_history(lifecycle, issue_id) do
    ids = Map.fetch!(lifecycle.history_ids, issue_id)
    overflow = max(length(ids) - lifecycle.history_limit, 0)

    {discarded, retained} = Enum.split(ids, overflow)

    records =
      Enum.reduce(discarded, lifecycle.records, fn request_id, records ->
        if Map.get(lifecycle.pending, issue_id) == request_id do
          records
        else
          Map.delete(records, request_id)
        end
      end)

    %{lifecycle | records: records, history_ids: Map.put(lifecycle.history_ids, issue_id, retained)}
  end

  defp identity_payload(%TrackerIdentity{} = identity) do
    Map.take(identity, [:version, :status, :kind, :owner, :repository, :provider_id, :identifier, :reason])
  end

  defp restore_records(records, opts) do
    records
    |> Enum.reduce(new(opts), fn raw, lifecycle ->
      case restore_record(raw) do
        {:ok, request} -> put_restored_request(lifecycle, request)
        :error -> lifecycle
      end
    end)
    |> trim_restored_history()
  end

  defp restore_record(raw) when is_map(raw) do
    with request_id <- persisted_value(raw, :request_id),
         true <- valid_request_id?(request_id),
         issue_id <- persisted_value(raw, :issue_id),
         true <- valid_issue_id?(issue_id),
         {:ok, tracker_identity} <- restore_identity(persisted_value(raw, :tracker_identity)),
         {:ok, action} <- persisted_atom(persisted_value(raw, :action), @actions),
         generation <- persisted_value(raw, :generation),
         true <- valid_generation?(generation),
         {:ok, expected_status} <- persisted_atom(persisted_value(raw, :expected_status), @expected_statuses),
         expected_version <- persisted_value(raw, :expected_version),
         true <- valid_expected_version?(expected_version),
         {:ok, requester} <- persisted_atom(persisted_value(raw, :requester), @requesters),
         {:ok, status} <- persisted_atom(persisted_value(raw, :status), @statuses),
         {:ok, requested_at} <- restore_datetime(persisted_value(raw, :requested_at)) do
      {:ok,
       %{
         protocol_version: @protocol_version,
         request_id: request_id,
         issue_id: issue_id,
         tracker_identity: tracker_identity,
         action: action,
         generation: generation,
         expected_status: expected_status,
         expected_version: expected_version,
         requester: requester,
         status: status,
         requested_at: requested_at,
         accepted_at: restore_optional_datetime(persisted_value(raw, :accepted_at)),
         applied_at: restore_optional_datetime(persisted_value(raw, :applied_at)),
         rejected_at: restore_optional_datetime(persisted_value(raw, :rejected_at)),
         rejection: restore_rejection(persisted_value(raw, :rejection)),
         expiry: restore_expiry(persisted_value(raw, :expiry))
       }}
    else
      _ -> :error
    end
  end

  defp restore_record(_raw), do: :error

  defp put_restored_request(lifecycle, request) do
    history_ids = Map.update(lifecycle.history_ids, request.issue_id, [request.request_id], &(&1 ++ [request.request_id]))

    lifecycle = %{
      lifecycle
      | records: Map.put(lifecycle.records, request.request_id, request),
        history_ids: history_ids
    }

    if request.status in @pending_statuses do
      put_in(lifecycle.pending[request.issue_id], request.request_id)
    else
      lifecycle
    end
  end

  defp trim_restored_history(lifecycle) do
    Enum.reduce(Map.keys(lifecycle.history_ids), lifecycle, &trim_history(&2, &1))
  end

  defp restore_identity(raw) when is_map(raw) do
    with {:ok, status} <- persisted_atom(persisted_value(raw, :status), [:joinable, :unjoinable]),
         {:ok, kind} <- persisted_atom(persisted_value(raw, :kind), [:github]),
         {:ok, reason} <- persisted_optional_atom(persisted_value(raw, :reason), TrackerIdentity.unjoinable(:legacy).reason |> List.wrap()),
         version when is_integer(version) and version > 0 <- persisted_value(raw, :version) do
      {:ok,
       %TrackerIdentity{
         version: version,
         status: status,
         kind: kind,
         owner: persisted_value(raw, :owner),
         repository: persisted_value(raw, :repository),
         provider_id: persisted_value(raw, :provider_id),
         identifier: persisted_value(raw, :identifier),
         reason: reason
       }}
    else
      _ -> :error
    end
  end

  defp restore_identity(_raw), do: :error

  defp restore_datetime(%DateTime{} = value), do: {:ok, value}

  defp restore_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      _ -> :error
    end
  end

  defp restore_datetime(_value), do: :error

  defp restore_optional_datetime(nil), do: nil

  defp restore_optional_datetime(value) do
    case restore_datetime(value) do
      {:ok, datetime} -> datetime
      :error -> nil
    end
  end

  defp restore_rejection(nil), do: nil

  defp restore_rejection(raw) when is_map(raw) do
    with {:ok, class} <- persisted_atom(persisted_value(raw, :class), @rejection_classes),
         message when is_binary(message) <- persisted_value(raw, :message) do
      %{class: class, message: message}
    else
      _ -> nil
    end
  end

  defp restore_rejection(_raw), do: nil

  defp restore_expiry(nil), do: nil

  defp restore_expiry(raw) when is_map(raw) do
    with {:ok, reason} <- persisted_atom(persisted_value(raw, :reason), @expiry_reasons),
         {:ok, at} <- restore_datetime(persisted_value(raw, :at)) do
      %{reason: reason, at: at}
    else
      _ -> nil
    end
  end

  defp restore_expiry(_raw), do: nil

  defp persisted_value(raw, key), do: Map.get(raw, key, Map.get(raw, Atom.to_string(key)))

  defp persisted_atom(value, allowed) when is_atom(value) do
    if value in allowed, do: {:ok, value}, else: :error
  end

  defp persisted_atom(value, allowed) when is_binary(value) do
    Enum.find_value(allowed, :error, fn atom -> if Atom.to_string(atom) == value, do: {:ok, atom} end)
  end

  defp persisted_atom(_value, _allowed), do: :error

  defp persisted_optional_atom(nil, _allowed), do: {:ok, nil}
  defp persisted_optional_atom(value, allowed), do: persisted_atom(value, allowed)

  defp positive_integer(value) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value), do: @default_history_limit

  defp now!(opts) do
    case Keyword.fetch(opts, :now) do
      {:ok, %DateTime{} = now} -> now
      _ -> DateTime.utc_now()
    end
  end

  defp valid_request_id?(value), do: (is_binary(value) and value != "") or (is_integer(value) and value > 0)
  defp valid_issue_id?(value), do: not is_nil(value)
  defp valid_generation?(value), do: (is_binary(value) and value != "") or (is_integer(value) and value >= 0)
  defp valid_expected_version?(value), do: is_integer(value) and value >= 0

  defp rejection(class, message), do: %{class: class, message: message}

  defp rejection_message(:not_found), do: "target unit was not found"
  defp rejection_message(:not_eligible), do: "target unit is not eligible for control"
  defp rejection_message(:unsupported), do: "target worker does not support this control"
  defp rejection_message(:stale_generation), do: "target worker generation is no longer current"
  defp rejection_message(:worker_unavailable), do: "target worker is unavailable"
  defp rejection_message(:already_in_state), do: "target is already in the requested state"
  defp rejection_message(:control_failed), do: "control routing failed"
  defp rejection_message(:superseded), do: "a newer control intent superseded this request"
  defp rejection_message(_class), do: "control request was rejected"
end
