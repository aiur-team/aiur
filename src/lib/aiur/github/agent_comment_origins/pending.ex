defmodule Aiur.GitHub.AgentCommentOrigins.Pending do
  @moduledoc false

  @default_ttl_ms :timer.minutes(5)

  @type t :: %{
          operation_id: String.t(),
          started_at_ms: integer(),
          kind: String.t(),
          command: String.t() | nil,
          observed_ids: [String.t()]
        }

  @spec new(String.t(), String.t(), String.t() | nil) :: t()
  def new(operation_id, kind, command \\ nil)
      when is_binary(operation_id) and is_binary(kind) and (is_binary(command) or is_nil(command)) do
    %{
      operation_id: operation_id,
      started_at_ms: System.system_time(:millisecond),
      kind: kind,
      command: command,
      observed_ids: []
    }
  end

  @spec normalize(term()) :: {:ok, [t()]} | {:error, term()}
  def normalize(pending) when is_list(pending) do
    with {:ok, operations} <- normalize_operations(pending),
         :ok <- ensure_unique_operation_ids(operations) do
      {:ok, operations}
    end
  end

  def normalize(_pending), do: {:error, :invalid_pending_operations}

  @spec active_and_expired([t()]) :: {[t()], [t()]}
  def active_and_expired(pending) when is_list(pending) do
    now = System.system_time(:millisecond)
    ttl_ms = Application.get_env(:aiur, :agent_comment_origin_pending_ttl_ms, @default_ttl_ms)

    Enum.split_with(pending, fn %{started_at_ms: started_at_ms} ->
      is_integer(ttl_ms) and ttl_ms > 0 and started_at_ms <= now and now - started_at_ms < ttl_ms
    end)
  end

  defp normalize_operations(pending) do
    Enum.reduce_while(pending, {:ok, []}, fn operation, {:ok, operations} ->
      case normalize_operation(operation) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | operations]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, operations} -> {:ok, Enum.reverse(operations)}
      error -> error
    end
  end

  defp normalize_operation(%{} = operation) do
    with operation_id when is_binary(operation_id) and operation_id != "" <- value(operation, :operation_id),
         started_at_ms when is_integer(started_at_ms) and started_at_ms >= 0 <- value(operation, :started_at_ms, 0),
         kind when is_binary(kind) and kind != "" <- value(operation, :kind, "legacy"),
         {:ok, command} <- normalize_command(value(operation, :command, nil)),
         {:ok, observed_ids} <- normalize_ids(value(operation, :observed_ids, [])) do
      {:ok,
       %{
         operation_id: operation_id,
         started_at_ms: started_at_ms,
         kind: kind,
         command: command,
         observed_ids: observed_ids
       }}
    else
      _other -> {:error, :invalid_pending_operation}
    end
  end

  defp normalize_operation(operation_id) when is_binary(operation_id) and operation_id != "" do
    {:ok, %{operation_id: operation_id, started_at_ms: 0, kind: "legacy", command: nil, observed_ids: []}}
  end

  defp normalize_operation(_operation), do: {:error, :invalid_pending_operation}

  defp ensure_unique_operation_ids(operations) do
    if length(operations) == length(Enum.uniq_by(operations, & &1.operation_id)) do
      :ok
    else
      {:error, :duplicate_pending_operation}
    end
  end

  defp value(operation, key, default \\ nil) do
    case Map.fetch(operation, key) do
      {:ok, value} -> value
      :error -> Map.get(operation, Atom.to_string(key), default)
    end
  end

  defp normalize_ids(ids) when is_list(ids) do
    if Enum.all?(ids, &(is_binary(&1) and &1 != "")) do
      {:ok, Enum.uniq(ids)}
    else
      {:error, :invalid_pending_observed_ids}
    end
  end

  defp normalize_ids(_ids), do: {:error, :invalid_pending_observed_ids}

  defp normalize_command(nil), do: {:ok, nil}
  defp normalize_command(command) when is_binary(command) and command != "", do: {:ok, command}
  defp normalize_command(_command), do: {:error, :invalid_pending_command}
end
