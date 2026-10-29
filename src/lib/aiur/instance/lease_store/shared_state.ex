defmodule Aiur.Instance.LeaseStore.SharedState do
  @moduledoc false

  @name Aiur.Instance.LeaseStore

  @spec admit_github_budget(String.t(), String.t(), String.t(), String.t(), non_neg_integer(), pos_integer(), keyword()) :: term()
  def admit_github_budget(lease_id, credential_key, resource, consumer_key, limit, points \\ 1, opts \\ []) do
    call({:admit_github_budget, lease_id, credential_key, resource, consumer_key, limit, points}, opts, :disabled)
  end

  @spec release_github_budget(String.t(), keyword()) :: term()
  def release_github_budget(lease_id, opts \\ []), do: call({:release_github_budget, lease_id}, opts, :disabled)

  @spec publish_github_budget_hold(String.t(), String.t(), DateTime.t(), keyword()) :: term()
  def publish_github_budget_hold(credential_key, resource, until_at, opts \\ []) do
    call({:publish_github_budget_hold, credential_key, resource, until_at}, opts, :disabled)
  end

  @spec github_budget_hold(String.t(), String.t(), keyword()) :: term()
  def github_budget_hold(credential_key, resource, opts \\ []),
    do: call({:github_budget_hold, credential_key, resource}, opts, :disabled)

  @spec publish_provider_meter(map(), keyword()) :: term()
  def publish_provider_meter(snapshot, opts \\ []), do: call({:publish_provider_meter, snapshot}, opts, :disabled)
  @spec shared_provider_meter(atom(), keyword()) :: term()
  def shared_provider_meter(provider, opts \\ []), do: call({:shared_provider_meter, provider}, opts, :disabled)
  @spec publish_github_quota_snapshot(map(), keyword()) :: term()
  def publish_github_quota_snapshot(snapshot, opts \\ []), do: call({:publish_github_quota_snapshot, snapshot}, opts, :disabled)
  @spec github_quota_snapshots(keyword()) :: term()
  def github_quota_snapshots(opts \\ []), do: call(:github_quota_snapshots, opts, :disabled)

  @spec budget_coordination_status(keyword()) :: %{available?: boolean(), live_count: pos_integer()}
  def budget_coordination_status(opts \\ []) do
    if configured?() do
      GenServer.call(Keyword.get(opts, :server, @name), {:shared_state, :budget_coordination_status})
    else
      %{available?: false, live_count: last_live_count()}
    end
  catch
    :exit, _reason -> %{available?: false, live_count: last_live_count()}
  end

  @doc false
  defdelegate last_live_count(), to: Aiur.Instance.LeaseStore.LiveCount, as: :read

  @doc false
  defdelegate remember_live_count(count), to: Aiur.Instance.LeaseStore.LiveCount, as: :remember

  @spec handle_call(term(), map()) :: {:reply, term(), map()}
  def handle_call(:last_live_count, state), do: {:reply, state.known_instance_count, state}

  def handle_call(:budget_coordination_status, state),
    do: {:reply, %{available?: is_pid(state.conn), live_count: state.known_instance_count}, state}

  def handle_call({:admit_github_budget, lease_id, credential_key, resource, consumer_key, limit, points}, state) do
    result =
      if is_pid(state.conn) do
        admit(state.conn, lease_id, credential_key, resource, consumer_key, instance_id(state), limit, points)
      else
        {:error, {:store_unavailable, :not_connected}}
      end

    {:reply, result, state}
  end

  def handle_call({:release_github_budget, lease_id}, state),
    do: query(state, "DELETE FROM aiur_github_budget_admissions WHERE lease_id = $1", [lease_id], fn _ -> :ok end)

  def handle_call({:publish_github_budget_hold, credential_key, resource, until_at}, state) do
    query(
      state,
      "INSERT INTO aiur_github_budget_holds (credential_key, resource, until_at) VALUES ($1, $2, $3) ON CONFLICT (credential_key, resource) DO UPDATE SET until_at = GREATEST(aiur_github_budget_holds.until_at, EXCLUDED.until_at), updated_at = clock_timestamp()",
      [credential_key, resource, until_at],
      fn _ -> :ok end
    )
  end

  def handle_call({:github_budget_hold, credential_key, resource}, state) do
    query(
      state,
      "SELECT until_at FROM aiur_github_budget_holds WHERE credential_key = $1 AND resource IN ($2, '*') AND until_at > clock_timestamp() ORDER BY until_at DESC LIMIT 1",
      [credential_key, resource],
      fn
        %{rows: [[until_at]]} -> {:ok, until_at}
        %{rows: []} -> {:ok, nil}
      end
    )
  end

  def handle_call({:publish_provider_meter, snapshot}, state) do
    key = "#{snapshot.provider}:#{snapshot.backend}"
    observed_at = snapshot.observed_at || DateTime.utc_now()
    payload = :erlang.term_to_binary(snapshot, [:compressed])

    query(
      state,
      "INSERT INTO aiur_provider_meter_snapshots (snapshot_key, provider, account_key, snapshot_payload, observed_at, instance_id) VALUES ($1, $2, $3, $4, $5, $6) ON CONFLICT (snapshot_key) DO UPDATE SET account_key = EXCLUDED.account_key, snapshot_payload = EXCLUDED.snapshot_payload, observed_at = EXCLUDED.observed_at, instance_id = EXCLUDED.instance_id, updated_at = clock_timestamp() WHERE aiur_provider_meter_snapshots.observed_at <= EXCLUDED.observed_at",
      [key, Atom.to_string(snapshot.provider), Atom.to_string(snapshot.backend), payload, observed_at, instance_id(state)],
      fn _ -> :ok end
    )
  end

  def handle_call({:shared_provider_meter, provider}, state) do
    query(
      state,
      "SELECT snapshot_payload FROM aiur_provider_meter_snapshots WHERE provider = $1 ORDER BY observed_at DESC LIMIT 1",
      [Atom.to_string(provider)],
      fn
        %{rows: [[payload]]} -> decode_provider_meter(payload, provider)
        %{rows: []} -> {:ok, nil}
      end
    )
  end

  def handle_call({:publish_github_quota_snapshot, snapshot}, state) do
    payload = :erlang.term_to_binary(snapshot, [:compressed])
    observed_at = DateTime.utc_now()

    query(
      state,
      "INSERT INTO aiur_github_quota_snapshots (instance_id, snapshot_payload, observed_at) VALUES ($1, $2, $3) ON CONFLICT (instance_id) DO UPDATE SET snapshot_payload = EXCLUDED.snapshot_payload, observed_at = EXCLUDED.observed_at, updated_at = clock_timestamp()",
      [instance_id(state), payload, observed_at],
      fn _ -> :ok end
    )
  end

  def handle_call(:github_quota_snapshots, state) do
    query(
      state,
      "SELECT instance_id, snapshot_payload, observed_at FROM aiur_github_quota_snapshots WHERE observed_at > clock_timestamp() - interval '1 hour' ORDER BY instance_id",
      [],
      &decode_quota_snapshots/1
    )
  end

  def handle_call(_message, state), do: {:reply, {:error, :unknown_shared_state_command}, state}

  defp call(message, opts, disabled) do
    if configured?() do
      GenServer.call(Keyword.get(opts, :server, @name), {:shared_state, message})
    else
      disabled
    end
  catch
    :exit, reason -> {:error, {:store_unavailable, reason}}
  end

  defp configured? do
    url = Application.get_env(:aiur, :lease_database_url) || System.get_env("AIUR_LEASE_DATABASE_URL")
    is_binary(url) and url != ""
  end

  defp admit(conn, lease_id, credential_key, resource, consumer_key, instance_id, limit, points) do
    Postgrex.transaction(conn, fn transaction_conn ->
      _ = Postgrex.query!(transaction_conn, "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [credential_key <> ":" <> resource])

      _ =
        Postgrex.query!(
          transaction_conn,
          "DELETE FROM aiur_github_budget_admissions WHERE credential_key = $1 AND resource = $2 AND admitted_at <= clock_timestamp() - interval '1 hour'",
          [credential_key, resource]
        )

      %{rows: [[used, oldest]]} =
        Postgrex.query!(
          transaction_conn,
          "SELECT COALESCE(SUM(points), 0), MIN(admitted_at) FROM aiur_github_budget_admissions WHERE credential_key = $1 AND resource = $2 AND admitted_at > clock_timestamp() - interval '1 hour'",
          [credential_key, resource]
        )

      cond do
        limit == 0 or used + points <= limit ->
          _ =
            Postgrex.query!(
              transaction_conn,
              "INSERT INTO aiur_github_budget_admissions (lease_id, credential_key, instance_id, resource, consumer_key, points) VALUES ($1, $2, $3, $4, $5, $6)",
              [lease_id, credential_key, instance_id, resource, consumer_key, points]
            )

          :admitted

        not is_nil(oldest) ->
          {:held, DateTime.add(oldest, 3600, :second)}
      end
    end)
    |> case do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, {:store_unavailable, reason}}
    end
  rescue
    error -> {:error, {:store_unavailable, error}}
  end

  defp query(%{conn: conn} = state, sql, params, map_fun) do
    case conn && Postgrex.query(conn, sql, params, timeout: 5_000) do
      {:ok, result} -> {:reply, map_fun.(result), state}
      {:error, reason} -> {:reply, {:error, {:store_unavailable, reason}}, state}
      nil -> {:reply, {:error, {:store_unavailable, :not_connected}}, state}
    end
  rescue
    error -> {:reply, {:error, {:store_unavailable, error}}, state}
  end

  defp decode_provider_meter(payload, _provider) do
    case :erlang.binary_to_term(payload, [:safe]) do
      snapshot when is_map(snapshot) -> {:ok, snapshot}
      _invalid -> {:error, {:store_unavailable, :invalid_provider_snapshot}}
    end
  rescue
    _error -> {:error, {:store_unavailable, :invalid_provider_snapshot}}
  end

  defp decode_quota_snapshots(%{rows: rows}) do
    Enum.reduce_while(rows, {:ok, []}, fn [instance_id, payload, observed_at], {:ok, acc} ->
      case :erlang.binary_to_term(payload, [:safe]) do
        snapshot when is_map(snapshot) ->
          {:cont, {:ok, [%{instance_id: instance_id, observed_at: observed_at, snapshot: snapshot} | acc]}}

        _invalid ->
          {:halt, {:error, {:store_unavailable, :invalid_quota_snapshot}}}
      end
    end)
    |> case do
      {:ok, snapshots} -> {:ok, Enum.reverse(snapshots)}
      error -> error
    end
  rescue
    _error -> {:error, {:store_unavailable, :invalid_quota_snapshot}}
  end

  defp instance_id(state) do
    case state.instance_id do
      fun when is_function(fun, 0) -> fun.()
      id -> id
    end
  end
end
