defmodule Aiur.Usage.GasLedger do
  @moduledoc "Durable, idempotent records for paid API spend outside coding providers."
  use GenServer

  alias Aiur.{Config, Journal}

  @max_rows 100_000
  @identifier ~r/\A[A-Za-z0-9._:-]{1,256}\z/

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Records exact USD spend once per idempotency key."
  @spec record(map(), GenServer.server()) :: {:ok, map()} | {:duplicate, map()} | {:error, atom()}
  def record(attrs, server \\ __MODULE__) when is_map(attrs), do: GenServer.call(server, {:record, attrs})

  @doc "Returns one user's retained Gas records and exact total."
  @spec snapshot(String.t(), GenServer.server()) :: map()
  def snapshot(user_id, server \\ __MODULE__) when is_binary(user_id), do: GenServer.call(server, {:snapshot, user_id})

  @impl true
  def init(opts) do
    with {:ok, root} <- state_root(opts),
         path = Path.join(root, "gas-spend.ndjson"),
         :ok <- Journal.prepare(root, path),
         {:ok, rows, nil} <- Journal.replay(path, &decode/1, max_file_bytes: 64 * 1_024 * 1_024, max_record_bytes: 4_096) do
      {:ok, %{path: path, rows: Enum.reverse(rows), by_id: Map.new(rows, &{&1.id, &1})}}
    else
      _ -> {:stop, :gas_ledger_unavailable}
    end
  end

  @impl true
  def handle_call({:record, attrs}, _from, state) do
    case normalize(attrs) do
      {:ok, row} ->
        case Map.fetch(state.by_id, row.id) do
          {:ok, ^row} -> {:reply, {:duplicate, row}, state}
          {:ok, _different} -> {:reply, {:error, :idempotency_conflict}, state}
          :error when map_size(state.by_id) >= @max_rows -> {:reply, {:error, :capacity_exhausted}, state}
          :error -> append(row, state)
        end

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:snapshot, user_id}, _from, state) do
    records = Enum.filter(state.rows, &(&1.user_id == user_id))
    total = Enum.reduce(records, Decimal.new(0), &Decimal.add(&1.amount_usd, &2))
    {:reply, %{records: records, spent_usd: total, record_count: length(records)}, state}
  end

  defp append(row, state) do
    case Journal.append(state.path, encode(row)) do
      :ok ->
        next = %{state | rows: [row | state.rows], by_id: Map.put(state.by_id, row.id, row)}
        {:reply, {:ok, row}, next}

      {:error, _reason} ->
        {:reply, {:error, :write_failed}, state}
    end
  end

  defp normalize(attrs) do
    with {:ok, id} <- identifier(value(attrs, :id)),
         {:ok, user_id} <- identifier(value(attrs, :user_id)),
         {:ok, api} <- identifier(value(attrs, :api)),
         {:ok, amount} <- amount(value(attrs, :amount_usd)),
         {:ok, occurred_at} <- datetime(value(attrs, :occurred_at)),
         {:ok, basis} <- basis(value(attrs, :basis, "actual")),
         {:ok, ticket} <- optional_identifier(value(attrs, :ticket)),
         {:ok, conversation} <- optional_identifier(value(attrs, :conversation_id)) do
      {:ok, %{id: id, user_id: user_id, api: api, amount_usd: amount, occurred_at: occurred_at, basis: basis, ticket: ticket, conversation_id: conversation}}
    end
  end

  defp decode(%{"id" => id} = row) do
    case normalize(row) do
      {:ok, %{id: ^id} = decoded} -> {:ok, decoded}
      _ -> {:error, :invalid_gas_record}
    end
  end

  defp decode(_row), do: {:error, :invalid_gas_record}

  defp encode(row) do
    Map.new(row, fn
      {:amount_usd, amount} -> {"amount_usd", Decimal.to_string(amount, :normal)}
      {:occurred_at, at} -> {"occurred_at", DateTime.to_iso8601(at)}
      {key, value} -> {Atom.to_string(key), value}
    end)
  end

  defp identifier(value) when is_binary(value) do
    if String.match?(value, @identifier) and not String.match?(value, ~r/(?:secret|credential|token|password|bearer|api[-_]?key)/i),
      do: {:ok, value},
      else: {:error, :invalid_identifier}
  end

  defp identifier(_value), do: {:error, :invalid_identifier}
  defp optional_identifier(nil), do: {:ok, nil}
  defp optional_identifier(value), do: identifier(value)

  defp amount(value) when is_binary(value) do
    case Decimal.parse(value) do
      {%Decimal{} = amount, ""} -> if Decimal.negative?(amount), do: {:error, :invalid_amount}, else: {:ok, amount}
      _ -> {:error, :invalid_amount}
    end
  end

  defp amount(value) when is_integer(value) and value >= 0, do: {:ok, Decimal.new(value)}
  defp amount(_value), do: {:error, :invalid_amount}

  defp datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, 0} -> {:ok, DateTime.truncate(datetime, :second)}
      _ -> {:error, :invalid_occurred_at}
    end
  end

  defp datetime(%DateTime{utc_offset: 0, std_offset: 0} = value), do: {:ok, DateTime.truncate(value, :second)}
  defp datetime(_value), do: {:error, :invalid_occurred_at}
  defp basis(value) when value in ["actual", "estimate"], do: {:ok, value}
  defp basis(_value), do: {:error, :invalid_basis}

  defp state_root(opts) do
    case Keyword.get(opts, :state_dir) do
      path when is_binary(path) and path != "" -> {:ok, path}
      _ -> Config.Paths.usage_ledger_state_dir()
    end
  end

  defp value(map, key, default \\ nil), do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
