defmodule Aiur.Opencode.Db do
  @moduledoc """
  Isolation wrapper for direct reads/writes against opencode's SQLite store
  at `~/.local/share/opencode/opencode.db`.

  opencode is the upstream owner of the schema — see
  `src/docs/notes/opencode-row-shapes-1.17.10.md` for the row shapes Aiur
  injects. This module hides `:exqlite` configuration, sets a generous
  `busy_timeout`, retries once on `SQLITE_BUSY`, and exposes a small
  insert + fetch surface plus `^msg` / `^prt` ULID-style ID generators.
  """

  require Logger

  alias Aiur.Opencode.Config
  alias Exqlite.Basic
  alias Exqlite.Connection

  @default_busy_timeout_ms 5_000

  @spec path() :: Path.t()
  def path do
    case Application.get_env(:aiur, :opencode_db_path_override) do
      value when is_binary(value) and value != "" ->
        Path.expand(value)

      _ ->
        case Config.db_path() do
          path when is_binary(path) and path != "" -> Path.expand(path)
          _ -> Path.expand("~/.local/share/opencode/opencode.db")
        end
    end
  end

  @doc """
  Open a connection, set `PRAGMA busy_timeout`, call `fun.(conn)`, then close.
  """
  @spec with_conn((Connection.t() -> result)) :: result | {:error, term()}
        when result: var
  def with_conn(fun) when is_function(fun, 1) do
    with {:ok, conn} <- open(path()) do
      try do
        fun.(conn)
      after
        Basic.close(conn)
      end
    end
  end

  @doc """
  Run `fun` inside one `BEGIN IMMEDIATE … COMMIT` transaction on a single
  fresh connection. Use for batched replays — `replay_history/1` in
  `SessionWriter` is the canonical caller. Without this, each individual
  `insert_message` / `insert_part` opens its own connection and contends
  for the SQLite write lock on every row; 5 concurrent writers each doing
  ~100 inserts blow past the 10 s `await_replay` timeout (observed on
  2026-05-22). With this, each writer acquires the lock once, performs
  all inserts, then releases — turning 500 contended writes into 5
  serialized transactions.

  On error inside `fun`, ROLLBACK fires and the error propagates. The
  passed conn must be used with the `_in/N` insert variants below.
  """
  @spec with_transaction((Connection.t() -> result)) :: result | {:error, term()}
        when result: var
  def with_transaction(fun) when is_function(fun, 1) do
    with_conn(fn conn ->
      case Basic.exec(conn, "BEGIN IMMEDIATE") do
        {:ok, _, _, _} ->
          try do
            result = fun.(conn)
            _ = Basic.exec(conn, "COMMIT")
            result
          catch
            kind, reason ->
              _ = Basic.exec(conn, "ROLLBACK")
              :erlang.raise(kind, reason, __STACKTRACE__)
          end

        {:error, err, _} ->
          {:error, err}
      end
    end)
  end

  @doc """
  Insert one `message` row. `data_map` becomes the `data` JSON column;
  `id` and `session_id` populate the corresponding SQL columns.
  Retries once on `SQLITE_BUSY` so concurrent opencode writes don't fail us.
  """
  @spec insert_message(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def insert_message(session_id, message_id, data_map)
      when is_binary(session_id) and is_binary(message_id) and is_map(data_map) do
    with_conn(fn conn -> insert_message(conn, session_id, message_id, data_map) end)
  end

  @doc """
  Variant that reuses a caller-owned connection — for batching inside
  `with_transaction/1`.
  """
  @spec insert_message(Connection.t(), String.t(), String.t(), map()) ::
          :ok | {:error, term()}
  def insert_message(conn, session_id, message_id, data_map)
      when is_binary(session_id) and is_binary(message_id) and is_map(data_map) do
    now = System.os_time(:millisecond)

    sql = """
    INSERT INTO message (id, session_id, time_created, time_updated, data)
    VALUES (?, ?, ?, ?, ?)
    """

    with {:ok, data_json} <- encode(data_map) do
      exec_with_retry(conn, sql, [message_id, session_id, now, now, data_json])
    end
  end

  @doc """
  Insert one `part` row. `data_map` becomes the `data` JSON column;
  `id`, `message_id`, `session_id` populate the corresponding SQL columns.
  Retries once on `SQLITE_BUSY`.
  """
  @spec insert_part(String.t(), String.t(), String.t(), map()) :: :ok | {:error, term()}
  def insert_part(session_id, message_id, part_id, data_map)
      when is_binary(session_id) and is_binary(message_id) and is_binary(part_id) and is_map(data_map) do
    with_conn(fn conn -> insert_part(conn, session_id, message_id, part_id, data_map) end)
  end

  @doc """
  Variant that reuses a caller-owned connection — for batching inside
  `with_transaction/1`.
  """
  @spec insert_part(Connection.t(), String.t(), String.t(), String.t(), map()) ::
          :ok | {:error, term()}
  def insert_part(conn, session_id, message_id, part_id, data_map)
      when is_binary(session_id) and is_binary(message_id) and is_binary(part_id) and is_map(data_map) do
    now = System.os_time(:millisecond)

    sql = """
    INSERT INTO part (id, message_id, session_id, time_created, time_updated, data)
    VALUES (?, ?, ?, ?, ?, ?)
    """

    with {:ok, data_json} <- encode(data_map) do
      exec_with_retry(conn, sql, [part_id, message_id, session_id, now, now, data_json])
    end
  end

  @doc """
  Delete one message and all of its parts. Used to replace a live-refreshing
  status row (e.g. the #132 per-ticket cost line) in place: the previous row is
  removed before the new one is inserted, so the scrollback keeps a single
  current line rather than accumulating a stack of stale ones. No-op semantics —
  deleting an already-absent id succeeds.
  """
  @spec delete_message(String.t(), String.t()) :: :ok | {:error, term()}
  def delete_message(session_id, message_id)
      when is_binary(session_id) and is_binary(message_id) do
    with_conn(fn conn -> delete_message(conn, session_id, message_id) end)
  end

  @spec delete_message(Connection.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def delete_message(conn, session_id, message_id)
      when is_binary(session_id) and is_binary(message_id) do
    with :ok <- exec_with_retry(conn, "DELETE FROM part WHERE message_id = ? AND session_id = ?", [message_id, session_id]) do
      exec_with_retry(conn, "DELETE FROM message WHERE id = ? AND session_id = ?", [message_id, session_id])
    end
  end

  @doc """
  Read one message + all its parts back. Used by the synthetic-stream
  round-trip in `Aiur.Opencode.ChatCompletions` to replay just-written
  rows as SSE deltas.
  """
  @spec fetch_message_with_parts(String.t(), String.t()) ::
          {:ok, %{message: map(), parts: [map()]}} | {:error, term()}
  def fetch_message_with_parts(session_id, message_id)
      when is_binary(session_id) and is_binary(message_id) do
    with_conn(fn conn ->
      with {:ok, msg_data_json} <- fetch_message_data(conn, session_id, message_id),
           {:ok, msg_data} <- Jason.decode(msg_data_json),
           {:ok, part_rows} <- fetch_part_rows(conn, message_id),
           {:ok, parts} <- decode_parts(part_rows) do
        {:ok, %{message: msg_data, parts: parts}}
      end
    end)
  end

  @doc """
  Generate an opencode-compatible `msg_` id. Crockford base32-like
  monotonic-time + entropy; matches opencode's `^msg[A-Z0-9]+` pattern.
  """
  @spec msg_id() :: String.t()
  def msg_id, do: prefixed_id("msg_")

  @doc """
  Generate an opencode-compatible `prt_` id.
  """
  @spec prt_id() :: String.t()
  def prt_id, do: prefixed_id("prt_")

  @doc """
  Generate an opencode-compatible `call_` id for tool parts.
  """
  @spec call_id() :: String.t()
  def call_id, do: prefixed_id("call_")

  # ----------------------------------------------------------------- internals

  defp open(db_path) do
    case Basic.open(db_path) do
      {:ok, conn} ->
        # WAL is opencode's default; just set the busy_timeout so concurrent
        # writes wait instead of returning SQLITE_BUSY immediately.
        case Basic.exec(conn, "PRAGMA busy_timeout = #{@default_busy_timeout_ms}") do
          {:ok, _, _, _} ->
            {:ok, conn}

          other ->
            Basic.close(conn)
            {:error, other}
        end

      error ->
        error
    end
  end

  defp exec_with_retry(conn, sql, params, attempt \\ 1) do
    case Basic.exec(conn, sql, params) do
      {:ok, _, _, _} ->
        :ok

      {:error, %{message: "database is locked"}, _} when attempt == 1 ->
        Logger.warning("opencode_db retry sql=#{summarize(sql)} reason=locked")
        Process.sleep(100)
        exec_with_retry(conn, sql, params, attempt + 1)

      {:error, err, _} ->
        {:error, err}
    end
  end

  defp fetch_message_data(conn, session_id, message_id) do
    sql = "SELECT data FROM message WHERE id = ? AND session_id = ? LIMIT 1"

    case Basic.rows(Basic.exec(conn, sql, [message_id, session_id])) do
      {:ok, [[json]], _} -> {:ok, json}
      {:ok, [], _} -> {:error, :not_found}
      other -> {:error, other}
    end
  end

  defp fetch_part_rows(conn, message_id) do
    sql = "SELECT data FROM part WHERE message_id = ? ORDER BY time_created"

    case Basic.rows(Basic.exec(conn, sql, [message_id])) do
      {:ok, rows, _} -> {:ok, rows}
      other -> {:error, other}
    end
  end

  defp decode_parts(rows) do
    rows
    |> Enum.reduce_while({:ok, []}, fn [json], {:ok, acc} ->
      case Jason.decode(json) do
        {:ok, decoded} -> {:cont, {:ok, [decoded | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, parts} -> {:ok, Enum.reverse(parts)}
      err -> err
    end
  end

  defp encode(data_map) do
    case Jason.encode(data_map) do
      {:ok, _} = ok -> ok
      {:error, %Jason.EncodeError{} = err} -> {:error, err}
    end
  end

  # Crockford-ish base32: 0-9 + A-Z minus I, L, O, U. opencode uses a similar
  # alphabet for its `msg_` / `prt_` IDs. The exact bit layout doesn't matter
  # — opencode only validates the regex `^(msg|prt|call)[A-Z0-9]+`.
  @alphabet ~c"0123456789ABCDEFGHJKMNPQRSTVWXYZ"

  # opencode's TUI orders parts by lexical `id`, so multiple parts of the same
  # message (step-start → body → step-finish) inserted within a single
  # millisecond must produce IDs that sort in call order. The naive form
  # (timestamp + random) breaks this when collisions occur within 1 ms —
  # step-finish can land before the body part, and the renderer never reaches
  # the body, leaving the assistant message visually empty. Follow the ULID
  # monotonic rule: when the timestamp matches the prior call from this
  # process, increment the entropy by 1 instead of regenerating it.
  defp prefixed_id(prefix) do
    time_ms = System.os_time(:millisecond)
    entropy = next_entropy(time_ms)
    prefix <> encode_base32(time_ms, 10) <> encode_base32(entropy, 16)
  end

  defp next_entropy(time_ms) do
    entropy =
      case Process.get(:aiur_opencode_last_id) do
        {^time_ms, last_entropy} -> last_entropy + 1
        _ -> :binary.decode_unsigned(:crypto.strong_rand_bytes(10))
      end

    Process.put(:aiur_opencode_last_id, {time_ms, entropy})
    entropy
  end

  defp encode_base32(value, width) when is_integer(value) and value >= 0 do
    do_encode_base32(value, width, [])
  end

  defp do_encode_base32(_value, 0, acc), do: List.to_string(acc)

  defp do_encode_base32(value, width, acc) do
    digit = rem(value, 32)
    char = Enum.at(@alphabet, digit)
    do_encode_base32(div(value, 32), width - 1, [char | acc])
  end

  defp summarize(sql) do
    sql |> String.split() |> Enum.take(4) |> Enum.join(" ")
  end
end
