defmodule Aiur.Orchestrator.ControlLifecycle.Restore do
  @moduledoc false

  alias Aiur.Orchestrator.ControlLifecycle
  alias Aiur.TrackerIdentity
  import Aiur.Orchestrator.ControlLifecycle.Records, only: [trim_history: 2]
  import Aiur.Orchestrator.ControlLifecycle.Validation, only: [valid_request_id?: 1, valid_issue_id?: 1, valid_generation?: 1, valid_expected_version?: 1]

  @spec restore([map()], map(), keyword()) :: ControlLifecycle.t()
  def restore(records, persisted, opts) do
    records
    |> restore_records(opts)
    |> put_restored_daemon_events(persisted)
    |> put_restored_max_agents(persisted)
  end

  @spec merge(ControlLifecycle.t(), ControlLifecycle.t()) :: ControlLifecycle.t()
  def merge(%ControlLifecycle{} = lifecycle, %ControlLifecycle{} = other) do
    records =
      Map.merge(lifecycle.records, other.records, fn _request_id, left, right ->
        Enum.max_by([left, right], &request_transition_key/1)
      end)

    history_limit = max(lifecycle.history_limit, other.history_limit)
    created_at = earliest_datetime(lifecycle.created_at, other.created_at)

    merged =
      records
      |> Map.values()
      |> Enum.sort_by(&request_history_key/1)
      |> Enum.reduce(ControlLifecycle.new(now: created_at, history_limit: history_limit), &put_restored_request(&2, &1))
      |> trim_restored_history()

    ControlLifecycle.merge_daemon_events(merged, %{lifecycle | daemon_events: lifecycle.daemon_events ++ other.daemon_events})
    |> Map.put(:max_agents, other.max_agents || lifecycle.max_agents)
  end

  defp request_history_key(request) do
    {DateTime.to_unix(request.requested_at, :microsecond), to_string(request.request_id)}
  end

  defp request_transition_key(request) do
    {DateTime.to_unix(request_transition_at(request), :microsecond), status_rank(request.status)}
  end

  defp request_transition_at(%{status: :applied, applied_at: %DateTime{} = at}), do: at
  defp request_transition_at(%{status: :rejected, rejected_at: %DateTime{} = at}), do: at
  defp request_transition_at(%{status: :expired, expiry: %{at: %DateTime{} = at}}), do: at
  defp request_transition_at(%{status: :accepted, accepted_at: %DateTime{} = at}), do: at
  defp request_transition_at(request), do: request.requested_at

  defp status_rank(:requested), do: 0
  defp status_rank(:accepted), do: 1
  defp status_rank(status) when status in [:applied, :rejected, :expired], do: 2

  defp earliest_datetime(nil, right), do: right
  defp earliest_datetime(left, nil), do: left
  defp earliest_datetime(%DateTime{} = left, %DateTime{} = right), do: Enum.min_by([left, right], &DateTime.to_unix(&1, :microsecond))

  defp restore_records(records, opts) do
    records
    |> Enum.reduce(ControlLifecycle.new(opts), fn raw, lifecycle ->
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
         {:ok, action} <- persisted_atom(persisted_value(raw, :action), ControlLifecycle.allowed_values(:actions)),
         generation <- persisted_value(raw, :generation),
         true <- valid_generation?(generation),
         {:ok, expected_status} <- persisted_atom(persisted_value(raw, :expected_status), ControlLifecycle.allowed_values(:expected_statuses)),
         expected_version <- persisted_value(raw, :expected_version),
         true <- valid_expected_version?(expected_version),
         {:ok, requester} <- persisted_atom(persisted_value(raw, :requester), ControlLifecycle.allowed_values(:requesters)),
         {:ok, status} <- persisted_atom(persisted_value(raw, :status), ControlLifecycle.allowed_values(:statuses)),
         {:ok, requested_at} <- restore_datetime(persisted_value(raw, :requested_at)) do
      {:ok,
       %{
         protocol_version: ControlLifecycle.allowed_values(:protocol_version),
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

    if request.status in ControlLifecycle.allowed_values(:pending_statuses) do
      put_in(lifecycle.pending[request.issue_id], request.request_id)
    else
      lifecycle
    end
  end

  defp trim_restored_history(lifecycle) do
    Enum.reduce(Map.keys(lifecycle.history_ids), lifecycle, &trim_history(&2, &1))
  end

  @spec build_daemon_event(:start | :stop, map()) :: ControlLifecycle.daemon_event()
  def build_daemon_event(kind, attrs) do
    %{
      kind: kind,
      at: daemon_event_at(attrs),
      run_id: Map.get(attrs, :run_id) || "",
      os_pid: Map.get(attrs, :os_pid) || "",
      ppid: string_or_nil(Map.get(attrs, :ppid)),
      ppid_comm: string_or_nil(Map.get(attrs, :ppid_comm)),
      hostname: string_or_nil(Map.get(attrs, :hostname))
    }
  end

  @spec daemon_event_payload(ControlLifecycle.daemon_event()) :: map()
  def daemon_event_payload(event) do
    %{
      kind: event.kind,
      at: event.at,
      run_id: event.run_id,
      os_pid: event.os_pid,
      ppid: event.ppid,
      ppid_comm: event.ppid_comm,
      hostname: event.hostname
    }
  end

  defp put_restored_daemon_events(lifecycle, persisted) do
    events =
      case persisted_value(persisted, :daemon_events) do
        raw when is_list(raw) -> Enum.flat_map(raw, &restore_daemon_event/1)
        _ -> []
      end

    %{lifecycle | daemon_events: Enum.take(events, -ControlLifecycle.allowed_values(:daemon_event_limit))}
  rescue
    _ -> lifecycle
  end

  defp put_restored_max_agents(lifecycle, persisted) do
    case persisted_value(persisted, :max_agents) do
      value when is_integer(value) and value > 0 -> %{lifecycle | max_agents: value}
      _ -> lifecycle
    end
  end

  defp restore_daemon_event(raw) when is_map(raw) do
    with {:ok, kind} <- persisted_atom(persisted_value(raw, :kind), ControlLifecycle.allowed_values(:daemon_kinds)),
         {:ok, at} <- restore_datetime(persisted_value(raw, :at)),
         run_id when is_binary(run_id) and run_id != "" <- persisted_value(raw, :run_id) do
      [
        build_daemon_event(kind, %{
          at: at,
          run_id: run_id,
          os_pid: persisted_value(raw, :os_pid),
          ppid: persisted_value(raw, :ppid),
          ppid_comm: persisted_value(raw, :ppid_comm),
          hostname: persisted_value(raw, :hostname)
        })
      ]
    else
      _ -> []
    end
  end

  defp restore_daemon_event(_raw), do: []

  defp daemon_event_at(attrs) do
    case Map.get(attrs, :at) do
      %DateTime{} = value -> value
      _ -> DateTime.utc_now()
    end
  end

  defp string_or_nil(value) when is_binary(value) and value != "", do: value
  defp string_or_nil(_value), do: nil

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
    with {:ok, class} <- persisted_atom(persisted_value(raw, :class), ControlLifecycle.allowed_values(:rejection_classes)),
         message when is_binary(message) <- persisted_value(raw, :message) do
      %{class: class, message: message}
      |> maybe_put_rejection_condition(restore_rejection_condition(persisted_value(raw, :condition)))
    else
      _ -> nil
    end
  end

  defp restore_rejection(_raw), do: nil

  defp restore_rejection_condition(raw) when is_map(raw) do
    with {:ok, control_status} <- persisted_atom(persisted_value(raw, :control_status), ControlLifecycle.allowed_values(:expected_statuses)),
         {:ok, pause_reason} <- persisted_optional_atom(persisted_value(raw, :pause_reason), pause_reasons()) do
      %{control_status: control_status, pause_reason: pause_reason}
    else
      _ -> nil
    end
  end

  defp restore_rejection_condition(_raw), do: nil

  defp maybe_put_rejection_condition(rejection, nil), do: rejection
  defp maybe_put_rejection_condition(rejection, condition), do: Map.put(rejection, :condition, condition)

  defp restore_expiry(nil), do: nil

  defp restore_expiry(raw) when is_map(raw) do
    with {:ok, reason} <- persisted_atom(persisted_value(raw, :reason), ControlLifecycle.allowed_values(:expiry_reasons)),
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

  @doc false
  @spec pause_reasons() :: [atom()]
  def pause_reasons do
    [
      :before_run_failure,
      :blocker_dependency,
      :ci_wait,
      :global_pause,
      :label_override,
      :max_agent_duration,
      :operator_pause,
      :rate_limit_fallback_recovery,
      :usage_limit_exhausted
    ]
  end
end
