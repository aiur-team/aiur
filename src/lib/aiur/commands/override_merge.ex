defmodule Aiur.Commands.OverrideMerge do
  @moduledoc "Versioned merge disposition for overrides delivered to an unmerged worker."

  alias Aiur.DecisionEvent.Validation

  @spec normalize(map()) :: {:ok, map()} | {:error, term()}
  def normalize(raw) do
    # Keep legacy committed_at readable; only recorded push ancestry authorizes implementation.
    with {:ok, action} <- Validation.map_required_string(raw, :action_id, 256),
         {:ok, head} <- Validation.bounded_optional(Validation.get(raw, :head_sha), 128, :head_sha),
         {:ok, worker_head} <- Validation.bounded_optional(Validation.get(raw, :worker_head_sha), 128, :worker_head_sha),
         contains when is_boolean(contains) <- Validation.get(raw, :head_contains_worker_push) || false,
         version when is_integer(version) and version > 0 <- Validation.get(raw, :expected_version),
         number when is_integer(number) and number > 0 <- Validation.get(raw, :pr_number),
         {:ok, at} <- timestamp(Validation.get(raw, :committed_at)) do
      {:ok, %{action_id: action, head_sha: head, worker_head_sha: worker_head, head_contains_worker_push: contains, expected_version: version, pr_number: number, committed_at: at}}
    else
      _ -> {:error, :invalid_override_merge}
    end
  end

  @spec apply(map(), map()) :: {:ok, map()} | {:error, atom()}
  def apply(decision, %{data: data, occurred_at: at}) do
    record = Enum.find(decision.overrides, &(&1.action_id == data.action_id))

    if eligible?(record, decision, data) do
      implemented = implemented?(record, data)

      record =
        record
        |> Map.put(:merge_version, data.expected_version + 1)
        |> Map.put(:pr_merged, true)
        |> Map.put(:evidence, %{kind: :merge, head_sha: data.head_sha, pr_number: data.pr_number})
        |> disposition(implemented, at)

      {:ok, %{decision | overrides: Enum.map(decision.overrides, &if(&1.action_id == data.action_id, do: record, else: &1))}}
    else
      {:error, :stale}
    end
  end

  defp implemented?(%{state: :delivered, evidence: %{kind: :push, worker_reported: true, head_sha: pushed, at: pushed_at}} = record, data) do
    is_binary(data.head_sha) and Map.get(data, :worker_head_sha) == pushed and
      Map.get(data, :head_contains_worker_push) == true and is_struct(pushed_at, DateTime) and
      DateTime.compare(pushed_at, record.delivered_at) == :gt
  end

  defp implemented?(_record, _data), do: false

  defp eligible?(nil, _, _), do: false

  defp eligible?(record, decision, data) do
    record.action_id == decision.active_action_id and record.state in [:queued, :delivered, :failed] and
      record.route != :corrective_ticket and is_nil(record.corrective_ticket) and
      Map.get(record, :merge_version, 1) == data.expected_version and
      worker_head(record) == Map.get(data, :worker_head_sha) and
      (is_nil(record.pr_number) or record.pr_number == data.pr_number)
  end

  defp worker_head(%{evidence: %{kind: :push, worker_reported: true, head_sha: sha}}), do: sha
  defp worker_head(_record), do: nil

  defp disposition(record, true, at), do: %{record | state: :implemented, implemented_at: at}
  defp disposition(record, false, _at), do: record |> Map.put(:route, :corrective_ticket) |> Map.put(:merge_reason, "PR merged before the change")

  defp timestamp(nil), do: {:ok, nil}
  defp timestamp(%DateTime{} = at), do: {:ok, at}

  defp timestamp(at) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, parsed, _} -> {:ok, parsed}
      _ -> {:error, :invalid_timestamp}
    end
  end

  defp timestamp(_), do: {:error, :invalid_timestamp}
end
