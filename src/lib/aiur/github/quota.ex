defmodule Aiur.GitHub.Quota do
  @moduledoc """
  Fleet-wide view of the primary GitHub API budgets used by Aiur.

  GitHub returns an authoritative budget snapshot on every API response. This
  process retains those snapshots, rejects requests against an exhausted
  resource until its reset, sheds new dispatch at the low-water floor, and
  keeps coarse rolling attribution for the shared credential.

  Attribution is kept in the same unit and over the same span the meter
  reports, because a ranking that does not reconcile with the budget beside it
  names the wrong leader (#1805):

    * GraphQL bills *points*, not calls. A catalog query costing 26 points and
      a one-point read are both "one request", so a request-count ranking is
      blind to the queries that actually drain the budget. Each observation
      carries the cost the response reported in `rateLimit { cost }` where the
      query asked for it, and one point where it did not.
    * The span is the live quota window (`reset_at - 1h`), not a rolling hour,
      so the attributed span and the meter's `used` count the same calls.
    * Coverage is published alongside the ranking. Aiur cannot see every call
      billed to the credential, and an unmeasured majority presented as a
      leader invites acting on 0.04% of the spend, so the snapshot states what
      share of the window's real spend the ranking accounts for.

  The primary windows are not the only way GitHub refuses a call. Secondary
  (abuse) rate limits reject with `403`/`429` while `x-ratelimit-remaining`
  still reads healthy, so nothing in the primary windows records the refusal
  and the caller is free to retry straight into another rejection. Those
  rejections are tracked separately as a per-resource backoff honouring
  `Retry-After`, which holds callers off exactly as an exhausted window does.
  """

  use GenServer

  alias Aiur.GitHub.Budget
  alias Aiur.GitHub.Config, as: GitHubConfig
  alias Aiur.GitHub.Credential
  alias Aiur.GitHub.CredentialRegistry
  alias Aiur.GitHub.{HoldSweep, RequestLog, RequestOrigin, Transport}

  alias Aiur.GitHub.Quota.{Attribution, Coverage, ShellObservations, SnapshotCache, Windows}
  alias Aiur.Signal

  @empty_coverage %{resources: %{}, estimated?: false}
  @unknown_snapshot %{
    state: :unknown,
    windows: %{},
    credential_windows: %{},
    attribution: [],
    callers: [],
    coverage: @empty_coverage,
    reconciliation: %{},
    backoffs: []
  }

  @type request :: map()
  @type hold :: %{
          resource: String.t(),
          remaining: non_neg_integer(),
          limit: pos_integer(),
          reset_at: DateTime.t(),
          observed_at: DateTime.t()
        }

  @refresh_interval_ms 60_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @spec observe(GenServer.server(), request(), {:ok, map()} | {:error, term()}) :: :ok
  def observe(server \\ __MODULE__, request, result) do
    GenServer.cast(server, {:observe, RequestOrigin.mark(request), result})
  catch
    :exit, _reason -> :ok
  end

  @spec snapshot(GenServer.server()) :: map()
  def snapshot(server \\ __MODULE__) do
    snapshot!(server)
  catch
    :exit, _reason -> @unknown_snapshot
  end

  @doc """
  Reads the quota meter without replacing an unavailable process with an
  unknown snapshot.

  Diagnostic callers use this form when an unreachable meter must be reported
  as an error rather than presented as an empty measurement.
  """
  @spec snapshot!(GenServer.server(), timeout()) :: map()
  def snapshot!(server \\ __MODULE__, timeout \\ 5_000), do: GenServer.call(server, :snapshot, timeout)

  @doc """
  Returns a recently published snapshot without contacting the quota process.

  The live snapshot path also refreshes this cache. Consumers on latency-sensitive
  paths can use it first, then choose their own bounded live-read fallback on a miss.
  """
  @spec cached_snapshot(GenServer.server(), non_neg_integer()) :: {:ok, map(), non_neg_integer(), integer()} | :miss
  def cached_snapshot(server \\ __MODULE__, max_age_ms \\ 60_000),
    do: cached_snapshot_at(server, max_age_ms, System.monotonic_time(:millisecond))

  @doc false
  @spec cached_snapshot_at(GenServer.server(), non_neg_integer(), integer()) :: {:ok, map(), non_neg_integer(), integer()} | :miss
  def cached_snapshot_at(server, max_age_ms, now_ms) do
    server_pid = if is_pid(server), do: server, else: GenServer.whereis(server)

    if server_pid, do: SnapshotCache.get(server_pid, max_age_ms, now_ms), else: :miss
  catch
    :exit, _reason -> :miss
  end

  @spec preflight(GenServer.server(), request()) :: :ok | {:hold, hold()}
  def preflight(server \\ __MODULE__, request) do
    GenServer.call(server, {:preflight, request})
  catch
    :exit, _reason -> :ok
  end

  @spec dispatch_status(GenServer.server()) :: :available | {:hold, hold()}
  def dispatch_status(server \\ __MODULE__) do
    GenServer.call(server, :dispatch_status)
  catch
    :exit, _reason -> :available
  end

  @doc false
  # Forces the durable request log's delayed-write buffer to disk, so a caller
  # that observed through the public path can read its own rows
  # deterministically (the request-log mutation test relies on this).
  @spec flush_request_log(GenServer.server()) :: :ok
  def flush_request_log(server \\ __MODULE__) do
    GenServer.call(server, :flush_request_log)
  catch
    :exit, _reason -> :ok
  end

  @impl true
  def init(opts) do
    SnapshotCache.ensure_table()

    refresh? = Keyword.get(opts, :refresh?, Application.get_env(:aiur, :github_quota_refresh?, true))

    # Resolved once at boot: every observe appends to the same durable file,
    # and re-resolving `GitHub.Config.repo()` per request would add a config
    # read to the hot path. An explicit `nil` disables the log (tests); an
    # absent value resolves the configured default.
    request_log_path =
      case Keyword.fetch(opts, :request_log_path) do
        {:ok, nil} -> nil
        {:ok, path} -> path
        :error -> RequestLog.default_path()
      end

    state = %{
      windows: %{},
      credential_windows: %{},
      backoffs: %{},
      observations: [],
      shell_observations: [],
      shell_refreshed_at: nil,
      alerts: MapSet.new(),
      # When this meter started observing. Attribution lives in this process's
      # memory and does not survive a restart, while the credential's window
      # does — GitHub keeps counting across the restart and `/rate_limit`
      # reports the whole hour on the next refresh. Without this, a consumer
      # cannot tell "nobody else spent it" from "I was not running when it was
      # spent", and would attribute the daemon's own forgotten calls to
      # somebody else.
      # Overridable so a test can place the boot before or after a window's
      # start without also moving the clock that prices everything else.
      started_at: Keyword.get_lazy(opts, :started_at, fn -> Keyword.get(opts, :clock, &DateTime.utc_now/0).() end),
      clock: Keyword.get(opts, :clock, &DateTime.utc_now/0),
      emit_fun: Keyword.get(opts, :emit_fun, &Signal.alert/2),
      shell_log_path: Keyword.get_lazy(opts, :shell_log_path, &ShellObservations.default_shell_log_path/0),
      stale_broker_path: Keyword.get_lazy(opts, :stale_broker_path, &ShellObservations.default_stale_broker_path/0),
      stale_broker_alerts: MapSet.new(),
      hold_dir: Keyword.get_lazy(opts, :hold_dir, &Windows.default_hold_dir/0),
      request_log_path: request_log_path,
      # The durable request log's io_device, opened once here in
      # `:delayed_write` and closed on terminate (#2255). Holding it keeps an
      # observe from paying an open/close/stat on this GenServer's message
      # loop, which gates every agent's GitHub access.
      request_log_io: RequestLog.open_writer(request_log_path),
      # Bytes written to the current file, tracked so rotation happens at the
      # cap without a `stat` per request.
      request_log_bytes: 0,
      refresh_fun: Keyword.get(opts, :refresh_fun, &refresh_from_github/0),
      recovery_fun: Keyword.get(opts, :recovery_fun, &notify_orchestrator_recovery/0),
      observed_dispatch_hold?: false,
      recovery_timer_ref: nil,
      recovery_timer_token: nil,
      refresh_interval_ms: Keyword.get(opts, :refresh_interval_ms, @refresh_interval_ms),
      refresh_ref: nil
    }

    state = Map.put(state, :hold_alerts, HoldSweep.sweep(state.hold_dir, state.clock.(), state.emit_fun))
    if refresh?, do: Process.send_after(self(), :refresh, 0)
    {:ok, state}
  end

  @impl true
  def handle_cast({:observe, request, result}, state) do
    now = state.clock.()
    held_before? = state.observed_dispatch_hold?

    # Durable per-request record (#2255). Every request routed through this
    # chokepoint lands one row in `daemon-requests.tsv` — timestamp, pid,
    # caller, method, path/operation, status, cost, credential fingerprint —
    # so a budget question is answerable from logs alone after the window has
    # closed. It runs for every observe (including `/rate_limit` probes) and
    # is deliberately independent of the in-memory attribution below: the log
    # is the evidence, the attribution is the ranking.
    state =
      state
      |> Attribution.log_request(request, result, now)
      |> Windows.prune_backoffs(now)
      |> Windows.observe_response(request, result, now)
      |> Windows.observe_rejection(request, result, now)
      |> Attribution.attribute_request(request, result, now)
      |> Windows.maybe_alert()

    status = Windows.dispatch_status(state, now)
    held_now? = match?({:hold, _hold}, status)
    if held_before? and not held_now?, do: state.recovery_fun.()

    state = state |> Map.put(:observed_dispatch_hold?, held_now?) |> sync_recovery_timer(status, now)
    {:noreply, state}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    now = state.clock.()
    state = state |> Windows.prune_backoffs(now) |> Attribution.prune_observations(now) |> ShellObservations.refresh_shell_observations(now) |> ShellObservations.refresh_stale_broker_alerts()

    in_window = Attribution.observations_in_window(state, now)

    coverage = Coverage.coverage(in_window, state.windows, now)

    snapshot = %{
      state: if(map_size(state.windows) == 0, do: :unknown, else: :observed),
      windows:
        Map.new(state.windows, fn {resource, window} ->
          {resource, window |> Windows.present_window() |> Map.put(:started_at, Attribution.window_start(state.windows, resource, now))}
        end),
      credential_windows:
        state.credential_windows
        |> Enum.filter(fn {{_key, _resource}, window} -> DateTime.compare(now, window.reset_at) == :lt end)
        |> Enum.reduce(%{}, fn {{key, resource}, window}, acc ->
          visible = window |> Windows.present_window() |> Map.put(:started_at, DateTime.add(window.reset_at, -3600, :second))
          Map.update(acc, key, %{resource => visible}, &Map.put(&1, resource, visible))
        end),
      observing_since: Attribution.observing_since(state, now),
      attribution: Attribution.summarize_attribution(in_window),
      callers: Attribution.summarize_callers(in_window, state.windows, now),
      coverage: coverage,
      reconciliation: Coverage.reconciliation(coverage),
      backoffs: Windows.present_backoffs(state, now)
    }

    SnapshotCache.put(self(), snapshot, System.monotonic_time(:millisecond), System.system_time(:millisecond))
    {:reply, snapshot, state}
  end

  def handle_call({:preflight, request}, _from, state) do
    state = Windows.prune_backoffs(state, state.clock.())

    reply =
      if Windows.rate_limit_endpoint?(request) do
        :ok
      else
        case Windows.resource_status(state, Windows.request_resource(request), 0.0) do
          :available -> :ok
          hold -> hold
        end
      end

    {:reply, reply, state}
  end

  def handle_call(:dispatch_status, _from, state) do
    now = state.clock.()
    state = Windows.prune_backoffs(state, now)
    {:reply, Windows.dispatch_status(state, now), state}
  end

  def handle_call(:flush_request_log, _from, state) do
    reply =
      case state.request_log_io do
        nil -> :ok
        io -> RequestLog.sync(io)
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_info(:refresh, %{refresh_ref: nil} = state) do
    refresh_fun = state.refresh_fun
    {_pid, ref} = spawn_monitor(refresh_fun)
    {:noreply, %{state | refresh_ref: ref}}
  end

  def handle_info(:refresh, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{refresh_ref: ref} = state) do
    hold_alerts = HoldSweep.sweep(state.hold_dir, state.clock.(), state.emit_fun, state.hold_alerts)
    Process.send_after(self(), :refresh, state.refresh_interval_ms)
    {:noreply, %{ShellObservations.refresh_stale_broker_alerts(state) | refresh_ref: nil, hold_alerts: hold_alerts}}
  end

  def handle_info({:dispatch_recovery, token}, %{recovery_timer_token: token} = state) do
    now = state.clock.()
    state = Windows.prune_backoffs(state, now)
    status = Windows.dispatch_status(state, now)
    held_now? = match?({:hold, _hold}, status)

    if state.observed_dispatch_hold? and not held_now?, do: state.recovery_fun.()

    state = state |> Map.put(:observed_dispatch_hold?, held_now?) |> sync_recovery_timer(status, now)
    {:noreply, state}
  end

  def handle_info({:dispatch_recovery, _stale_token}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    SnapshotCache.delete(self())
    # Flush and close the request log's delayed-write io_device so the last
    # buffered rows are not lost on shutdown.
    if state.request_log_io, do: :file.close(state.request_log_io)
    :ok
  end

  defp sync_recovery_timer(state, :available, _now) do
    cancel_recovery_timer(state)
    %{state | recovery_timer_ref: nil, recovery_timer_token: nil}
  end

  defp sync_recovery_timer(state, {:hold, %{reset_at: reset_at}}, now) do
    cancel_recovery_timer(state)
    token = make_ref()
    delay_ms = max(DateTime.diff(reset_at, now, :millisecond), 0)
    timer_ref = Process.send_after(self(), {:dispatch_recovery, token}, delay_ms)
    %{state | recovery_timer_ref: timer_ref, recovery_timer_token: token}
  end

  defp cancel_recovery_timer(%{recovery_timer_ref: ref}) when is_reference(ref), do: Process.cancel_timer(ref)
  defp cancel_recovery_timer(_state), do: false

  defp refresh_from_github do
    with token when is_binary(token) and token != "" <- GitHubConfig.token() do
      credential = CredentialRegistry.credentials() |> Enum.find(&(&1.primary? and Credential.token(&1) == token))
      credential_key = if credential, do: Credential.identity_key(credential), else: Budget.token_key(token)

      Transport.default_request_fun(%{
        method: :get,
        url: "https://api.github.com/rate_limit",
        token: token,
        credential_id: "primary",
        credential_pinned?: true,
        credential_key: credential_key,
        timeout_ms: 10_000
      })
    end

    :ok
  rescue
    _unavailable -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp notify_orchestrator_recovery do
    case GenServer.whereis(Application.get_env(:aiur, :github_quota_recovery_target)) do
      pid when is_pid(pid) -> send(pid, :github_quota_recovered)
      nil -> :ok
    end

    :ok
  end

  @doc """
  The earliest moment this meter could have attributed a call.

  Not "when the first call happened" — a daemon that has been up for hours and
  was simply idle for the first ten minutes of a window can still account for
  the whole window. This is the boundary of what the meter is *able* to have
  seen: its own boot, or the edge of the rolling attribution window, whichever
  is later.

  A consumer compares this against a window's `started_at` to know whether the
  shortfall between `attributed` and `spend` means "another consumer spent it"
  or only "I was not running yet". The two are different facts and only one of
  them names somebody else.
  """
  @spec observing_since(map(), DateTime.t()) :: DateTime.t()
  defdelegate observing_since(state, now), to: Attribution

  @doc """
  Does the per-caller breakdown add up to what GitHub says the window cost?

  A breakdown that does not reconcile is not evidence, it is a guess with a
  table around it. `spend` is `limit - remaining` from the credential's own
  `/rate_limit` window — the number the operator sees drop — and `attributed`
  is the sum of every row in the ranking. `reconciled?` is the claim that the
  two agree closely enough to act on.

  The two ways it can fail are not the same fact, so `direction` separates them:

    * `:shortfall` — Aiur attributed less than the window spent. This is the
      normal, expected case: calls made on the same credential by anything
      outside this process are real spend Aiur never saw. It bounds how much of
      the ranking is the whole story; it is not a defect.
    * `:excess` — Aiur attributed more than the window spent. Points cannot be
      counted twice, so this is a bug in the accounting and is the only case
      worth alarming on.
    * `:agrees` — inside the margin.

  Collapsing both into one boolean would print an alarm during normal operation,
  and an operator who learns to ignore the alarm cannot see the double count
  when it happens. `reconciled?` is kept for the inside-the-margin claim.
  """
  @spec reconciliation(map()) :: %{optional(String.t()) => map()}
  defdelegate reconciliation(value), to: Coverage

  @doc false
  @spec parse_shell_observation(String.t()) :: map() | nil
  defdelegate parse_shell_observation(value), to: ShellObservations
end
