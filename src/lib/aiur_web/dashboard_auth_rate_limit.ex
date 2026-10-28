defmodule AiurWeb.DashboardAuthRateLimit.Store do
  @moduledoc false
  use GenServer

  @name __MODULE__
  @max_clients 10_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: @name)
  @spec allow(:inet.ip_address(), integer(), pos_integer(), pos_integer()) :: boolean()
  def allow(client, now, window, limit), do: GenServer.call(@name, {:allow, client, now, window, limit})

  @impl GenServer
  def init(_opts), do: {:ok, %{requests: %{}, cleanup_at: 0}}

  @impl GenServer
  def handle_call({:allow, client, now, window, limit}, _from, state) do
    requests =
      if now >= state.cleanup_at do
        Map.filter(state.requests, fn {_key, %{last_seen: last_seen}} -> now - last_seen < window end)
      else
        state.requests
      end

    client_requests = Map.get(requests, client, %{timestamps: [], last_seen: now})
    timestamps = Enum.filter(client_requests.timestamps, &(now - &1 < window))
    at_capacity? = map_size(requests) >= @max_clients and not Map.has_key?(requests, client)
    allowed? = length(timestamps) < limit and not at_capacity?

    next =
      if allowed? do
        Map.put(requests, client, %{timestamps: [now | timestamps], last_seen: now})
      else
        requests
      end

    {:reply, allowed?, %{state | requests: next, cleanup_at: max(state.cleanup_at, now + window)}}
  end
end

defmodule AiurWeb.DashboardAuthRateLimit do
  @moduledoc false
  @behaviour Plug
  import Plug.Conn
  require Logger

  alias AiurWeb.DashboardAuthRateLimit.Store
  @window_ms 60_000
  @limit 20
  # ponytail: once 10,000 distinct client IPs are active in one window, new
  # clients get a conservative 429 until older entries expire; the cap bounds
  # memory when a trusted proxy exposes attacker-controlled client addresses.
  @paths MapSet.new([
           {"GET", ["auth", "login"]},
           {"GET", ["auth", "google"]},
           {"GET", ["auth", "google", "callback"]},
           {"POST", ["auth", "passkeys", "authentication", "challenge"]},
           {"POST", ["auth", "passkeys", "authentication", "finish"]},
           {"POST", ["auth", "passkeys", "registration", "challenge"]},
           {"POST", ["auth", "passkeys", "registration", "finish"]}
         ])

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    if MapSet.member?(@paths, {conn.method, conn.path_info}) do
      client = conn.remote_ip
      now = System.monotonic_time(:millisecond)

      if allow?(client, now) do
        register_failure_log(conn, client)
      else
        Logger.warning("Dashboard sign-in rate limited method=#{conn.method} path=#{conn.request_path} client_ip=#{inspect(client)}")
        conn |> put_resp_header("retry-after", "60") |> send_resp(429, "Too many sign-in attempts") |> halt()
      end
    else
      conn
    end
  end

  defp allow?(client, now) do
    if Process.whereis(Store) do
      Store.allow(client, now, @window_ms, @limit)
    else
      true
    end
  end

  defp register_failure_log(conn, client) do
    register_before_send(conn, fn response ->
      if response.status >= 400 do
        Logger.warning("Dashboard sign-in failed method=#{conn.method} path=#{conn.request_path} status=#{response.status} client_ip=#{inspect(client)}")
      end

      response
    end)
  end
end
