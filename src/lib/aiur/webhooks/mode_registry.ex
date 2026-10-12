defmodule Aiur.Webhooks.ModeRegistry do
  @moduledoc """
  Per-repo delivery-mode store, silence sweep, and operator alerting.

  The fleet may track several repos at once, each in a different mode, so mode
  lives per repo in this registry and nothing anywhere may assume one mode
  fleet-wide.

  ## The seam

  `record_delivery/3` is the single entry point a webhook receiver calls when a
  delivery has been received *and verified*. Everything else — proving a repo,
  recovering it from degradation, keeping its silence timer alive — follows from
  that one call. Nothing else may promote a repo to webhook mode.

  ## Degradation

  A timer sweeps proven repos. A repo silent past
  `webhooks.silence_threshold_seconds` drops back to full polling and raises a
  needs-attention alert naming the repo, because silently degrading to "no
  events at all" is strictly worse than never having built webhooks. Recovery is
  automatic: the next delivery restores webhook mode and emits an informational
  alert. No operator action in either direction.

  Reads never block on the sweep and never fail loudly: an unknown repo reads
  back as an unconfigured polling repo, which is exactly today's behavior.
  """

  use GenServer

  require Logger

  alias Aiur.{Alerts, Config}
  alias Aiur.Config.Schema.Webhooks, as: WebhookSettings
  alias Aiur.Webhooks.{DeliveryMode, DeliveryModeEvents, ModeTable}
  alias Aiur.Webhooks.ModeRegistry.Policy

  @type server :: GenServer.server()

  # Published to PubSub when a proven repo degrades, and again on every sweep
  # while it stays degraded. The event-sourced view-state sources subscribe to
  # this so they can re-list on the gap — the one case where deliveries are
  # known to be dropped — rather than on a clock. The re-publish on each later
  # sweep is what keeps that re-list alive for the whole outage instead of
  # firing once at the moment the gap opens.
  @degraded_topic "webhooks:mode:degraded"
  # Published to PubSub the moment a resumed delivery proves a degraded repo's
  # gap has closed. Recovery re-lists on this trailing edge — after the gap is
  # over — so everything that changed during the degraded window is re-read
  # once deliveries are flowing again.
  @recovered_topic "webhooks:mode:recovered"

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Subscribes the caller to `{:webhook_degraded, repo}` broadcasts.

  A degradation means the repo's webhook deliveries are known to be dropped, so
  any projection that rides the event stream must re-list to re-converge. This
  is the gap-based counterpart to a bootstrap listing: re-list on boot, and
  re-list when the stream is known to have gaps. The broadcast repeats on every
  sweep while the repo stays degraded, so the re-list is a coarse cadence that
  only runs during the outage itself.
  """
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe do
    Phoenix.PubSub.subscribe(Aiur.PubSub, @degraded_topic)
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, reason}
  end

  @doc """
  Subscribes the caller to `{:webhook_recovered, repo}` broadcasts.

  A recovered repo is one whose gap has closed: a delivery resumed after
  degradation. Re-listing on this trailing edge — rather than only when the gap
  opened — is what recovers everything that changed during the degraded window,
  because a repo sitting degraded is frozen by definition (no event stream is
  carrying the truth to it).
  """
  @spec subscribe_recovered() :: :ok | {:error, term()}
  def subscribe_recovered do
    Phoenix.PubSub.subscribe(Aiur.PubSub, @recovered_topic)
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, reason}
  end

  @doc """
  Records one observed, verified webhook delivery for `repo`.

  Idempotent with respect to mode: repeated deliveries keep a repo
  webhook-backed and refresh its silence timer.
  """
  @spec record_delivery(String.t(), keyword()) :: {:ok, DeliveryMode.t()}
  def record_delivery(repo, opts \\ []) when is_binary(repo) do
    {server, opts} = Keyword.pop(opts, :server, __MODULE__)
    at = Keyword.get(opts, :at) || DateTime.utc_now()
    GenServer.call(server, {:record_delivery, repo, at})
  end

  @doc """
  Records that the poller observed repository activity for `repo`.

  This is the corroboration the silence sweep needs: it never promotes a repo
  to webhook mode, and its only effect is to let a genuine delivery failure be
  told apart from an idle repository. See `Aiur.Webhooks.DeliveryMode`.
  """
  @spec record_activity(String.t(), keyword()) :: {:ok, DeliveryMode.t()}
  def record_activity(repo, opts \\ []) when is_binary(repo) do
    {server, opts} = Keyword.pop(opts, :server, __MODULE__)
    at = Keyword.get(opts, :at) || DateTime.utc_now()
    GenServer.call(server, {:record_activity, repo, Keyword.get(opts, :observation), at})
  end

  @doc """
  Records observed activity without waiting for the registry to answer.

  This is what the publish path uses. Activity is bookkeeping for an alert that
  fires on a 60s sweep, so it is never worth blocking an event publish on a
  registry round trip — and a synchronous call there would put this process's
  mailbox on the critical path of every polled event. Ordering is safe without
  the reply because activity timestamps only ever move forwards.
  """
  @spec record_activity_async(String.t(), keyword()) :: :ok
  def record_activity_async(repo, opts \\ []) when is_binary(repo) do
    {server, opts} = Keyword.pop(opts, :server, __MODULE__)
    at = Keyword.get(opts, :at) || DateTime.utc_now()
    GenServer.cast(server, {:record_activity, repo, Keyword.get(opts, :observation), at})
  end

  @doc "Current mode for `repo`. Unknown repos read back as never-configured."
  @spec mode(String.t(), server()) :: DeliveryMode.t()
  def mode(repo, server \\ __MODULE__) when is_binary(repo) do
    GenServer.call(server, {:mode, repo})
  end

  @doc "Transport currently serving `repo` — `:webhook` only once proven."
  @spec transport(String.t(), server()) :: DeliveryMode.transport()
  def transport(repo, server \\ __MODULE__) when is_binary(repo) do
    repo |> mode(server) |> DeliveryMode.transport()
  end

  @doc "Why `repo` is polling, or `nil` when it is proven webhook-backed."
  @spec polling_reason_for(String.t(), server()) :: DeliveryMode.polling_reason()
  def polling_reason_for(repo, server \\ __MODULE__) when is_binary(repo) do
    repo |> mode(server) |> DeliveryMode.polling_reason()
  end

  @doc """
  Marks whether config expects a webhook for `repo`.

  Never promotes a repo to webhook mode; the most it can do is move a repo to
  `configured_unproven`, which still polls at full rate.
  """
  @spec configure(String.t(), boolean(), server()) :: {:ok, DeliveryMode.t()}
  def configure(repo, configured?, server \\ __MODULE__) when is_binary(repo) and is_boolean(configured?) do
    GenServer.call(server, {:configure, repo, configured?})
  end

  @doc "Every known repo's mode, ordered by repo name."
  @spec list(server()) :: [DeliveryMode.t()]
  def list(server \\ __MODULE__), do: GenServer.call(server, :list)

  @doc """
  Runs the silence sweep immediately and returns the repos that degraded.

  The registry sweeps on its own timer; this is the deterministic hook for
  tests and for an operator-triggered refresh.
  """
  @spec sweep(server(), DateTime.t() | nil) :: {:ok, [String.t()]}
  def sweep(server \\ __MODULE__, now \\ nil) do
    GenServer.call(server, {:sweep, now || DateTime.utc_now()})
  end

  @doc "Silence threshold in milliseconds currently in force."
  @spec silence_threshold_ms(server()) :: pos_integer()
  def silence_threshold_ms(server \\ __MODULE__), do: GenServer.call(server, :silence_threshold_ms)

  @impl true
  def init(opts) do
    settings = webhook_settings(opts)

    state = %{
      repos: initial_repos(opts, settings),
      silence_threshold_ms: Keyword.get(opts, :silence_threshold_ms) || settings.silence_threshold_seconds * 1_000,
      sweep_interval_ms: Keyword.get(opts, :sweep_interval_ms) || settings.sweep_interval_seconds * 1_000,
      alert_fun: Keyword.get(opts, :alert_fun, &Alerts.emit_custom/3),
      observed: %{},
      sweep_timer: nil
    }

    {:ok, schedule_sweep(state)}
  end

  defp initial_repos(opts, settings) do
    opts
    |> Keyword.get(:configured_repos, settings.repos)
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&Policy.normalize/1)
    |> Enum.reject(&(&1 == ""))
    |> Map.new(&{&1, DeliveryMode.new(&1, configured?: true)})
  end

  # Config is unavailable in some boot and test contexts. Falling back to the
  # schema defaults keeps the registry startable there, and the defaults are
  # the conservative ones: no configured repos, no widening.
  defp webhook_settings(opts) do
    case Keyword.get(opts, :settings) do
      %{} = settings -> settings
      _missing -> Config.settings().webhooks
    end
  rescue
    _error -> %WebhookSettings{}
  catch
    _kind, _reason -> %WebhookSettings{}
  end

  @impl true
  def handle_call({:record_delivery, repo, at}, _from, state) do
    repo = Policy.normalize(repo)
    current = fetch(state, repo)
    {updated, transition} = DeliveryMode.record_delivery(current, at)
    announce(state, updated, transition)

    {:reply, {:ok, updated}, persist(state, repo, updated)}
  end

  def handle_call({:record_activity, repo, observation, at}, _from, state) do
    repo = Policy.normalize(repo)

    case record_activity_on_known_repo(state, repo, observation, at) do
      {:ok, updated, state} -> {:reply, {:ok, updated}, state}
      {:replay, state} -> {:reply, {:ok, fetch(state, repo)}, state}
      :unknown -> {:reply, {:ok, fetch(state, repo)}, state}
    end
  end

  def handle_call({:mode, repo}, _from, state), do: {:reply, state |> fetch(Policy.normalize(repo)), state}

  def handle_call({:configure, repo, configured?}, _from, state) do
    repo = Policy.normalize(repo)
    {updated, _transition} = state |> fetch(repo) |> DeliveryMode.configure(configured?)
    {:reply, {:ok, updated}, persist(state, repo, updated)}
  end

  def handle_call(:list, _from, state) do
    {:reply, state.repos |> Map.values() |> Enum.sort_by(& &1.repo), state}
  end

  def handle_call({:sweep, now}, _from, state) do
    {state, degraded} = run_sweep(state, now)
    {:reply, {:ok, degraded}, state}
  end

  def handle_call(:silence_threshold_ms, _from, state), do: {:reply, state.silence_threshold_ms, state}

  @impl true
  def handle_cast({:record_activity, repo, observation, at}, state) do
    case record_activity_on_known_repo(state, Policy.normalize(repo), observation, at) do
      {:ok, _updated, state} -> {:noreply, state}
      {:replay, state} -> {:noreply, state}
      :unknown -> {:noreply, state}
    end
  end

  # Activity corroborates a mode; it never creates one. The publish path offers
  # activity for every polled resource, so recording through `fetch/2`'s
  # `Map.get_lazy` would mint a `never_configured` row for any repo the poller
  # touches and fill `list/1` and the CLI table with entries that can never
  # alert. A repo the registry has never heard of has no webhook expectation to
  # corroborate — config seeds the configured ones, and a delivery creates the
  # proven ones, so anything still unknown here is genuinely not our business.
  #
  # Novelty is decided here rather than in the publish path because this is the
  # only place that is structurally able to decide it. The poller re-offers old
  # resources on every sweep by design, and the traffic that matters most —
  # events the fleet filters — is never published, so it is never marked
  # processed and never enters the publish dedup window. Both of those stores
  # are therefore blind to exactly the traffic that needs deduplicating, and
  # inferring novelty from a store that the path in question never writes to is
  # the mistake this guard exists to stop repeating.
  defp record_activity_on_known_repo(state, repo, observation, at) do
    case Map.fetch(state.repos, repo) do
      {:ok, mode} ->
        record_novel_activity(state, repo, mode, observation, at)

      :error ->
        :unknown
    end
  end

  # A `nil` observation has no stable identity to compare, so it always counts.
  defp record_novel_activity(state, repo, mode, nil, at) do
    {updated, _transition} = DeliveryMode.record_activity(mode, at)
    {:ok, updated, persist(state, repo, updated)}
  end

  defp record_novel_activity(state, repo, mode, observation, at) do
    key = {repo, observation}
    seen? = Map.has_key?(state.observed, key)
    # Refreshed on every sighting, so a resource the poller keeps re-offering
    # never ages out and never gets counted a second time.
    state = put_in(state.observed[key], System.monotonic_time(:millisecond))

    if seen? do
      {:replay, state}
    else
      {updated, _transition} = DeliveryMode.record_activity(mode, at)
      {:ok, updated, persist(state, repo, updated)}
    end
  end

  @impl true
  def handle_info(:sweep, state) do
    {state, _degraded} = run_sweep(state, DateTime.utc_now())
    {:noreply, schedule_sweep(state)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp run_sweep(state, now) do
    {repos, degraded} =
      Enum.reduce(state.repos, {%{}, []}, fn {repo, mode}, {acc, degraded} ->
        {updated, transition} = DeliveryMode.sweep(mode, now, state.silence_threshold_ms)
        announce(state, updated, transition)

        # `announce/3` publishes `:degraded` on the transition *into* degraded
        # mode. A repo that stays degraded re-publishes on every later sweep, so
        # the gap-based view-state sources keep a coarse re-list for the whole
        # outage instead of freezing after the one that detected it. That clock
        # only runs while the event stream is known to be lying, which is exactly
        # the case #2325's zero-poll steady state is not built for.
        if transition == :none and updated.state == :degraded, do: publish_degraded(repo)

        ModeTable.put(repo, updated)

        {Map.put(acc, repo, updated), if(transition == :degraded, do: [repo | degraded], else: degraded)}
      end)

    {%{state | repos: repos, observed: Policy.prune_observed(state.observed, state.silence_threshold_ms)}, Enum.sort(degraded)}
  end

  defp schedule_sweep(state) do
    if state.sweep_timer, do: Process.cancel_timer(state.sweep_timer)
    %{state | sweep_timer: Process.send_after(self(), :sweep, state.sweep_interval_ms)}
  end

  defp fetch(state, repo), do: Map.get_lazy(state.repos, repo, fn -> DeliveryMode.new(repo) end)

  # Every mode change is published to `ModeTable` so a hot read path
  # (`Aiur.GitHub.ReadCache.Policy`) can read the transport without a round
  # trip through this process. Publishing here — at each write site — rather
  # than on read keeps the two views from drifting: a repo this process knows
  # is a repo the table knows, and the sweep cannot degrade one without the
  # other seeing it.
  defp persist(state, repo, mode) do
    ModeTable.put(repo, mode)
    put_in(state.repos[repo], mode)
  end

  defp announce(state, %DeliveryMode{repo: repo} = mode, :degraded) do
    DeliveryModeEvents.publish(mode, :degraded)

    publish_degraded(repo)
    emit_alert(state, mode, :degraded)
  end

  defp announce(state, mode, :never_delivered), do: emit_alert(state, mode, :never_delivered)

  defp announce(state, %DeliveryMode{repo: repo} = mode, :recovered) do
    # The trailing-edge signal: the gap has closed, so every projection that
    # rode the event stream through the degraded window re-lists to recover what
    # the gap dropped. Published on both channels: `DeliveryModeEvents`
    # (`{:webhook_mode_changed, ...}`, the #2313 Build Order projection) and the
    # `@recovered_topic` broadcast (`{:webhook_recovered, repo}`, the #2325
    # view-state sources).
    DeliveryModeEvents.publish(mode, :recovered)
    publish_recovered(repo)
    emit_alert(state, mode, :recovered)
  end

  defp announce(_state, _mode, _transition), do: :ok

  defp emit_alert(state, mode, transition) do
    {name, message, opts} = Policy.alert(mode, transition, state.silence_threshold_ms)
    emit(state, name, message, opts)
  end

  defp emit(state, name, message, opts) do
    state.alert_fun.(name, message, opts)
  rescue
    error -> Logger.warning("Webhooks.ModeRegistry alert #{name} failed: #{Exception.message(error)}")
  catch
    :exit, reason -> Logger.warning("Webhooks.ModeRegistry alert #{name} exited: #{inspect(reason)}")
  end

  # Best-effort, and deliberately quiet on failure: a subscriber that misses
  # the broadcast re-converges on the next degradation or an explicit refresh,
  # and the alert is the operator-facing signal for the same transition. A
  # broadcast must never take down the sweep that just did real work.
  defp publish_degraded(repo) do
    if Process.whereis(Aiur.PubSub) do
      Phoenix.PubSub.broadcast(Aiur.PubSub, @degraded_topic, {:webhook_degraded, repo})
    end

    :ok
  rescue
    error -> Logger.warning("Webhooks.ModeRegistry publish degraded failed: #{Exception.message(error)}")
  catch
    :exit, reason -> Logger.warning("Webhooks.ModeRegistry publish degraded exited: #{inspect(reason)}")
  end

  # Same best-effort discipline as `publish_degraded/1`: recovery is a
  # convenience for projections, and the alert that follows is the durable
  # operator-facing record of the same transition.
  defp publish_recovered(repo) do
    if Process.whereis(Aiur.PubSub) do
      Phoenix.PubSub.broadcast(Aiur.PubSub, @recovered_topic, {:webhook_recovered, repo})
    end

    :ok
  rescue
    error -> Logger.warning("Webhooks.ModeRegistry publish recovered failed: #{Exception.message(error)}")
  catch
    :exit, reason -> Logger.warning("Webhooks.ModeRegistry publish recovered exited: #{inspect(reason)}")
  end
end
