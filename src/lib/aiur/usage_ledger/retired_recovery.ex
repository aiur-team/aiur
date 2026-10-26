defmodule Aiur.UsageLedger.RetiredRecovery do
  @moduledoc false

  alias Aiur.UsageLedger.{CounterPolicy, Record, RetiredKeys}

  @spec valid_tail?(list(), non_neg_integer(), non_neg_integer()) :: boolean()
  def valid_tail?(records, floor, checkpoint_position) do
    last_position =
      case List.last(records) do
        nil -> checkpoint_position
        record -> record.position
      end

    expected = if last_position > floor, do: Enum.to_list((floor + 1)..last_position), else: []
    Enum.map(records, & &1.position) == expected and last_position >= checkpoint_position
  end

  @spec replay_tail(map(), non_neg_integer(), list(), String.t()) ::
          {:ok, CounterPolicy.state(), non_neg_integer()} | {:error, atom()}
  def replay_tail(policy, checkpoint_position, records, keys_path) do
    with {:ok, keys} <- RetiredKeys.load(keys_path) do
      policy = %{policy | idempotency: MapSet.union(policy.idempotency, keys)}

      records
      |> Enum.filter(&(&1.position > checkpoint_position))
      |> Enum.reduce_while({:ok, policy, checkpoint_position}, fn record, {:ok, current, position} ->
        if record.position == position + 1 do
          replay_record(record, current, position)
        else
          {:halt, {:error, :invalid_positions}}
        end
      end)
    end
  end

  defp replay_record(record, policy, position) do
    case CounterPolicy.apply(policy, record.envelope) do
      {:ok, %{state: next, delta: delta}} ->
        if Record.matches_delta?(record, delta), do: {:cont, {:ok, next, position + 1}}, else: {:halt, {:error, :record_delta_mismatch}}

      {:duplicate, _policy} ->
        {:halt, {:error, :duplicate_canonical_record}}

      {:error, reason, _policy} ->
        {:halt, {:error, reason}}
    end
  end
end
