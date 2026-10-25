defmodule Aiur.Orchestrator.ControlLifecycle.Records do
  @moduledoc false

  alias Aiur.Orchestrator.ControlLifecycle
  import Aiur.Orchestrator.ControlLifecycle.Validation, only: [rejection: 2]

  @spec build_request(map(), DateTime.t()) :: ControlLifecycle.request()
  def build_request(attrs, now) do
    %{
      protocol_version: ControlLifecycle.allowed_values(:protocol_version),
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

  @spec same_intent?(map(), map()) :: boolean()
  def same_intent?(record, attrs) do
    Enum.all?(
      [:issue_id, :tracker_identity, :action, :generation, :expected_status, :expected_version, :requester],
      &(Map.get(record, &1) == Map.get(attrs, &1))
    )
  end

  @spec supersede_pending(ControlLifecycle.t(), term(), DateTime.t()) :: ControlLifecycle.t()
  def supersede_pending(lifecycle, issue_id, now) do
    case ControlLifecycle.current_pending(lifecycle, issue_id) do
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

  @spec put_new_request(ControlLifecycle.t(), ControlLifecycle.request()) :: ControlLifecycle.t()
  def put_new_request(lifecycle, request) do
    history_ids = Map.update(lifecycle.history_ids, request.issue_id, [request.request_id], &(&1 ++ [request.request_id]))

    lifecycle
    |> Map.put(:history_ids, history_ids)
    |> put_record(request)
    |> put_in([Access.key(:pending), request.issue_id], request.request_id)
    |> trim_history(request.issue_id)
  end

  @spec put_record(ControlLifecycle.t(), ControlLifecycle.request()) :: ControlLifecycle.t()
  def put_record(lifecycle, request), do: put_in(lifecycle.records[request.request_id], request)

  @spec clear_pending(ControlLifecycle.t(), term(), String.t() | pos_integer()) :: ControlLifecycle.t()
  def clear_pending(lifecycle, issue_id, request_id) do
    if lifecycle.pending[issue_id] == request_id do
      update_in(lifecycle.pending, &Map.delete(&1, issue_id))
    else
      lifecycle
    end
  end

  @spec pending_request?(ControlLifecycle.t(), ControlLifecycle.request()) :: boolean()
  def pending_request?(lifecycle, request), do: lifecycle.pending[request.issue_id] == request.request_id

  @spec trim_history(ControlLifecycle.t(), term()) :: ControlLifecycle.t()
  def trim_history(lifecycle, issue_id) do
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

  @spec put_snapshot_request(ControlLifecycle.t(), ControlLifecycle.request()) :: ControlLifecycle.t()
  def put_snapshot_request(lifecycle, request) do
    %{
      lifecycle
      | history_ids: Map.update(lifecycle.history_ids, request.issue_id, [request.request_id], &(&1 ++ [request.request_id])),
        records: Map.put(lifecycle.records, request.request_id, request)
    }
  end
end
