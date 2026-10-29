defmodule Aiur.Commands.Overrides do
  @moduledoc "Durable override metadata and lifecycle projection."

  alias Aiur.{Decision, DecisionEvent, JSONSafe}

  @routes [:active_worker, :resume_pending, :capacity_wait, :corrective_ticket, :replacement]

  @spec normalize_metadata(term()) :: {:ok, map() | nil} | {:error, :invalid_override_metadata}
  def normalize_metadata(nil), do: {:ok, nil}

  def normalize_metadata(raw) when is_map(raw) do
    metadata = Map.new([:pr_number, :pr_merged, :pr_head_sha, :pr_head_ref, :route], &{&1, get(raw, &1)})
    route = Enum.find(@routes, &(metadata.route in [&1, Atom.to_string(&1)]))
    merged = if metadata.pr_merged == "unknown", do: :unknown, else: metadata.pr_merged

    if route && merged in [true, false, :unknown] && valid_number?(metadata.pr_number) &&
         valid_string?(metadata.pr_head_sha, 128) && valid_string?(metadata.pr_head_ref, 256) do
      {:ok, %{metadata | route: route, pr_merged: merged}}
    else
      {:error, :invalid_override_metadata}
    end
  end

  def normalize_metadata(_raw), do: {:error, :invalid_override_metadata}

  @spec public(Decision.t()) :: [map()]
  def public(decision), do: JSONSafe.normalize(decision.overrides)

  @spec observe(Decision.t(), DecisionEvent.t()) :: Decision.t()
  def observe(decision, %{type: :revision_recorded, data: %{override: metadata} = revision} = event) when is_map(metadata) do
    previous = Enum.map(decision.overrides, &supersede(&1, event.occurred_at))

    record =
      Map.merge(metadata, %{
        override_id: revision.action_id,
        decision_id: decision.decision_id,
        prior_action_id: revision.prior_action_id,
        action_id: revision.action_id,
        ticket: decision.ticket,
        state: :queued,
        queued_at: event.occurred_at,
        delivered_at: nil,
        implemented_at: nil,
        superseded_at: nil,
        evidence: nil
      })

    %{decision | overrides: previous ++ [record]}
  end

  def observe(decision, %{type: :delivered, data: data, occurred_at: at}) do
    update(decision, data.action_id, fn
      %{state: :queued} = record -> %{record | state: :delivered, delivered_at: at}
      record -> record
    end)
  end

  def observe(decision, %{type: type, data: data, occurred_at: at}) when type in [:acknowledged, :resolved] do
    update(decision, data.action_id, fn
      %{state: state, route: :active_worker} = record when state in [:queued, :delivered] -> %{record | state: :implemented, implemented_at: at, evidence: :acknowledged}
      record -> record
    end)
  end

  def observe(decision, _event), do: decision

  @spec implemented(Decision.t(), DecisionEvent.t()) :: {:ok, Decision.t()} | {:error, atom()}
  def implemented(decision, %{data: data}) do
    record = Enum.find(decision.overrides, &(&1.action_id == data.action_id))

    if valid_push?(record, decision, data) do
      {:ok, update(decision, data.action_id, &%{&1 | state: :implemented, implemented_at: data.at, evidence: %{kind: :push, head_sha: data.head_sha, pr_number: data.pr_number}})}
    else
      {:error, :override_push_mismatch}
    end
  end

  defp valid_push?(%{state: :delivered, route: :active_worker} = record, decision, data) do
    decision.active_action_id == data.action_id && (is_nil(record.pr_number) || record.pr_number == data.pr_number) &&
      is_integer(data.pr_number) && changed_head?(record, data) && after_delivery?(record, data)
  end

  defp valid_push?(_record, _decision, _data), do: false

  defp changed_head?(record, data) do
    is_binary(data.head_sha) && data.head_sha != "" &&
      data.head_sha != record.pr_head_sha
  end

  defp after_delivery?(record, data) do
    match?(%DateTime{}, data.at) && match?(%DateTime{}, record.delivered_at) &&
      DateTime.compare(data.at, record.delivered_at) == :gt
  end

  defp supersede(%{state: :superseded} = record, _at), do: record
  defp supersede(record, at), do: %{record | state: :superseded, superseded_at: at}

  defp update(decision, action_id, fun) do
    %{decision | overrides: Enum.map(decision.overrides, &if(&1.action_id == action_id, do: fun.(&1), else: &1))}
  end

  defp valid_number?(nil), do: true
  defp valid_number?(value), do: is_integer(value) and value > 0
  defp valid_string?(nil, _max), do: true
  defp valid_string?(value, max), do: is_binary(value) and String.valid?(value) and byte_size(value) in 1..max and not String.match?(value, ~r/[\x00-\x1f\x7f]/)
  defp get(raw, key), do: Map.get(raw, key, Map.get(raw, Atom.to_string(key)))
end
