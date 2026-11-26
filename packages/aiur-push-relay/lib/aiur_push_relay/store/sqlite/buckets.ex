defmodule AiurPushRelay.Store.SQLite.Buckets do
  @moduledoc "Persistent SQLite token buckets shared by handle and source-IP limits."
  alias Exqlite.Sqlite3, as: DB

  def consume(db, key, capacity, per_hour, now) do
    case query(db, "SELECT tokens, updated_at FROM buckets WHERE bucket_key = ?", [key]) do
      [] -> persist(db, key, nil, now, capacity, per_hour, now)
      [[tokens, updated_at]] -> persist(db, key, tokens, updated_at, capacity, per_hour, now)
    end
  end

  defp persist(db, key, tokens, updated_at, capacity, per_hour, now) do
    case AiurPushRelay.RateLimit.consume(tokens, updated_at, capacity, per_hour, now) do
      {:ok, remaining} -> save(db, key, remaining, now)
      limited -> limited
    end
  end

  defp save(db, key, tokens, now) do
    query(
      db,
      "INSERT INTO buckets VALUES (?,?,?) ON CONFLICT(bucket_key) DO UPDATE SET tokens=excluded.tokens, updated_at=excluded.updated_at",
      [key, tokens, now]
    )

    :ok
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
