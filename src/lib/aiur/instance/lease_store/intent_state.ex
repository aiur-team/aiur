defmodule Aiur.Instance.LeaseStore.IntentState do
  @moduledoc false
  # SQL for shared intent (schema S4). Rides the LeaseStore connection, so reconnect,
  # TLS, timeouts and the fail-closed alert are inherited.

  alias Aiur.Intent.Change

  @batch 100
  @overlap_seconds 60

  @spec create_tables(Postgrex.conn()) :: :ok | {:error, term()}
  def create_tables(conn) do
    statements = [
      """
      CREATE TABLE IF NOT EXISTS aiur_intent_changes (
        seq bigserial NOT NULL,
        change_id uuid PRIMARY KEY,
        hlc_wall_ms bigint NOT NULL,
        hlc_counter integer NOT NULL,
        origin_gateway text NOT NULL,
        slot text NOT NULL CHECK (slot IN ('human','executor','default')),
        author_id text NOT NULL,
        entity_kind text NOT NULL,
        entity_key text NOT NULL,
        field text NOT NULL,
        value_json jsonb NOT NULL,
        supersedes uuid NULL,
        force boolean NOT NULL DEFAULT false,
        reason text NULL,
        received_at timestamptz NOT NULL DEFAULT clock_timestamp()
      )
      """,
      "CREATE UNIQUE INDEX IF NOT EXISTS aiur_intent_changes_seq ON aiur_intent_changes (seq)",
      """
      CREATE TABLE IF NOT EXISTS aiur_intent_registers (
        entity_kind text NOT NULL, entity_key text NOT NULL, field text NOT NULL,
        winning_change_id uuid NOT NULL, value_json jsonb NOT NULL,
        PRIMARY KEY (entity_kind, entity_key, field)
      )
      """
    ]

    Enum.reduce_while(statements, :ok, fn sql, :ok ->
      case Postgrex.query(conn, sql, []) do
        {:ok, _} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @doc "Inserts up to #{@batch} changes in one transaction; returns the ids the database now holds."
  @spec publish(Postgrex.conn(), [Change.t()]) :: {:ok, [String.t()]} | {:error, term()}
  def publish(conn, changes) do
    batch = Enum.take(changes, @batch)

    Postgrex.transaction(conn, fn tx ->
      Enum.each(batch, fn c ->
        Postgrex.query!(
          tx,
          """
          INSERT INTO aiur_intent_changes
            (change_id, hlc_wall_ms, hlc_counter, origin_gateway, slot, author_id, entity_kind, entity_key, field, value_json, supersedes, force, reason)
          VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13)
          ON CONFLICT (change_id) DO NOTHING
          """,
          [
            Change.uuid_to_binary(c.change_id),
            c.hlc_wall_ms,
            c.hlc_counter,
            c.origin_gateway,
            c.slot,
            c.author_id,
            c.entity_kind,
            c.entity_key,
            c.field,
            c.value_json,
            Change.uuid_to_binary(c.supersedes),
            c.force,
            c.reason
          ]
        )
      end)

      Enum.map(batch, & &1.change_id)
    end)
  end

  @cols "seq, change_id, hlc_wall_ms, hlc_counter, origin_gateway, slot, author_id, entity_kind, entity_key, field, value_json, supersedes, force, reason, received_at"

  @doc """
  Up to `limit` rows after `cursor`, paged on `seq` alone. With `overlap: true` the rows at or
  below the cursor received in the last #{@overlap_seconds}s come first, outside the page count
  (bigserial is allocated at insert, not commit, so a late commit can land under the cursor).
  """
  @spec changes_since(Postgrex.conn(), non_neg_integer(), pos_integer(), boolean()) :: {:ok, [Change.t()]} | {:error, term()}
  def changes_since(conn, cursor, limit, overlap? \\ false) do
    with {:ok, late} <- if(overlap?, do: late_rows(conn, cursor), else: {:ok, []}),
         {:ok, page} <- query_rows(conn, "SELECT #{@cols} FROM aiur_intent_changes WHERE seq > $1 ORDER BY seq LIMIT $2", [cursor, limit]) do
      {:ok, late ++ page}
    end
  end

  defp late_rows(conn, cursor) do
    query_rows(
      conn,
      "SELECT #{@cols} FROM aiur_intent_changes WHERE seq <= $1 AND received_at > clock_timestamp() - interval '#{@overlap_seconds} seconds' ORDER BY seq",
      [cursor]
    )
  end

  defp query_rows(conn, sql, params) do
    case Postgrex.query(conn, sql, params, timeout: 5_000) do
      {:ok, %{rows: rows}} -> {:ok, Enum.map(rows, &row/1)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp row([seq, id, w, n, origin, slot, author, kind, key, field, value, sup, force, reason, at]) do
    %Change{
      seq: seq,
      change_id: Change.uuid_from_binary(id),
      hlc_wall_ms: w,
      hlc_counter: n,
      origin_gateway: origin,
      slot: slot,
      author_id: author,
      entity_kind: kind,
      entity_key: key,
      field: field,
      value_json: value,
      supersedes: Change.uuid_from_binary(sup),
      force: force,
      reason: reason,
      received_at: at
    }
  end
end
