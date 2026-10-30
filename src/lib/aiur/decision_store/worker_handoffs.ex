defmodule Aiur.DecisionStore.WorkerHandoffs do
  @moduledoc "Serialized worker handoff attestations for delivered Command overrides."

  alias Aiur.DecisionStore.CommandFacts

  @routes [:active_worker, :resume_pending, :capacity_wait, :replacement]

  @spec candidates(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def candidates(identifier, opts \\ []) do
    GenServer.call(Keyword.get(opts, :server, Aiur.DecisionStore), {:override_handoff_candidates, identifier})
  catch
    :exit, _ -> {:error, :store_unavailable}
  end

  @spec record(String.t(), [map()], map(), keyword()) :: :ok | {:error, term()}
  def record(identifier, snapshots, receipt, opts \\ []) do
    GenServer.call(Keyword.get(opts, :server, Aiur.DecisionStore), {:record_override_handoff, identifier, snapshots, receipt})
  catch
    :exit, _ -> {:error, :store_unavailable}
  end

  @spec snapshots(map(), String.t()) :: [map()]
  def snapshots(state, identifier) do
    for {_id, decision} <- state.current,
        record <- decision.overrides,
        eligible?(decision, record, identifier) do
      %{
        decision_id: decision.decision_id,
        action_id: record.action_id,
        merge_version: Map.get(record, :merge_version, 1),
        delivered_at: record.delivered_at,
        pr_number: record.pr_number,
        pr_head_sha: record.pr_head_sha,
        route: record.route,
        worker_head_sha: worker_head(record)
      }
    end
    |> Enum.sort_by(& &1.decision_id)
  end

  @spec apply(map(), String.t(), [map()], map()) :: {:reply, :ok | {:error, term()}, map()}
  def apply(%{writable?: false} = state, _identifier, _snapshots, _receipt), do: {:reply, {:error, :store_read_only}, state}

  def apply(state, identifier, expected, receipt) do
    cond do
      expected != snapshots(state, identifier) -> {:reply, {:error, :stale_override_handoff}, state}
      not valid_receipt?(receipt) -> {:reply, {:error, :override_handoff_head_unconfirmed}, state}
      true -> record_all(state, Enum.filter(expected, &qualifies?(&1, receipt)), receipt)
    end
  end

  defp eligible?(decision, record, identifier) do
    record.action_id == decision.active_action_id and record.state == :delivered and record.route in @routes and
      is_nil(record.corrective_ticket) and record.pr_merged != true and record.ticket.identifier == identifier
  end

  defp worker_head(%{evidence: %{worker_reported: true, head_sha: head}}), do: head
  defp worker_head(_record), do: nil

  defp valid_receipt?(%{head_sha: head, pr_number: number, at: %DateTime{}}), do: is_binary(head) and head != "" and is_integer(number) and number > 0
  defp valid_receipt?(_receipt), do: false

  defp qualifies?(record, %{head_sha: head, pr_number: number, at: at}) do
    head != record.pr_head_sha and (is_nil(record.pr_number) or record.pr_number == number) and DateTime.compare(at, record.delivered_at) == :gt
  end

  defp record_all(state, snapshots, receipt) do
    Enum.reduce_while(snapshots, {:reply, :ok, state}, fn snapshot, {:reply, :ok, acc} ->
      data = %{action_id: snapshot.action_id, head_sha: receipt.head_sha, pr_number: receipt.pr_number, at: receipt.at}

      case CommandFacts.record(acc, snapshot.decision_id, :override_worker_handoff, data, []) do
        {:reply, {:ok, _}, next} -> {:cont, {:reply, :ok, next}}
        {:reply, {:error, reason}, next} -> {:halt, {:reply, {:error, reason}, next}}
      end
    end)
  end
end
