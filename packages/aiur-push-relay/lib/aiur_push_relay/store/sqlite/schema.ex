defmodule AiurPushRelay.Store.SQLite.Schema do
  @moduledoc false

  def sql do
    """
    PRAGMA journal_mode=WAL;
    PRAGMA busy_timeout=100;
    CREATE TABLE IF NOT EXISTS handles (
      handle TEXT PRIMARY KEY, platform TEXT, push_token TEXT, app_topic TEXT,
      environment TEXT, send_secret_sha256 BLOB, created_at INTEGER, last_used_at INTEGER,
      gone INTEGER NOT NULL DEFAULT 0);
    CREATE TABLE IF NOT EXISTS sends (
      handle TEXT, idempotency_key TEXT, status INTEGER, created_at INTEGER, delivery TEXT,
      PRIMARY KEY(handle, idempotency_key));
    CREATE TABLE IF NOT EXISTS send_log (handle TEXT, at INTEGER, size INTEGER, status INTEGER);
    CREATE TABLE IF NOT EXISTS buckets (bucket_key TEXT PRIMARY KEY, tokens REAL, updated_at INTEGER);
    CREATE INDEX IF NOT EXISTS sends_age ON sends(created_at);
    CREATE INDEX IF NOT EXISTS send_log_age ON send_log(at);
    CREATE INDEX IF NOT EXISTS buckets_age ON buckets(updated_at);
    """
  end
end
