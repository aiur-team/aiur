defmodule AiurPushRelay.Store.SQLite do
  @moduledoc "Owns the SQLite connection so registry, idempotency, and bucket writes stay atomic."
  use GenServer
  @behaviour AiurPushRelay.Store
  alias Exqlite.Sqlite3, as: DB

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  @impl true
  def create(server, row), do: GenServer.call(server, {:create, row})
  @impl true
  def get(server, handle), do: GenServer.call(server, {:get, handle})
  @impl true
  def delete(server, handle), do: GenServer.call(server, {:delete, handle})

  @impl true
  def reserve(server, row, envelope, now),
    do: GenServer.call(server, {:reserve, row, envelope, now})

  @impl true
  def consume(server, key, capacity, per_hour, now),
    do: GenServer.call(server, {:consume, key, capacity, per_hour, now})

  @impl true
  def finish(server, handle, key, status),
    do: GenServer.call(server, {:finish, handle, key, status})

  @impl true
  def release(server, handle, key), do: GenServer.call(server, {:release, handle, key})
  @impl true
  def health(server), do: GenServer.call(server, :health)

  @impl true
  def init(opts) do
    with {:ok, db} <- DB.open(Keyword.fetch!(opts, :path)),
         :ok <- DB.execute(db, AiurPushRelay.Store.SQLite.Schema.sql()) do
      Process.send_after(self(), :prune, 600_000)

      {:ok,
       %{
         db: db,
         log_retention_days: Keyword.get(opts, :log_retention_days, 7),
         send_limits: Keyword.get(opts, :send_limits, %{burst: 10, per_hour: 60})
       }}
    else
      {:error, _} -> {:stop, :store_unavailable}
    end
  end

  @impl true
  def handle_call(operation, _, %{db: db} = state) do
    result = transaction(db, fn -> execute(db, operation, state) end)
    {:reply, result, state}
  end

  @impl true
  def handle_info(:prune, %{db: db} = state) do
    transaction(db, fn -> prune(db, System.system_time(:second), state.log_retention_days) end)
    Process.send_after(self(), :prune, 600_000)
    {:noreply, state}
  end

  @impl true
  def terminate(_, %{db: db}), do: DB.close(db)

  defp execute(db, :health, _state) do
    [[1]] = query(db, "SELECT 1", [])
    :ok
  end

  defp execute(db, {:create, row}, _state) do
    query(db, "INSERT INTO handles VALUES (?,?,?,?,?,?,?,?,?)", [
      row.handle,
      row.platform,
      row.push_token,
      row.app_topic,
      row.environment,
      {:blob, row.send_secret_sha256},
      row.created_at,
      row.created_at,
      0
    ])

    :ok
  end

  defp execute(db, {:get, handle}, _state) do
    case query(db, "SELECT * FROM handles WHERE handle = ?", [handle]) do
      [] -> {:error, :handle_unknown}
      [values] -> {:ok, handle_row(values)}
    end
  end

  defp execute(db, {:delete, handle}, _state) do
    query(db, "DELETE FROM handles WHERE handle = ?", [handle])
    query(db, "DELETE FROM sends WHERE handle = ?", [handle])
    :ok
  end

  defp execute(db, {:reserve, row, envelope, now}, state) do
    prune(db, now, state.log_retention_days)

    case execute(db, {:get, row.handle}, state) do
      {:ok, %{gone: false}} -> reserve_send(db, row.handle, envelope, now, state)
      {:ok, %{gone: true}} -> {:error, :handle_gone}
      error -> error
    end
  end

  defp execute(db, {:consume, key, capacity, per_hour, now}, _state),
    do: AiurPushRelay.Store.SQLite.Buckets.consume(db, key, capacity, per_hour, now)

  defp execute(db, {:release, handle, key}, _state) do
    query(db, "DELETE FROM sends WHERE handle = ? AND idempotency_key = ?", [handle, key])
    :ok
  end

  defp execute(db, {:finish, handle, key, status}, _state) do
    if status == :gone, do: query(db, "UPDATE handles SET gone = 1 WHERE handle = ?", [handle])

    query(db, "UPDATE sends SET delivery = ? WHERE handle = ? AND idempotency_key = ?", [
      to_string(status),
      handle,
      key
    ])

    :ok
  end

  defp reserve_send(db, handle, envelope, now, state) do
    case query(db, "SELECT status FROM sends WHERE handle = ? AND idempotency_key = ?", [
           handle,
           envelope["idempotency_key"]
         ]) do
      [[status]] ->
        {:duplicate, status}

      [] ->
        limits = state.send_limits

        case AiurPushRelay.Store.SQLite.Buckets.consume(
               db,
               "handle:" <> handle,
               limits.burst,
               limits.per_hour,
               now
             ) do
          :ok -> insert_send(db, handle, envelope, now)
          limited -> limited
        end
    end
  end

  defp insert_send(db, handle, envelope, now) do
    query(db, "INSERT INTO sends VALUES (?,?,202,?,'queued')", [
      handle,
      envelope["idempotency_key"],
      now
    ])

    query(db, "INSERT INTO send_log VALUES (?,?,?,202)", [
      handle,
      now,
      byte_size(envelope["sealed"])
    ])

    query(db, "UPDATE handles SET last_used_at = ? WHERE handle = ?", [now, handle])
    :new
  end

  defp prune(db, now, retention_days) do
    query(db, "DELETE FROM sends WHERE created_at <= ?", [now - 86_400])
    query(db, "DELETE FROM send_log WHERE at <= ?", [now - retention_days * 86_400])
    :ok
  end

  defp handle_row([handle, platform, token, topic, env, hash, created, used, gone]) do
    %{
      handle: handle,
      platform: platform,
      push_token: token,
      app_topic: topic,
      environment: env,
      send_secret_sha256: hash,
      created_at: created,
      last_used_at: used,
      gone: gone == 1
    }
  end

  defp transaction(db, fun) do
    with :ok <- DB.execute(db, "BEGIN IMMEDIATE") do
      try do
        result = fun.()
        :ok = DB.execute(db, "COMMIT")
        result
      rescue
        _ ->
          DB.execute(db, "ROLLBACK")
          {:error, :store_unavailable}
      end
    else
      _ -> {:error, :store_unavailable}
    end
  end

  defp query(db, sql, params) do
    {:ok, statement} = DB.prepare(db, sql)

    try do
      :ok = DB.bind(statement, params)
      {:ok, rows} = DB.fetch_all(db, statement)
      rows
    after
      DB.release(db, statement)
    end
  end
end
