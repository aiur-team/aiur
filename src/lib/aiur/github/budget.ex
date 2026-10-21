defmodule Aiur.GitHub.Budget do
  @moduledoc """
  Coordinates GitHub request admission across local Aiur instances.

  The broker is host-local and keyed by one-way credential and consumer fingerprints. It shares
  rate ceilings, global and endpoint-family in-flight leases, jittered request
  starts, and rate-limit cooldowns with the agent `gh` wrapper.
  """

  alias Aiur.GitHub.Budget.{BrokerPort, ResponseLimits, Settings, StateDir}
  alias Aiur.GitHub.{CredentialHeadroom, EndpointPolicy}
  alias Aiur.Signal

  require Logger

  @type lease :: %{id: String.t(), token_key: String.t()}
  @type hold :: %{resource: String.t(), reset_at: DateTime.t(), reason: atom()}

  @type release_outcome ::
          :released
          | :deadline_exceeded
          | :github_budget_broker_unavailable
          | :bypass

  @release_topic "github:budget:lease_release"

  # Keep this source-tree path strictly compile-time-only so changes to the
  # broker invalidate the module. Runtime calls resolve `priv/` from the
  # installed application because release layouts do not retain this checkout.
  @broker_source_path Path.expand("../../../priv/github_budget.py", __DIR__)
  @external_resource @broker_source_path
  @retry_floor_ms 5
  @priority_key :aiur_github_budget_priority

  @spec enabled?(keyword()) :: boolean()
  def enabled?(opts \\ []) do
    Keyword.get_lazy(opts, :enabled?, fn -> Aiur.GitHub.Access.Settings.current().budget_enabled? end)
  end

  @doc """
  Logs, once at boot, that GitHub budget metering is disabled because the
  broker cannot run (python3 not found on the box).

  Metering is an optimization: `acquire/2` and `command/3` both fail open to
  `:bypass` when the broker is unavailable, so the daemon keeps running
  unmetered. This notice is the "says so once, clearly" counterpart to that
  fail-open behaviour (#2376). A no-op when metering is enabled, the broker is
  runnable, or an explicit `:python` is configured.
  """
  @spec warn_metering_unavailable(keyword()) :: :ok
  def warn_metering_unavailable(opts \\ []) do
    if enabled?(opts) and is_nil(BrokerPort.python_executable(opts)) do
      Logger.warning(
        "aiur_boot phase=budget_metering_disabled reason=python3_not_found " <>
          "GitHub budget metering is disabled because python3 was not found on this box; " <>
          "GitHub requests run unmetered. Install python3 to enable the budget broker."
      )
    end

    :ok
  end

  @spec token_key(String.t()) :: String.t()
  def token_key(token) when is_binary(token) and token != "" do
    :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)
  end

  @spec token_key(String.t() | nil) :: String.t() | nil
  def token_key(_token), do: nil

  @doc "A domain-separated, one-way key for a stable configured credential identity."
  @spec identity_key(String.t()) :: String.t()
  def identity_key(identity) when is_binary(identity) and identity != "" do
    token_key("aiur-github-credential-v1\0" <> identity)
  end

  @spec state_dir(keyword()) :: Path.t()
  def state_dir(opts \\ []), do: StateDir.resolve(opts)

  @spec database_path(keyword()) :: Path.t()
  def database_path(opts \\ []), do: Path.join(state_dir(opts), "budget.sqlite3")

  @spec ensure_state_dir(keyword()) :: :ok | {:error, term()}
  def ensure_state_dir(opts \\ []), do: StateDir.ensure(opts)

  @spec broker_path(keyword()) :: Path.t()
  def broker_path(opts \\ []) do
    case Keyword.get(opts, :broker_path) do
      path when is_binary(path) and path != "" -> path
      # Tests inject a broker variant (e.g. one without the `reconcile`
      # subcommand) through the `:broker_path` option; production always uses
      # the broker shipped in `priv/`.
      _missing -> :aiur |> :code.priv_dir() |> to_string() |> Path.join("github_budget.py")
    end
  end

  @doc "Configuration exported to the agent-side `gh` wrapper."
  @spec guard_settings(keyword()) :: map()
  def guard_settings(opts \\ []), do: Settings.settings(opts)

  @spec acquire(map(), keyword()) ::
          {:ok, lease()}
          | {:hold, hold()}
          | {:error, :github_budget_broker_unavailable | :github_budget_broker_timeout}
          | :bypass
  def acquire(request, opts \\ []) do
    with true <- enabled?(opts),
         token when is_binary(token) <- Map.get(request, :token),
         key when is_binary(key) <- token_key(token) do
      case BrokerPort.python_executable(opts) do
        python when is_binary(python) ->
          request |> do_acquire(key, python, identity_opts(request, opts), Settings.deadline(opts)) |> keep_hold(nil)

        nil ->
          # No python3 on the box, so the broker cannot run at all. Fail open to
          # unmetered operation exactly like `command/3` does: a budget broker is
          # an optimization, and its absence must degrade to unmetered requests,
          # never to a dead daemon (#2376).
          :bypass
      end
    else
      false -> :bypass
      _unavailable -> {:error, :github_budget_broker_unavailable}
    end
  end

  @doc """
  PubSub topic carrying a completion signal for every lease release.

  Subscribers receive `{:github_budget_lease_released, %{lease_id: id,
  token_key: key, budget_ms: non_neg_integer(), outcome: release_outcome()}}`,
  where `budget_ms` is the time the release granted itself before running and
  `outcome` is how it ended.
  """
  @spec release_topic() :: String.t()
  def release_topic, do: @release_topic

  @spec release(lease(), keyword()) :: :ok
  def release(lease, opts \\ [])

  def release(%{id: id, token_key: key}, opts) when is_binary(id) and is_binary(key) do
    budget_ms = max(Settings.command_deadline(opts) - System.monotonic_time(:millisecond), 0)
    publish_release(id, key, budget_ms, BrokerPort.command(["release", "--lease-id", id], key, opts))
    :ok
  end

  def release(_lease, _opts), do: :ok

  # `release/2` shares the request deadline and may be abandoned before broker
  # acknowledgment. An abandoned release holds headroom until broker expiry;
  # an acknowledged one returns it immediately. Keep outcome and caller budget
  # explicit instead of inferring acknowledgment from load-sensitive timing.
  # `budget_ms` also exposes a release budget that exceeds the request deadline.
  defp publish_release(lease_id, token_key, budget_ms, result) do
    event = %{lease_id: lease_id, token_key: token_key, budget_ms: budget_ms, outcome: release_outcome(result)}

    if Process.whereis(Aiur.PubSub) do
      Phoenix.PubSub.broadcast(Aiur.PubSub, @release_topic, {:github_budget_lease_released, event})
    end

    :ok
  rescue
    error -> Logger.warning("github_budget_release_publish_failed #{Exception.message(error)}")
  catch
    :exit, reason -> Logger.warning("github_budget_release_publish_exited #{inspect(reason)}")
  end

  defp release_outcome({:ok, _output}), do: :released
  defp release_outcome({:error, :github_budget_broker_timeout}), do: :deadline_exceeded
  defp release_outcome({:error, reason}), do: reason
  defp release_outcome(:bypass), do: :bypass

  @doc "Observes a response before releasing its lease so accounting and rejections are global immediately."
  @spec observe(map(), lease(), {:ok, map()} | {:error, term()}, keyword()) :: :ok
  def observe(request, lease, result, opts) do
    # The reconcile must carry the same credential identity the admission did,
    # or the broker resolves it to a different storage key than the one the
    # lease was admitted under.
    reconcile_response(lease, result, identity_opts(request, opts))
    observe(request, result, opts)
  end

  @spec observe(map(), {:ok, map()} | {:error, term()}, keyword()) :: :ok
  def observe(request, {:ok, %{} = response}, opts) do
    case active_token_key(request, opts) do
      key when is_binary(key) -> observe_response(key, request, response, opts)
      _unavailable -> :ok
    end
  end

  def observe(_request, _result, _opts), do: :ok

  defp reconcile_response(%{id: id, token_key: key}, {:ok, %{status: 304}}, opts)
       when is_binary(id) and is_binary(key) do
    case BrokerPort.command(["reconcile", "--lease-id", id, "--status", "304"], key, opts) do
      {:ok, _output} -> :ok
      # `command` already logs the broker failure generically; this names the
      # reconcile specifically so a stale broker (one without the `reconcile`
      # subcommand) or a broken reconcile is visible in the daemon log instead
      # of reading as "reconciliation did not fire".
      {:error, reason} -> Logger.warning("github_budget_reconcile_failed lease_id=#{id} reason=#{inspect(reason)}")
      :bypass -> :ok
    end

    :ok
  end

  defp reconcile_response(_lease, _result, _opts), do: :ok

  @doc "Marks the calling process as the base-branch watcher: its admissions may use one lease above the in-flight caps."
  @spec prioritize() :: :ok
  def prioritize do
    Process.put(@priority_key, true)
    :ok
  end

  @spec snapshot(String.t(), keyword()) :: map()
  def snapshot(token, opts \\ []) when is_binary(token) do
    key = token_key(token)

    case BrokerPort.command(["snapshot"], key, identity_opts(%{}, opts)) do
      {:ok, output} ->
        case Jason.decode(String.trim(output)) do
          {:ok, snapshot} -> ResponseLimits.atomize_snapshot(snapshot)
          _invalid -> %{cooldown_until_ms: 0, inflight: %{}, admissions: []}
        end

      _unavailable ->
        %{cooldown_until_ms: 0, inflight: %{}, admissions: []}
    end
  end

  @doc """
  Per-actor (daemon vs each agent workspace) Core/GraphQL usage and ceilings.

  Reads the broker's whole actor inventory — one entry per consumer it has seen,
  keyed by credential and consumer fingerprint — with the rolling-hour `used`
  count, the configured `limit` (0 = no ceiling), and `reset_at_ms`: the wall-
  clock moment the actor's usage next drops (the hold release when the actor is
  over its ceiling, otherwise when its oldest in-window admission ages out).

  Returns `%{actors: []}` when the broker is unavailable or disabled, so a
  report command degrades to "nothing observed" rather than failing loudly on a
  host without a broker.
  """
  @spec usage(keyword()) :: map()
  def usage(opts \\ []) do
    case BrokerPort.command(["usage"], "", Keyword.put(opts, :include_token_key, false)) do
      {:ok, output} ->
        case Jason.decode(String.trim(output)) do
          {:ok, %{"actors" => actors}} -> %{actors: Enum.map(actors, &ResponseLimits.atomize_actor/1)}
          _invalid -> %{actors: []}
        end

      _unavailable ->
        %{actors: []}
    end
  end

  @spec endpoint_family(map()) :: String.t()
  def endpoint_family(%{url: url}) when is_binary(url), do: EndpointPolicy.endpoint_family(url)
  def endpoint_family(_request), do: "rest"

  @spec request_resource(map()) :: String.t()
  def request_resource(%{url: url}) when is_binary(url), do: EndpointPolicy.resource(url)
  def request_resource(_request), do: "core"

  defp do_acquire(request, key, python, opts, deadline_at) do
    # `command_timeout_ms` bounds each broker round trip apart from the admission wait, so a slow broker still times out.
    command_ms = Keyword.get(opts, :command_timeout_ms)
    command_deadline_at = if command_ms, do: min(deadline_at, System.monotonic_time(:millisecond) + command_ms), else: deadline_at
    command_opts = opts |> Keyword.put(:python, python) |> Keyword.put(:deadline_at, command_deadline_at)

    case BrokerPort.command(acquire_args(request, opts), key, command_opts) do
      {:ok, "granted " <> id} ->
        grant_or_hold(String.trim(id), request, key)

      {:ok, "wait actor " <> milliseconds} ->
        retry_admission(request, key, python, opts, deadline_at, milliseconds, :actor_budget)

      {:ok, "hold shared " <> metadata} ->
        shared_hold(request, key, python, opts, deadline_at, metadata)

      {:ok, "wait " <> milliseconds} ->
        retry_admission(request, key, python, opts, deadline_at, milliseconds, :shared_budget)

      # Deadline expiry differs from malformed output: Python startup can race the deadline under load, so
      # callers may retry it (#2286). `:admission_closed` marks expiry at the admission deadline, not the per-command bound.
      {:error, :github_budget_broker_timeout} ->
        if command_deadline_at == deadline_at, do: {:error, :admission_closed}, else: {:error, :github_budget_broker_timeout}

      _unavailable ->
        {:error, :github_budget_broker_unavailable}
    end
  end

  defp shared_hold(request, key, python, opts, deadline_at, metadata) do
    with [resource, reset_at_ms] <- String.split(String.trim(metadata), " ", parts: 2),
         true <- resource in ["core", "graphql", "search"],
         {reset_at_ms, ""} when reset_at_ms > 0 <- Integer.parse(reset_at_ms),
         {:ok, reset_at} <- DateTime.from_unix(reset_at_ms, :millisecond),
         true <- reset_at_ms > System.system_time(:millisecond) do
      delay_ms = reset_at_ms - System.system_time(:millisecond)

      if System.monotonic_time(:millisecond) + delay_ms >= deadline_at do
        {:hold, %{reason: :shared_budget, resource: resource, reset_at: reset_at}}
      else
        Process.sleep(max(delay_ms, @retry_floor_ms))
        request |> do_acquire(key, python, opts, deadline_at) |> keep_hold(%{reason: :shared_budget, resource: resource, reset_at: reset_at})
      end
    else
      _invalid -> {:error, :github_budget_broker_unavailable}
    end
  end

  defp retry_admission(request, key, python, opts, deadline_at, milliseconds, reason) do
    case Integer.parse(String.trim(milliseconds)) do
      {delay, ""} when delay > 0 ->
        retry_or_hold(request, key, python, opts, deadline_at, delay, reason)

      _invalid ->
        {:error, :github_budget_broker_unavailable}
    end
  end

  defp grant_or_hold(id, _request, key) do
    if valid_lease_id?(id) do
      {:ok, %{id: id, token_key: key}}
    else
      {:error, :github_budget_broker_unavailable}
    end
  end

  defp retry_or_hold(request, key, python, opts, deadline_at, delay, reason) do
    if System.monotonic_time(:millisecond) + delay >= deadline_at do
      maybe_alert_meter_disagreement(request, key, reason, opts)
      {:hold, hold(request, delay, reason)}
    else
      Process.sleep(max(delay, @retry_floor_ms))
      request |> do_acquire(key, python, opts, deadline_at) |> keep_hold(hold(request, delay, reason))
    end
  end

  # A retry cut off by the admission deadline after the broker already said "wait" reports that hold,
  # so lease saturation is not counted as a slow broker. A first attempt has no hold to report.
  defp keep_hold({:error, :admission_closed}, nil), do: {:error, :github_budget_broker_timeout}
  defp keep_hold({:error, :admission_closed}, hold), do: {:hold, hold}
  defp keep_hold(result, _hold), do: result

  defp maybe_alert_meter_disagreement(request, key, :actor_budget, opts) do
    resource = request_resource(request)

    with %{} = window <- CredentialHeadroom.window(key, resource),
         %{} = local <- local_usage(key, resource, opts) do
      CredentialHeadroom.reconcile_budget_meter(key, resource, local, window, alert_fun: Keyword.get(opts, :alert_fun, &Signal.alert/2))
    else
      _unavailable -> :ok
    end
  end

  # A shared hold is the token-wide cooldown, not an hourly ledger, so there is
  # no local count to compare — the contradiction is the hold itself standing
  # while the credential's own window still reports headroom.
  defp maybe_alert_meter_disagreement(request, key, :shared_budget, opts) do
    resource = request_resource(request)

    case CredentialHeadroom.window(key, resource) do
      %{} = window ->
        CredentialHeadroom.reconcile_shared_hold(key, resource, window, alert_fun: Keyword.get(opts, :alert_fun, &Signal.alert/2))

      _unavailable ->
        :ok
    end
  end

  defp local_usage(key, resource, opts) do
    usage_opts = opts |> Keyword.drop([:deadline_at]) |> Keyword.put(:timeout_ms, 1_000)

    case BrokerPort.command(["meter", "--consumer-key", Settings.consumer_key(opts), "--resource", resource], key, usage_opts) do
      {:ok, output} ->
        case Jason.decode(String.trim(output)) do
          {:ok, meter} -> ResponseLimits.atomize_usage_figure(meter)
          _invalid -> nil
        end

      _unavailable ->
        nil
    end
  end

  defp acquire_args(request, opts) do
    settings = Settings.settings(opts)
    {core_limit, graphql_limit, search_limit} = actor_limits(Settings.consumer_identity(opts), settings)
    family = endpoint_family(request)

    # Endpoints GitHub does not meter (e.g. `/rate_limit`) are admitted for
    # ordering but recorded non-billable, so the ledger never reports them as
    # spend — the same decision `Quota` reaches through the shared
    # `EndpointPolicy` table (#2353).
    billable_args = if EndpointPolicy.billable_for(family), do: [], else: ["--billable", "0"]

    [
      "acquire",
      "--resource",
      request_resource(request),
      "--consumer-key",
      Settings.consumer_key(opts),
      "--consumer-label",
      Settings.consumer_identity(opts),
      "--endpoint-family",
      family,
      "--max-inflight",
      Integer.to_string(settings.max_inflight),
      "--max-inflight-per-endpoint",
      Integer.to_string(settings.max_inflight_per_endpoint),
      "--requests-per-minute",
      Integer.to_string(settings.requests_per_minute),
      "--stagger-ms",
      Integer.to_string(settings.stagger_ms),
      "--lease-ttl-ms",
      Integer.to_string(settings.lease_ttl_ms),
      "--core-limit",
      Integer.to_string(core_limit),
      "--graphql-limit",
      Integer.to_string(graphql_limit),
      "--search-limit",
      Integer.to_string(search_limit)
    ] ++ billable_args ++ priority_args(request)
  end

  # Main-watch (and the base-CI fixer it drives) may hold one lease above the in-flight caps so bulk
  # polling cannot starve default-branch health checks; cooldowns, ceilings and pacing still apply.
  defp priority_args(_request), do: if(Process.get(@priority_key), do: ["--priority"], else: [])

  # The daemon and each agent workspace are separate actors with separate hourly
  # ceilings. The daemon's own calls default to the daemon consumer and the
  # daemon ceiling; an agent workspace (which reaches the broker through the gh
  # wrapper, not through this module) is labelled `workspace:<path>` and would
  # get the agent ceiling if it ever acquired here.
  defp actor_limits(identity, settings) do
    if String.starts_with?(identity, "workspace:") do
      {settings.agent_core_limit_per_hour, settings.agent_graphql_limit_per_hour, settings.agent_search_limit_per_hour}
    else
      {settings.daemon_core_limit_per_hour, settings.daemon_graphql_limit_per_hour, settings.daemon_search_limit_per_hour}
    end
  end

  defp hold(key, scope, resource, delay_ms, opts) do
    _ =
      BrokerPort.command(
        ["hold", "--scope", Atom.to_string(scope), "--resource", resource, "--delay-ms", Integer.to_string(delay_ms)],
        key,
        opts
      )

    :ok
  end

  defp hold(request, delay_ms, reason) do
    %{resource: request_resource(request), reset_at: DateTime.add(DateTime.utc_now(), ceil(delay_ms / 1_000), :second), reason: reason}
  end

  defp active_token_key(request, opts) do
    if enabled?(opts), do: token_key(Map.get(request, :token))
  end

  defp observe_response(key, request, response, opts) do
    opts = identity_opts(request, opts)
    headers = Map.get(response, :headers, [])
    resource = ResponseLimits.response_resource(headers, request)

    case ResponseLimits.limit_hold(response, headers) do
      {:resource, delay} when is_binary(resource) ->
        ResponseLimits.log_resource_hold(resource, headers, request, delay)
        hold(key, :resource, resource, delay, opts)

      {:resource, _delay} ->
        # The response names a rate-limit pool we do not model (GitHub also
        # meters `integration_manifest`, `code_scanning_upload`, …). Attributing
        # its exhaustion to the request's bucket would create a false hold on
        # `core`; skip rather than guess (#2409).
        :ok

      {:token, delay} ->
        hold(key, :token, resource, delay, opts)

      :none ->
        :ok
    end
  end

  defp identity_opts(request, opts) do
    case Map.get(request, :credential_key) || Keyword.get(opts, :credential_key) do
      key when is_binary(key) and key != "" -> Keyword.put(opts, :credential_key, key)
      _missing -> opts
    end
  end

  defp valid_lease_id?(id), do: String.match?(id, ~r/\A[a-f0-9]{32}\z/)
end
