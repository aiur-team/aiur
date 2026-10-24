defmodule Aiur.Instance.LeaseStore.RepositoryLease do
  @moduledoc "Repository leader lease operations and persistence queries."

  alias Aiur.GitHub.Config, as: GitHubConfig
  alias Aiur.Instance.Identity
  alias Aiur.Instance.LeaseStore

  @default_ttl_ms 30_000

  @spec claim(String.t(), keyword()) :: :acquired | :held | {:error, term()}
  def claim(repository, opts \\ []), do: call(:claim, repository, opts)

  @spec renew(String.t(), keyword()) :: :ok | {:error, term()}
  def renew(repository, opts \\ []), do: call(:renew, repository, opts)

  @spec leader(String.t(), keyword()) :: map() | :unheld | :disabled | :unknown
  def leader(repository, opts \\ []) do
    case {LeaseStore.configured?(), repository_key(repository)} do
      {false, _} ->
        :disabled

      {true, {:ok, repo}} ->
        case request(opts, {:repository_lease, :read, repo, nil, nil}) do
          {:ok, nil} -> :unheld
          {:ok, lease} -> lease
          _ -> :unknown
        end

      _ ->
        :unknown
    end
  rescue
    _ -> :unknown
  end

  @spec leader_owned?(String.t(), keyword()) :: boolean() | :disabled | :unknown
  def leader_owned?(repository, opts \\ []) do
    case leader(repository, opts) do
      %{instance_id: holder} -> holder == instance_id(opts)
      other when other in [:unheld, :disabled, :unknown] -> other == :disabled or false
    end
  end

  @spec repository_key(String.t() | nil) :: {:ok, String.t()} | {:error, :invalid_repository}
  def repository_key(repository \\ nil) do
    case String.split(String.downcase(String.trim(to_string(repository || GitHubConfig.repo()))), "/") do
      [owner, name] when owner != "" and name != "" -> {:ok, "#{owner}/#{name}"}
      _ -> {:error, :invalid_repository}
    end
  rescue
    _ -> {:error, :invalid_repository}
  end

  @doc false
  @spec handle(atom(), map(), String.t(), pos_integer() | nil, String.t() | nil) :: term()
  def handle(state, action, repo, ttl_ms, _instance_id) do
    query =
      case action do
        :claim ->
          {"""
           INSERT INTO aiur_repository_leases (repository, instance_id, heartbeat_at, expires_at)
           VALUES ($1, $2, clock_timestamp(), clock_timestamp() + make_interval(secs => $3))
           ON CONFLICT (repository) DO UPDATE SET instance_id = EXCLUDED.instance_id,
             heartbeat_at = EXCLUDED.heartbeat_at, expires_at = EXCLUDED.expires_at
           WHERE aiur_repository_leases.expires_at <= clock_timestamp()
              OR aiur_repository_leases.instance_id = EXCLUDED.instance_id
           RETURNING repository
           """, [repo, instance_id(state), ttl_ms / 1_000], fn %{num_rows: rows} -> if(rows == 1, do: :acquired, else: :held) end}

        :renew ->
          {"""
           UPDATE aiur_repository_leases SET heartbeat_at = clock_timestamp(),
             expires_at = clock_timestamp() + make_interval(secs => $3)
           WHERE repository = $1 AND instance_id = $2 AND expires_at > clock_timestamp()
           RETURNING repository
           """, [repo, instance_id(state), ttl_ms / 1_000], fn %{num_rows: rows} -> if(rows == 1, do: :ok, else: {:error, :lease_lost}) end}

        :read ->
          {"SELECT instance_id, heartbeat_at, expires_at FROM aiur_repository_leases WHERE repository = $1 AND expires_at > clock_timestamp()", [repo],
           fn
             %{rows: [[id, heartbeat_at, expires_at]]} -> {:ok, %{instance_id: id, heartbeat_at: heartbeat_at, expires_at: expires_at}}
             %{rows: []} -> {:ok, nil}
           end}
      end

    {sql, params, mapper} = query

    result =
      case state.conn && Postgrex.query(state.conn, sql, params, timeout: 5_000) do
        {:ok, response} -> mapper.(response)
        {:error, error} -> {:error, {:store_unavailable, error}}
        nil -> {:error, {:store_unavailable, :not_connected}}
      end

    result
  rescue
    error -> {{:error, {:store_unavailable, error}}, state}
  end

  defp call(action, repository, opts) do
    with {:ok, repo} <- repository_key(repository) do
      request(opts, {:repository_lease, action, repo, Keyword.get(opts, :ttl_ms, @default_ttl_ms), instance_id(opts)})
    end
  end

  defp request(opts, message) do
    if LeaseStore.configured?(),
      do: GenServer.call(Keyword.get(opts, :server, LeaseStore), message, 10_000),
      else: {:error, {:store_unavailable, :store_not_configured}}
  catch
    :exit, reason -> {:error, {:store_unavailable, reason}}
  end

  defp instance_id(opts) do
    case Keyword.get(opts, :instance_id, &Identity.current/0) do
      fun when is_function(fun, 0) -> fun.()
      id -> id
    end
  end
end
