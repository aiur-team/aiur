defmodule Aiur.Orchestrator.OperatorMessages.PendingStore do
  @moduledoc false

  require Logger

  alias Aiur.{AgentQueueItem, AgentQueueStore, Config.Paths, Fs, JsonStore, Signal}

  @filename "pending-operator-messages.json"
  @max_persisted_items 256
  @recovery_alert "operator_message_queue.recovery"

  @doc false
  @spec capacity() :: pos_integer()
  def capacity, do: @max_persisted_items

  @doc false
  @spec active_count(AgentQueueStore.t()) :: non_neg_integer()
  def active_count(%AgentQueueStore{} = store),
    do: Enum.count(Map.values(store.items), &persistable?/1)

  @spec load() :: AgentQueueStore.t()
  def load do
    case path() do
      {:ok, path} -> load_path(path)
      {:error, reason} -> recover(nil, {:state_path_unavailable, reason})
    end
  end

  @spec save(AgentQueueStore.t()) :: :ok | {:error, term()}
  def save(%AgentQueueStore{} = store) do
    items =
      store.items
      |> Map.values()
      |> Enum.filter(&persistable?/1)
      |> Enum.sort_by(& &1.sequence)

    persist(items)
  rescue
    error ->
      reason = {:write_failed, error.__struct__, Exception.message(error)}
      Logger.error("Pending operator messages could not be persisted: #{inspect(reason)}")
      {:error, reason}
  end

  defp load_path(path) do
    case ensure_private_file(path) do
      :ok -> load_document(path)
      {:error, reason} -> recover(path, {:permission_failed, reason})
    end
  end

  defp load_document(path) do
    case JsonStore.read(path, :missing) do
      {:ok, :missing} ->
        AgentQueueStore.new()

      {:ok, %{"version" => 1, "items" => encoded}} when is_list(encoded) ->
        load_items(path, encoded)

      {:ok, _invalid_document} ->
        recover(path, :invalid_document)

      {:error, reason} ->
        recover(path, {:read_failed, reason})
    end
  end

  defp ensure_private_file(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> File.chmod(path, 0o600)
      {:ok, %File.Stat{type: :symlink}} -> {:error, {:symlink_rejected, path}}
      {:ok, %File.Stat{}} -> {:error, {:not_a_regular_file, path}}
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp load_items(path, encoded) do
    case decode_items(encoded) do
      {:ok, items} -> restore_items(path, items)
      {:error, reason} -> recover(path, reason)
    end
  end

  defp restore_items(path, items) do
    restorable_items =
      items
      |> Enum.filter(&persistable?/1)
      |> Enum.map(&restore_unacknowledged_claim/1)

    persist_pruned_items(path, items, restorable_items)
    AgentQueueStore.restore_persisted_items(AgentQueueStore.new(), restorable_items)
  end

  defp persist_pruned_items(_path, items, items), do: :ok

  defp persist_pruned_items(path, _items, restorable_items) do
    case write_items(path, restorable_items) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Could not prune completed operator messages from persisted state: #{inspect(reason)}")
    end
  end

  defp decode_items(encoded) do
    Enum.reduce_while(encoded, {:ok, []}, fn item, {:ok, items} ->
      case decode_item(item) do
        {:ok, decoded} -> {:cont, {:ok, [decoded | items]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      error -> error
    end
  end

  defp decode_item(encoded) when is_binary(encoded) do
    with {:ok, binary} <- Base.decode64(encoded),
         %AgentQueueItem{persist_across_restart?: true, category: :operator_message} = item <-
           :erlang.binary_to_term(binary, [:safe]),
         true <- valid_item?(item) do
      {:ok, item}
    else
      _ -> {:error, :invalid_item}
    end
  rescue
    _ -> {:error, :invalid_item}
  end

  defp decode_item(_), do: {:error, :invalid_item}

  defp valid_item?(%AgentQueueItem{
         id: id,
         sequence: seq,
         target_issue_identifier: target,
         status: status,
         inserted_at: %DateTime{}
       }) do
    is_integer(id) and id > 0 and is_integer(seq) and seq > 0 and is_binary(target) and
      status in [:pending, :delivered, :consumed, :failed, :superseded]
  end

  defp valid_item?(_), do: false

  defp persistable?(%AgentQueueItem{persist_across_restart?: true, status: :pending}), do: true

  defp persistable?(%AgentQueueItem{persist_across_restart?: true, status: :delivered, provider_delivered_at: nil}),
    do: true

  defp persistable?(_), do: false

  defp restore_unacknowledged_claim(%AgentQueueItem{status: :delivered, provider_delivered_at: nil} = item),
    do: %{item | status: :pending, delivered_at: nil}

  defp restore_unacknowledged_claim(item), do: item

  defp persist(items) do
    case path() do
      {:ok, path} -> write_items(path, items)
      {:error, reason} -> {:error, {:state_path_unavailable, reason}}
    end
  rescue
    error -> {:error, {:write_failed, error.__struct__, Exception.message(error)}}
  end

  defp write_items(path, items) do
    encoded =
      items
      |> Enum.map(&:erlang.term_to_binary(&1, [:compressed]))
      |> Enum.map(&Base.encode64/1)

    document = %{"version" => 1, "items" => encoded}

    JsonStore.write!(path, document, mode: 0o600)
    :ok
  rescue
    error -> {:error, {:write_failed, error.__struct__, Exception.message(error)}}
  end

  defp path do
    case Application.get_env(:aiur, :pending_operator_messages_store_path) do
      path when is_binary(path) and path != "" ->
        {:ok, path}

      _ ->
        case Paths.decision_state_dir() do
          {:ok, dir} -> {:ok, Path.join(dir, @filename)}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp recover(path, reason) do
    quarantine = if is_binary(path), do: quarantine(path), else: :not_applicable
    message = recovery_message(path, reason, quarantine)

    Logger.error(message)

    case Signal.agent_alert(@recovery_alert, message,
           reason: message,
           severity: "warning",
           needs_attention: true
         ) do
      :ok -> :ok
      {:error, alert_reason} -> Logger.warning("Pending operator queue recovery alert failed: #{inspect(alert_reason)}")
    end

    AgentQueueStore.new()
  rescue
    error ->
      Logger.error("Pending operator queue recovery reporting failed: #{Exception.message(error)}")
      AgentQueueStore.new()
  end

  defp quarantine(path) do
    case Fs.quarantine(path) do
      :ok -> :quarantined
      {:error, reason} -> {:quarantine_failed, reason}
    end
  rescue
    error -> {:quarantine_failed, Exception.message(error)}
  end

  defp recovery_message(path, reason, quarantine) do
    "Pending operator message state could not be recovered" <>
      if(path, do: " at #{path}", else: " (state path unavailable)") <>
      ": #{inspect(reason)}; recovery: #{inspect(quarantine)}. Starting with an empty queue; affected queued messages may be lost."
  end
end
