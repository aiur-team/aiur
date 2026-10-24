defmodule Aiur.Instance.LeaseStore do
  @moduledoc "Shared ticket leases and instance heartbeats backed by PostgreSQL."
  use GenServer

  require Logger

  alias Aiur.Instance.Identity
  alias Aiur.Instance.LeaseStore.{Postgres, Renewal, TicketKey}

  @name __MODULE__
  @default_ttl_ms 30_000
  @default_renew_interval_ms div(@default_ttl_ms, 3)
  @default_renew_margin_ms 5_000
  @claim_grace_ms 20_000
  @reconnect_initial_ms 1_000
  @reconnect_max_ms 30_000

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: @name,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 5_000
    }
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, @name))
  end

  @doc "Returns whether the coordination database is configured."
  @spec configured?() :: boolean()
  def configured? do
    is_binary(database_url()) and database_url() != ""
  end

  @doc "Atomically acquires an expired or unheld ticket lease."
  @spec claim(term(), keyword()) :: :acquired | :held | :disabled | {:error, term()}
  def claim(ticket, opts \\ []) do
    if configured?() do
      with {:ok, ticket_key} <- ticket_key(ticket) do
        GenServer.call(
          Keyword.get(opts, :server, @name),
          {:claim, ticket_key, Keyword.get(opts, :ttl_ms, @default_ttl_ms), Keyword.get(opts, :grace_ms, @claim_grace_ms)},
          10_000
        )
      end
    else
      :disabled
    end
  catch
    :exit, reason -> {:error, {:store_unavailable, reason}}
  end

  @doc "Starts a renewal process that follows the current caller's lifetime."
  @spec watch(term(), keyword()) :: :ok | :not_owned | :disabled | {:error, term()}
  def watch(ticket, opts \\ []) do
    if configured?() do
      with {:ok, ticket_key} <- ticket_key(ticket),
           do: watch_configured(ticket_key, Keyword.get(opts, :server, @name), opts)
    else
      :disabled
    end
  end

  defp watch_configured(ticket_key, server, opts) do
    if configured?(), do: watch_owned(ticket_key, server, opts), else: :disabled
  catch
    :exit, reason -> {:error, {:store_unavailable, reason}}
  end

  defp watch_owned(ticket_key, server, opts) do
    case GenServer.call(server, {:watch, ticket_key}) do
      :ok ->
        parent = self()
        interval = Keyword.get(opts, :renew_interval_ms, @default_renew_interval_ms)
        ttl_ms = Keyword.get(opts, :ttl_ms, @default_ttl_ms)
        margin_ms = Keyword.get(opts, :renew_margin_ms, @default_renew_margin_ms)

        {:ok, _pid} =
          Task.start(fn ->
            Renewal.start(parent, ticket_key, interval, ttl_ms, margin_ms, server, opts)
          end)

        :ok

      :not_owned ->
        :not_owned

      {:error, _} = error ->
        error
    end
  end

  @doc "Renews a ticket lease only while this instance still owns it."
  @spec renew(term(), keyword()) :: :ok | {:error, term()}
  def renew(ticket, opts \\ []) do
    with {:ok, ticket_key} <- ticket_key(ticket) do
      request(opts, {:renew, ticket_key, Keyword.get(opts, :ttl_ms, @default_ttl_ms)})
    end
  end

  @doc "Releases a ticket lease only while this instance still owns it."
  @spec release(term(), keyword()) :: :ok | {:error, term()}
  def release(ticket, opts \\ []) do
    with {:ok, ticket_key} <- ticket_key(ticket), do: request(opts, {:release, ticket_key})
  end

  @doc "Returns whether the current instance has a non-expired lease; store uncertainty fails closed."
  @spec owned?(term(), keyword()) :: boolean() | :disabled | :unknown
  def owned?(ticket, opts \\ []) do
    if configured?() do
      case holder(ticket, opts) do
        {:held, holder_id} -> holder_id == current_instance_id(opts)
        :unheld -> false
        :disabled -> :disabled
        :unknown -> :unknown
      end
    else
      :disabled
    end
  end

  @doc "Returns the active holder for a ticket; an expired row is unheld."
  @spec holder(term(), keyword()) :: {:held, String.t()} | :unheld | :disabled | :unknown
  def holder(ticket, opts \\ []) do
    if configured?(), do: lookup_holder(ticket, opts), else: :disabled
  rescue
    _ -> :unknown
  end

  defp lookup_holder(ticket, opts) do
    case ticket_key(ticket) do
      {:ok, key} ->
        case request(opts, {:holder, key}) do
          {:ok, nil} -> :unheld
          {:ok, id} when is_binary(id) -> {:held, id}
          _error -> :unknown
        end

      _error ->
        :unknown
    end
  end

  @doc "Canonical repository-qualified ticket key shared by dispatch, workers and observers."
  @spec ticket_key(term()) :: {:ok, String.t()} | {:error, :invalid_ticket_key}
  defdelegate ticket_key(ticket), to: TicketKey

  @doc "Publishes this instance's opaque metadata and returns the live roster."
  @spec heartbeat(String.t(), map(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def heartbeat(build_version, metadata, opts \\ [])
      when is_binary(build_version) and is_map(metadata) do
    request(
      opts,
      {:heartbeat, build_version, metadata, Keyword.get(opts, :ttl_ms, @default_ttl_ms * 3)}
    )
  end

  @doc "Lists live instance records; database errors are returned, never treated as an empty roster."
  @spec list_live(keyword()) :: {:ok, [map()]} | {:error, term()}
  def list_live(opts \\ []), do: request(opts, :list_live)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    state = %{
      conn: nil,
      url: Keyword.get(opts, :url, database_url()),
      instance_id: Keyword.get(opts, :instance_id, &Identity.current/0),
      leases: Keyword.get(opts, :leases, MapSet.new()),
      opts: opts,
      reconnect_ms: Keyword.get(opts, :reconnect_initial_ms, @reconnect_initial_ms),
      reconnect_max_ms: Keyword.get(opts, :reconnect_max_ms, @reconnect_max_ms),
      outage?: false,
      retry_timer: nil
    }

    send(self(), :connect)
    {:ok, state}
  end

  @impl true
  def handle_call({:claim, key, ttl_ms, grace_ms}, _from, state) do
    instance_id = instance_id(state)

    result =
      query(
        state,
        """
        INSERT INTO aiur_ticket_leases (ticket_key, instance_id, heartbeat_at, expires_at)
        VALUES ($1, $2, clock_timestamp(), clock_timestamp() + make_interval(secs => $3))
        ON CONFLICT (ticket_key) DO UPDATE
        SET instance_id = EXCLUDED.instance_id, heartbeat_at = EXCLUDED.heartbeat_at, expires_at = EXCLUDED.expires_at
        WHERE aiur_ticket_leases.expires_at <= clock_timestamp() - make_interval(secs => $4)
           OR aiur_ticket_leases.instance_id = EXCLUDED.instance_id
        RETURNING ticket_key
        """,
        [key, instance_id, ttl_ms / 1_000, grace_ms / 1_000],
        fn %{num_rows: rows} -> if(rows == 1, do: :acquired, else: :held) end
      )

    state =
      if result == :acquired, do: %{state | leases: MapSet.put(state.leases, key)}, else: state

    reply_with_reconnect(result, state)
  end

  def handle_call({:holder, key}, _from, state) do
    result =
      query(
        state,
        "SELECT instance_id FROM aiur_ticket_leases WHERE ticket_key = $1 AND expires_at > clock_timestamp()",
        [key],
        fn
          %{rows: [[id]]} -> {:ok, id}
          %{rows: []} -> {:ok, nil}
        end
      )

    reply_with_reconnect(result, state)
  end

  def handle_call({:watch, key}, _from, state),
    do: {:reply, if(MapSet.member?(state.leases, key), do: :ok, else: :not_owned), state}

  def handle_call({:renew, key, ttl_ms}, _from, state) do
    result =
      query(
        state,
        """
        UPDATE aiur_ticket_leases SET heartbeat_at = clock_timestamp(),
          expires_at = clock_timestamp() + make_interval(secs => $3)
        WHERE ticket_key = $1 AND instance_id = $2
        RETURNING ticket_key
        """,
        [key, instance_id(state), ttl_ms / 1_000],
        fn %{num_rows: rows} -> if(rows == 1, do: :ok, else: {:error, :lease_lost}) end
      )

    reply_with_reconnect(result, state)
  end

  def handle_call({:release, key}, _from, state) do
    result =
      query(
        state,
        "DELETE FROM aiur_ticket_leases WHERE ticket_key = $1 AND instance_id = $2",
        [key, instance_id(state)],
        fn _ -> :ok end
      )

    state = if result == :ok, do: %{state | leases: MapSet.delete(state.leases, key)}, else: state
    reply_with_reconnect(result, state)
  end

  def handle_call({:heartbeat, build_version, metadata, ttl_ms}, _from, state) do
    encoded = Jason.encode!(metadata)

    result =
      query(
        state,
        """
        INSERT INTO aiur_instances (instance_id, build_version, metadata_json, heartbeat_at, expires_at)
        VALUES ($1, $2, $3, clock_timestamp(), clock_timestamp() + make_interval(secs => $4))
        ON CONFLICT (instance_id) DO UPDATE SET build_version = EXCLUDED.build_version,
          metadata_json = EXCLUDED.metadata_json, heartbeat_at = EXCLUDED.heartbeat_at, expires_at = EXCLUDED.expires_at
        RETURNING instance_id, build_version, metadata_json, heartbeat_at, expires_at
        """,
        [instance_id(state), build_version, encoded, ttl_ms / 1_000],
        &Postgres.decode_instances/1
      )

    reply_with_reconnect(result, state)
  end

  def handle_call(:list_live, _from, state) do
    result =
      query(
        state,
        """
        SELECT instance_id, build_version, metadata_json, heartbeat_at, expires_at
        FROM aiur_instances WHERE expires_at > clock_timestamp() ORDER BY instance_id
        """,
        [],
        &Postgres.decode_instances/1
      )

    reply_with_reconnect(result, state)
  end

  @impl true
  def handle_info(:connect, state) do
    connect_fun = Keyword.get(state.opts, :connect_fun, &connect/1)

    case connect_fun.(state) do
      :disabled ->
        {:noreply, state}

      {:ok, conn} ->
        state = %{state | conn: conn, reconnect_ms: @reconnect_initial_ms, retry_timer: nil}
        state = if state.outage?, do: report_recovered(state), else: state
        {:noreply, state}

      {:error, reason} ->
        state = report_unavailable(state, reason)
        {:noreply, schedule_reconnect(state)}
    end
  end

  def handle_info({:EXIT, conn, reason}, %{conn: conn} = state) when is_pid(conn) do
    state = report_unavailable(%{state | conn: nil}, reason)
    {:noreply, schedule_reconnect(state)}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  defp request(opts, message) do
    if configured?(),
      do: GenServer.call(Keyword.get(opts, :server, @name), message, 10_000),
      else: {:error, :store_not_configured}
  catch
    :exit, reason -> {:error, {:store_unavailable, reason}}
  end

  defp query(state, sql, params, map_fun) do
    case state.conn && Postgrex.query(state.conn, sql, params, timeout: 5_000) do
      {:ok, result} -> map_fun.(result)
      {:error, reason} -> {:error, {:store_unavailable, reason}}
      nil -> {:error, {:store_unavailable, :not_connected}}
    end
  rescue
    error -> {:error, {:store_unavailable, error}}
  end

  defp reply_with_reconnect(
         {:error, {:store_unavailable, reason}} = result,
         %{conn: conn} = state
       )
       when is_pid(conn) do
    Process.exit(conn, :shutdown)
    state = report_unavailable(%{state | conn: nil}, reason) |> schedule_reconnect()
    {:reply, result, state}
  end

  defp reply_with_reconnect(result, state), do: {:reply, result, state}

  defp instance_id(state) do
    case state.instance_id do
      fun when is_function(fun, 0) -> fun.()
      id -> id
    end
  end

  defp current_instance_id(opts) do
    case Keyword.get(opts, :instance_id, &Identity.current/0) do
      fun when is_function(fun, 0) -> fun.()
      id -> id
    end
  end

  defp connect(%{url: url, opts: opts}) when is_binary(url) and url != "" do
    case Postgrex.start_link(Postgres.connection_opts(url) ++ Keyword.take(opts, [:timeout, :types])) do
      {:ok, conn} ->
        case Postgres.create_tables(conn) do
          :ok ->
            {:ok, conn}

          {:error, reason} ->
            Process.exit(conn, :shutdown)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp connect(%{url: nil}), do: :disabled
  defp connect(_state), do: {:error, :store_not_configured}

  defp schedule_reconnect(%{retry_timer: nil} = state) do
    timer = Process.send_after(self(), :connect, state.reconnect_ms)

    %{
      state
      | retry_timer: timer,
        reconnect_ms: min(state.reconnect_ms * 2, state.reconnect_max_ms)
    }
  end

  defp schedule_reconnect(state), do: state

  defp report_unavailable(%{outage?: true} = state, reason) do
    Logger.warning("shared ticket lease store remains unavailable: #{inspect(reason)}")
    state
  end

  defp report_unavailable(state, reason) do
    Logger.error("shared ticket lease store unavailable: #{inspect(reason)}")

    emit_store_alert(
      state,
      "system.instance.ownership_unknown",
      true,
      "Shared ownership cannot be checked; dispatch is held and observers fail closed."
    )

    %{state | outage?: true}
  end

  defp report_recovered(state) do
    emit_store_alert(
      state,
      "system.instance.ownership_unknown.resolved",
      false,
      "Shared ticket ownership store is reachable again."
    )

    %{state | outage?: false}
  end

  defp emit_store_alert(state, topic, needs_attention, message) do
    case Keyword.get(state.opts, :alert_fun, &Aiur.Alerts.emit_system/2) do
      fun when is_function(fun, 2) ->
        fun.(topic, message: message, needs_attention: needs_attention, severity: "warning")

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  defp database_url do
    Application.get_env(:aiur, :lease_database_url) || System.get_env("AIUR_LEASE_DATABASE_URL")
  end
end
