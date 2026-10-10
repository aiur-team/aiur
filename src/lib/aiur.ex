defmodule Aiur do
  @moduledoc """
  Entry point for the Aiur orchestrator.
  """
  @doc """
  Start the orchestrator in the current BEAM node.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    Aiur.Orchestrator.start_link(Keyword.put_new(opts, :name, Aiur.Orchestrator))
  end
end

defmodule Aiur.Application do
  @moduledoc """
  OTP application entrypoint that starts core supervisors and workers.
  """

  use Application

  require Logger

  alias Aiur.{AgentGitHubGuard, GitHub.Budget}
  alias Aiur.Application.StartupChecks
  alias Aiur.GitHub.Config
  alias Aiur.Identity.Machine

  @impl true
  def start(_type, _args) do
    :ok = Aiur.Boot.mark()
    # Absolute times render in the viewer's timezone via `DateTime.shift_zone!`,
    # which needs a timezone database installed. `:tz` ships one.
    :ok = Calendar.put_time_zone_database(Tz.TimeZoneDatabase)
    maybe_validate_environment()
    :ok = Aiur.LogFile.ensure_session_log_file()
    :ok = Aiur.LogFile.apply_config_debug()
    :ok = Aiur.LogFile.configure()
    settings = Aiur.Config.settings_uncached()
    telemetry? = Aiur.Config.telemetry_enabled?(settings)
    Aiur.RunTelemetry.start_boot()
    Logger.info("aiur_boot phase=start elapsed_ms=0")
    :ok = StartupChecks.log_base_branch(settings)
    :ok = StartupChecks.log_route_credentials(settings)
    # Durable daemon-lifecycle journal: record this boot's start (and its
    # invoking process) before any child can fail, so an incident's journal
    # always names the instance that started. Best-effort — a journal write
    # failure must never crash boot.
    record_daemon_start()
    _ = Machine.ensure()
    # Write the initial heartbeat file so the Executor can detect daemon downtime.
    # Best-effort: heartbeat write failure must not crash boot.
    Aiur.DaemonHeartbeat.write!()
    Aiur.Shutdown.record_workspace_root()
    Aiur.Shutdown.record_alert_ledger_path()
    install_signal_handlers()
    maybe_start_distribution()
    if Application.get_env(:aiur, :resolve_github_token_on_boot, true), do: resolve_github_token()
    # #2356: keep the bot PAT out of every agent environment. The daemon writes
    # it to the guard's credential file so a governed `gh` call can inject it
    # for its own duration, while a bare `curl` or a dependency build script
    # finds no token in the environment.
    _ = AgentGitHubGuard.ensure_agent_token_file()
    if Budget.enabled?(), do: AgentGitHubGuard.install_host()
    Budget.warn_metering_unavailable()
    Aiur.RtkStartupCheck.run()

    no_dashboard? = Application.get_env(:aiur, :no_dashboard, false)

    with :ok <- Aiur.GlobalConfigStartup.prepare(),
         :ok <- validate_dashboard_compatibility(no_dashboard?) do
      headless? = Application.get_env(:aiur, :headless, false)
      # Headless is authoritative: if both flags somehow end up set (e.g. a
      # hand-run `aiur --headless` that also injected `--interactive`), the lean
      # path wins rather than booting a half-built interactive tree.
      interactive_cli? = Application.get_env(:aiur, :interactive_cli, false) and not headless?

      children =
        child_specs(
          interactive_cli?: interactive_cli?,
          headless?: headless?,
          dashboard?: not no_dashboard?,
          tailscale_funnel?: configured_tailscale_funnel?(settings),
          telemetry?: telemetry?
        )

      # `:rest_for_one`, not `:one_for_one`: the children above are written in
      # dependency order, and several of them genuinely depend on the ones
      # before them. `Aiur.PubSub` leads the dependent block because 17 lib
      # modules subscribe to it; six application children hold a live link to it
      # at boot. Only the dependency-free webhook and capability ETS owners precede it;
      # neither must be restarted by anyone else's crash (#2531).
      #
      # Elixir's `Registry` links every registered process to its partition, and
      # `Phoenix.PubSub.subscribe/2` registers — so each subscribing sibling is
      # *linked* to `Aiur.PubSub`. When PubSub dies, that exit propagates over
      # those links and kills its subscribers in the same instant. Under
      # `:one_for_one` they are then restarted with no ordering guarantee
      # relative to PubSub itself: they resubscribe before it is back, fail to
      # start, and the resulting hot restart loop exhausts the restart budget
      # and terminates all ~90 children. Because a link-propagated `:shutdown`
      # is not an error exit, that happened with no crash report at all — the
      # tree was simply gone, and every later consumer either raised
      # `unknown registry: Aiur.PubSub` or blocked forever on a message from a
      # dead child (#2525).
      #
      # `:rest_for_one` makes the ordering real: PubSub restarts first, then
      # everything after it, so dependents never start into a missing registry.
      start_supervisor(
        children ++ [supervision_health_child(children)],
        name: Aiur.Supervisor
      )
      |> tap(fn
        {:ok, _supervisor} ->
          Machine.announce_degraded()
          start_upgrade_check()
          start_build_order_funnel_check(build_order_funnel_health_check_startup?(settings, no_dashboard?))

        _error ->
          :ok
      end)
    end
  end

  @doc false
  @spec start_supervisor([Supervisor.child_spec() | {module(), term()} | module()], keyword()) :: Supervisor.on_start()
  def start_supervisor(children, opts \\ []) do
    Supervisor.start_link(children, Keyword.put(opts, :strategy, :rest_for_one))
  end

  # The `aiur run` version notice is deliberately out-of-band: it runs in a
  # fire-and-forget task so it never delays boot or the first dispatch, fails
  # open and silent, caches with a TTL, and honors the `upgrade.check_enabled`
  # config key / `AIUR_UPGRADE_CHECK_DISABLED` env var. Under a development
  # launcher (`aiurdev`) it does nothing at all. The launcher surfaces the
  # resulting notice to the operator from the shared state file.
  #
  # The shared test app must not phone home: `:upgrade_check_refresh?` is set
  # false in the test env (config/config.exs), so a plain `mix test` boots the
  # supervisor tree without spawning a registry fetch. Tests of the check
  # itself drive `Aiur.Upgrade.check_and_announce/1` with an injected transport.
  @spec start_upgrade_check() :: :ok
  def start_upgrade_check do
    if Application.get_env(:aiur, :upgrade_check_refresh?, true) do
      Task.start(fn -> Aiur.Upgrade.check_and_announce() end)
    end

    :ok
  end

  defp start_build_order_funnel_check(true) do
    if Application.get_env(:aiur, :env) != :test and
         is_integer(Aiur.HttpServer.bound_port()) do
      Task.start(&Aiur.BuildOrderFunnelHealth.check/0)
    end

    :ok
  end

  defp start_build_order_funnel_check(false), do: :ok

  @doc false
  @spec build_order_funnel_health_check_startup?(term(), boolean()) :: boolean()
  def build_order_funnel_health_check_startup?(settings, no_dashboard?) do
    not no_dashboard? and
      Aiur.Config.build_order_funnel_health_check_enabled?(settings) and
      not match?({:ok, %{server: %{tailscale_funnel: true}}}, settings)
  end

  defdelegate maybe_validate_environment(), to: Aiur.Application.StartupChecks

  defdelegate validate_dashboard_compatibility(no_dashboard?),
    to: Aiur.Application.StartupChecks

  defdelegate validate_dashboard_compatibility(no_dashboard?, opts),
    to: Aiur.Application.StartupChecks

  defdelegate child_specs(opts), to: Aiur.Application.Children

  defp configured_tailscale_funnel?({:ok, %{server: %{tailscale_funnel: enabled}}}), do: enabled
  defp configured_tailscale_funnel?(_settings), do: false

  defp supervision_health_child(children) do
    {Aiur.SupervisionHealth, supervisor: Aiur.Supervisor, expected_children: children}
  end

  @impl true
  def prep_stop(state) do
    # SIGTERM / `:init.stop` path, BEFORE the supervision tree comes down —
    # the only point on that path where the ProcessReaper and the opencode
    # serves are still alive, so the kind-ordered cleanup (reap agents →
    # delete sessions over HTTP → reap serves) can actually hold.
    Aiur.Shutdown.cleanup()
    state
  end

  @impl true
  def stop(_state) do
    # Post-teardown best-effort re-entry. The reaper is gone by now (its own
    # terminate/2 already swept leftovers); `cleanup/1` phases are idempotent
    # and individually error-wrapped, so this is harmless after prep_stop.
    Aiur.Shutdown.cleanup()
    :ok
  end

  @doc false
  @spec record_daemon_start() :: :ok
  def record_daemon_start do
    process_identity = Aiur.DaemonLifecycle.process_identity()
    log_process_identity(process_identity)
    Aiur.DaemonLifecycle.record_start(Map.to_list(process_identity))
  rescue
    error ->
      # Best-effort by contract: identity resolution and the journal write both
      # sit on the boot path. `process_identity/0` builds its record from a hard
      # hostname match and `Boot.run_id/0`, and `record_start/1` takes the
      # journal lock — none of that may take the application down, so the whole
      # call is wrapped here, not just the write.
      Logger.warning("aiur_boot phase=daemon_start_failed error=#{inspect(error)}")
      :ok
  end

  @doc """
  Run the distribution bring-up step and log the outcome. Public so
  tests can inject a stub `distribution_module` and exercise both
  success and failure branches without needing the actual BEAM to be
  distributed in the test environment.
  """
  @spec start_distribution(module()) :: :ok
  def start_distribution(distribution_module \\ Aiur.Distribution) do
    case distribution_module.start!() do
      :ok ->
        Logger.info("Distribution active as #{inspect(distribution_module.node_name())}")

      {:error, reason} ->
        Logger.debug("Distribution not active: #{inspect(reason)}; pane subcommand will not connect")
    end

    :ok
  end

  defp maybe_start_distribution, do: start_distribution()

  # Resolve the GitHub token once at boot — before the Orchestrator /
  # GithubFirehose children that need GitHub auth start — preferring a valid
  # GITHUB_TOKEN env var but falling back to the gh keyring when the env token
  # is stale/invalid. Best-effort: a resolution error must not crash boot.
  defp resolve_github_token do
    Config.resolve_token()
    :ok
  rescue
    error ->
      Logger.warning("aiur_boot phase=github_token_resolve_failed error=#{inspect(error)}")
      :ok
  end

  # BEAM-level signal routing. The Erlang VM's default handlers already do
  # what we want for catchable signals:
  #   SIGINT  -> `init:stop()` -> Application.stop/1 -> Aiur.Shutdown.cleanup
  #   SIGTERM -> `init:stop()` -> same path
  # SIGHUP defaults to ignored on most VMs; we explicitly opt it into the
  # same graceful path so a terminal-close kills opencode sessions too.
  # Layer 2 (the bash trap in `scripts/aiurdev`) backstops these. Layer 3 is
  # boot-time GC in `Aiur.Opencode.SessionGC` for uncatchable signals (SIGKILL, OOM).
  defp install_signal_handlers do
    try do
      :ok = :os.set_signal(:sighup, :handle)
    catch
      kind, reason ->
        Logger.warning("aiur_signal phase=sighup_install_failed kind=#{kind} reason=#{inspect(reason)}")
    end

    :ok
  end

  # One-shot at boot: log the BEAM's OS pid + parent pid + parent comm
  # so when the wrapper trap fires and writes `wrapper_pid=N` to
  # `/tmp/aiur-trap.N.log`, the pair tells you which wrapper invocation
  # owned which BEAM. Without this, post-mortems have to guess.
  defp log_process_identity(identity) do
    os_pid = identity.os_pid
    ppid = identity.ppid || "unknown"
    ppid_comm = identity.ppid_comm || "unknown"
    Logger.info("aiur_boot phase=pids os_pid=#{os_pid} ppid=#{ppid} ppid_comm=#{ppid_comm}")
    :ok
  end
end
