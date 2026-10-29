defmodule Aiur.Orchestrator.OperatorMessages.PendingStore do
  @moduledoc false

  require Logger

  alias Aiur.{AgentQueueItem, AgentQueueStore, Config.Paths, JsonStore}

  @filename "pending-operator-messages.json"

  @spec load!() :: AgentQueueStore.t()
  def load! do
    case JsonStore.read(path(), :missing) do
      {:ok, :missing} ->
        AgentQueueStore.new()

      {:ok, %{"version" => 1, "items" => encoded}} when is_list(encoded) ->
        items = Enum.map(encoded, &decode_item!/1)
        AgentQueueStore.restore_persisted_items(AgentQueueStore.new(), items)

      {:ok, _} ->
        fail!(:invalid_document)

      {:error, reason} ->
        fail!({:read_failed, reason})
    end
  end

  @spec save!(AgentQueueStore.t()) :: :ok
  def save!(%AgentQueueStore{} = store) do
    items =
      store.items
      |> Map.values()
      |> Enum.filter(& &1.persist_across_restart?)
      |> Enum.sort_by(& &1.sequence)
      |> Enum.map(&:erlang.term_to_binary(&1, [:compressed]))
      |> Enum.map(&Base.encode64/1)

    JsonStore.write!(path(), %{"version" => 1, "items" => items})
  rescue
    error -> fail!({:write_failed, error.__struct__, Exception.message(error)})
  end

  defp decode_item!(encoded) when is_binary(encoded) do
    with {:ok, binary} <- Base.decode64(encoded),
         %AgentQueueItem{persist_across_restart?: true, category: :operator_message} = item <- :erlang.binary_to_term(binary, [:safe]),
         true <- valid_item?(item) do
      item
    else
      _ -> fail!(:invalid_item)
    end
  rescue
    _ -> fail!(:invalid_item)
  end

  defp decode_item!(_), do: fail!(:invalid_item)

  defp valid_item?(%AgentQueueItem{id: id, sequence: seq, target_issue_identifier: target, status: status, inserted_at: %DateTime{}}) do
    is_integer(id) and id > 0 and is_integer(seq) and seq > 0 and is_binary(target) and
      status in [:pending, :delivered, :consumed, :failed, :superseded]
  end

  defp valid_item?(_), do: false

  defp path do
    case Application.get_env(:aiur, :pending_operator_messages_store_path) do
      path when is_binary(path) and path != "" ->
        path

      _ ->
        case Paths.decision_state_dir() do
          {:ok, dir} -> Path.join(dir, @filename)
          {:error, reason} -> fail!({:state_path_unavailable, reason})
        end
    end
  end

  defp fail!(reason) do
    Logger.error("Pending operator messages could not be recovered or persisted: #{inspect(reason)}")
    raise "pending operator message persistence failed: #{inspect(reason)}"
  end
end
