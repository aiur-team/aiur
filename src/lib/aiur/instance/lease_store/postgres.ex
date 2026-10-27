defmodule Aiur.Instance.LeaseStore.Postgres do
  @moduledoc false

  @spec create_tables(Postgrex.conn()) :: :ok | {:error, term()}
  def create_tables(conn) do
    with {:ok, _} <-
           Postgrex.query(
             conn,
             """
             CREATE TABLE IF NOT EXISTS aiur_ticket_leases (
               ticket_key text PRIMARY KEY,
               instance_id text NOT NULL,
               heartbeat_at timestamptz NOT NULL,
               expires_at timestamptz NOT NULL
             )
             """,
             []
           ),
         {:ok, _} <-
           Postgrex.query(
             conn,
             """
             CREATE TABLE IF NOT EXISTS aiur_repository_leases (
               repository text PRIMARY KEY,
               instance_id text NOT NULL,
               heartbeat_at timestamptz NOT NULL,
               expires_at timestamptz NOT NULL
             )
             """,
             []
           ),
         {:ok, _} <-
           Postgrex.query(
             conn,
             """
             CREATE TABLE IF NOT EXISTS aiur_instances (
               instance_id text PRIMARY KEY,
               build_version text NOT NULL,
               metadata_json text NOT NULL,
               heartbeat_at timestamptz NOT NULL,
               expires_at timestamptz NOT NULL
             )
             """,
             []
           ),
         {:ok, _} <-
           Postgrex.query(
             conn,
             """
             CREATE TABLE IF NOT EXISTS aiur_github_budget_admissions (
               lease_id text PRIMARY KEY,
               credential_key text NOT NULL,
               instance_id text NOT NULL,
               resource text NOT NULL,
               consumer_key text NOT NULL,
               points integer NOT NULL DEFAULT 1,
               admitted_at timestamptz NOT NULL DEFAULT clock_timestamp()
             )
             """,
             []
           ),
         {:ok, _} <- Postgrex.query(conn, "ALTER TABLE aiur_github_budget_admissions ADD COLUMN IF NOT EXISTS points integer NOT NULL DEFAULT 1", []),
         {:ok, _} <-
           Postgrex.query(
             conn,
             "CREATE INDEX IF NOT EXISTS aiur_github_budget_admissions_window ON aiur_github_budget_admissions (credential_key, resource, admitted_at)",
             []
           ),
         {:ok, _} <-
           Postgrex.query(
             conn,
             """
             CREATE TABLE IF NOT EXISTS aiur_github_budget_holds (
               credential_key text NOT NULL,
               resource text NOT NULL,
               until_at timestamptz NOT NULL,
               updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
               PRIMARY KEY (credential_key, resource)
             )
             """,
             []
           ),
         {:ok, _} <-
           Postgrex.query(
             conn,
             """
             CREATE TABLE IF NOT EXISTS aiur_provider_meter_snapshots (
               snapshot_key text PRIMARY KEY,
               provider text NOT NULL,
               account_key text NOT NULL,
               snapshot_payload bytea NOT NULL,
               observed_at timestamptz NOT NULL,
               instance_id text NOT NULL,
               updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
             )
             """,
             []
           ),
         {:ok, _} <-
           Postgrex.query(
             conn,
             """
             CREATE TABLE IF NOT EXISTS aiur_github_quota_snapshots (
               instance_id text PRIMARY KEY,
               snapshot_payload bytea NOT NULL,
               observed_at timestamptz NOT NULL,
               updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
             )
             """,
             []
           ) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @spec decode_instances(%{rows: list()}) :: {:ok, [map()]} | {:error, :invalid_instance_metadata}
  def decode_instances(%{rows: rows}) do
    Enum.reduce_while(rows, {:ok, []}, fn [id, version, metadata, heartbeat_at, expires_at], {:ok, acc} ->
      case Jason.decode(metadata) do
        {:ok, decoded} when is_map(decoded) ->
          item = %{
            instance_id: id,
            build_version: version,
            metadata: decoded,
            heartbeat_at: heartbeat_at,
            expires_at: expires_at
          }

          {:cont, {:ok, [item | acc]}}

        _ ->
          {:halt, {:error, :invalid_instance_metadata}}
      end
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      error -> error
    end
  end

  @spec connection_opts(String.t()) :: keyword()
  def connection_opts(url) do
    uri = URI.parse(url)
    [username, password] = String.split(uri.userinfo || ":", ":", parts: 2)
    database = uri.path |> to_string() |> String.trim_leading("/") |> URI.decode()
    remote? = uri.host not in [nil, "localhost", "127.0.0.1", "::1"]

    [
      hostname: uri.host,
      port: uri.port || 5432,
      username: URI.decode(username),
      password: URI.decode(password),
      database: database
    ] ++
      if(remote?, do: [ssl: [verify: :verify_peer, cacerts: :public_key.cacerts_get()]], else: [])
  end
end
