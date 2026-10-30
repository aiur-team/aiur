defmodule Aiur.Commands.OverrideMerge do
  @moduledoc "Versioned merge disposition for overrides delivered to an unmerged worker."

  alias Aiur.DecisionEvent.Validation

  @spec normalize(map()) :: {:ok, map()} | {:error, term()}
  def normalize(raw) do
    with {:ok, action} <- Validation.map_required_string(raw, :action_id, 256),
         {:ok, head} <- Validation.bounded_optional(Validation.get(raw, :head_sha), 128, :head_sha),
         version when is_integer(version) and version > 0 <- Validation.get(raw, :expected_version),
         number when is_integer(number) and number > 0 <- Validation.get(raw, :pr_number),
         {:ok, at} <- timestamp(Validation.get(raw, :committed_at)) do
      {:ok, %{action_id: action, head_sha: head, expected_version: version, pr_number: number, committed_at: at}}
    else
      _ -> {:error, :invalid_override_merge}
    end
  end

  @spec apply(map(), map()) :: {:ok, map()} | {:error, atom()}
  def apply(decision, %{data: data, occurred_at: at}) do
    record = Enum.find(decision.overrides, &(&1.action_id == data.action_id))

    if eligible?(record, decision, data) do
      implemented =
        record.state == :delivered and is_binary(data.head_sha) and is_struct(data.committed_at, DateTime) and
          DateTime.compare(data.committed_at, record.delivered_at) == :gt and data.head_sha != record.pr_head_sha

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

  defp eligible?(nil, _, _), do: false

  defp eligible?(record, decision, data) do
    record.action_id == decision.active_action_id and record.state in [:queued, :delivered, :failed] and
      record.route != :corrective_ticket and is_nil(record.corrective_ticket) and
      Map.get(record, :merge_version, 1) == data.expected_version and
      (is_nil(record.pr_number) or record.pr_number == data.pr_number)
  end

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
