defmodule Aiur.Orchestrator.TrackerHealth do
  @moduledoc """
  Maintains tracker preflight and GitHub connectivity health state.
  All functions execute inside the orchestrator GenServer process.
  """

  require Logger

  alias Aiur.{Alerts, Config}
  alias Aiur.GitHub.Client, as: GitHubClient
  alias Aiur.GitHub.Connectivity, as: GitHubConnectivity
  alias Aiur.GitHub.Tracker, as: GitHubTracker
  alias Aiur.Orchestrator
  alias Aiur.Orchestrator.DispatchPolicy
  alias Aiur.Orchestrator.State
  alias Aiur.PollCadence
  alias Aiur.Webhooks
  alias Aiur.Webhooks.IntervalPolicy

  @spec note_github_connectivity_success(State.t(), atom()) :: State.t()
  def note_github_connectivity_success(%State{} = state, source) do
    %{
      state
      | github_connectivity: GitHubConnectivity.note_success(state.github_connectivity, source),
        github_poll_delays: Map.delete(state.github_poll_delays, source)
    }
  end

  @doc false
  @spec note_github_connectivity_failure(State.t(), atom(), term()) :: State.t()
  def note_github_connectivity_failure(%State{} = state, source, reason) do
    classification = connectivity_classification(reason)
    detail = Orchestrator.connectivity_detail(reason)

    if classification == :unclassified do
      # F2 of #2429: a reason this classifier does not recognize is itself a
      # finding. Surface the raw term instead of silently stamping it `:transport`
      # (which asserted "connectivity lost" for failures that have nothing to do
      # with the network).
      Logger.warning("github_connectivity_unclassified source=#{source} reason=#{inspect(reason)} classification=#{classification}")
    end

    {streaks, alerts} =
      GitHubConnectivity.note_failure(state.github_connectivity, source, classification)

    Enum.each(alerts, &emit_github_connectivity_alert/1)

    backoff_ms =
      classification
      |> GitHubConnectivity.backoff_ms(connectivity_streak_count(streaks, source), detail)
      |> normalize_github_backoff_ms(state)

    %{
      state
      | github_connectivity: streaks,
        github_poll_delays: Map.put(state.github_poll_delays, source, backoff_ms)
    }
  end

  # A local budget hold is not connectivity: it must not ride the transport
  # escalation curve and must not emit `system.github.connectivity_lost` (#2429).
  # Recognized in the raw `{:aiur, :locally_held, hold}` shape and in the
  # transport-classified `{:github, :transport, %{reason: ...}}` shape old
  # `Errors.classify_error` versions produced, so a hold is never misread as a
  # network break.
  defp connectivity_classification({:aiur, :locally_held, _hold}), do: :local_hold
  defp connectivity_classification({:github, :local_hold, _detail}), do: :local_hold

  defp connectivity_classification({:github, :transport, %{reason: {:aiur, :locally_held, _hold}}}),
    do: :local_hold

  defp connectivity_classification({:github, classification, _detail}), do: classification
  defp connectivity_classification({:github_api_status, 429}), do: :rate_limited

  # Catch-all that assigns no specific meaning: an unknown reason is `:unclassified`
  # (handled conservatively, surfaced with its raw term by the caller) rather than
  # being asserted to be `:transport` (#2429 F2).
  defp connectivity_classification(_reason), do: :unclassified

  defp connectivity_streak_count(streaks, source) do
    case Map.get(streaks, source) do
      {_classification, count} when is_integer(count) and count > 0 -> count
      _ -> 1
    end
  end

  defp normalize_github_backoff_ms(:escalate, _state), do: GitHubConnectivity.max_backoff_ms()

  defp normalize_github_backoff_ms(delay_ms, _state) when is_integer(delay_ms) and delay_ms >= 0,
    do: delay_ms

  defp normalize_github_backoff_ms(_delay_ms, %State{} = state), do: state.poll_interval_ms

  @doc false
  @spec note_github_poll_interval(State.t(), atom(), pos_integer() | nil) :: State.t()
  def note_github_poll_interval(%State{} = state, source, seconds)
      when is_integer(seconds) and seconds > 0 do
    %{state | github_poll_delays: Map.put(state.github_poll_delays, source, seconds * 1_000)}
  end

  def note_github_poll_interval(%State{} = state, _source, _seconds), do: state

  # GitHub's delays are floors, not targets: `X-Poll-Interval` says "do not poll
  # faster than this" and a connectivity backoff says "wait at least this long".
  # The configured interval is a floor too. So the next tick is the widest of
  # them, never the narrowest — returning a GitHub floor outright would let a
  # 60s header override a deliberately widened `polling.interval_seconds` and
  # quietly undo the quota saving it was set to buy.
  #
  # The base floor composes the webhook and idle widening factors rather than
  # using the raw configured interval. `IntervalPolicy` widens the webhook
  # portion only for a repo proven webhook-backed, so this is the seam where the cutover actually happens —
  # and, more importantly, where it comes back. When W-6's silence sweep
  # degrades a repo, its transport reverts to `:polling`, `IntervalPolicy`
  # returns the base interval again, and the very next tick is computed at the
  # tighter value. Nothing has to remember to restore it.
  #
  # `opts` are a test seam (`:repo`, `:server`, `:transport`, `:widen_factor`)
  # forwarded to `IntervalPolicy`; production calls this with none and reads
  # the live registry.
  @spec next_poll_delay_ms(State.t(), keyword()) :: non_neg_integer()
  def next_poll_delay_ms(%State{} = state, opts \\ []) do
    poll_schedule(state, opts).delay_ms
  end

  @doc false
  @spec poll_schedule(State.t(), keyword()) :: %{
          delay_ms: non_neg_integer(),
          idle_backoff?: boolean(),
          idle_widen_factor: float()
        }
  def poll_schedule(%State{} = state, opts \\ []) do
    webhook_ms = webhook_adjusted_interval_ms(state, opts)
    idle_factor = idle_widen_factor(opts)
    idle_backoff? = idle_fleet?(state) and idle_factor > 1.0
    base_ms = if idle_backoff?, do: IntervalPolicy.widen(webhook_ms, idle_factor), else: webhook_ms

    delay_ms =
      case github_next_poll_delay_ms(state) do
        github_ms when is_integer(github_ms) and is_integer(base_ms) -> max(github_ms, base_ms)
        github_ms when is_integer(github_ms) -> github_ms
        _none -> base_ms
      end

    %{delay_ms: delay_ms, idle_backoff?: idle_backoff?, idle_widen_factor: idle_factor}
  end

  @doc false
  @spec publish_poll_cadence(State.t(), map()) :: :ok
  def publish_poll_cadence(%State{} = state, %{delay_ms: delay_ms} = schedule)
      when is_integer(delay_ms) and delay_ms > 0 do
    # `:dispatch` is the interval the tick actually scheduled — GitHub
    # `X-Poll-Interval` / connectivity backoff floors included. Every other
    # class composes the same widening the schedule applied (webhook factor for
    # a proven webhook-backed repo, idle factor while the fleet is idle) on top
    # of its own class base, so a class whose `polling.intervals` entry differs
    # from `interval_seconds` resolves its own live cadence instead of silently
    # inheriting the dispatch one (#2309).
    PollCadence.publish_effective_interval_ms(delay_ms, class: :dispatch)
    idle_factor = if schedule.idle_backoff?, do: schedule.idle_widen_factor, else: 1.0
    publish_class_cadences(state, Aiur.GitHub.Config.repo(), idle_factor)
    :ok
  end

  # A non-positive delay — a momentary "poll now" reschedule, say — leaves the
  # last published cadences in force rather than crashing the orchestrator. A
  # skipped publish is never worse than a crash for a freshness bookkeeping
  # step.
  def publish_poll_cadence(_state, _schedule), do: :ok

  # `state` is threaded through so every class composes the same GitHub
  # `X-Poll-Interval` / connectivity backoff floor the dispatch schedule
  # applies. Before #2309 every consumer derived from the dispatch tick — floor
  # included — so a class whose published cadence dropped the floor would read
  # *narrower* than the daemon actually polls while GitHub throttles us, which
  # is a behaviour change on a default config. The floor keeps that from
  # happening: a widened class still resolves no faster than the tick that
  # drives its loop.
  defp publish_class_cadences(%State{} = state, repo, idle_factor) when is_binary(repo) do
    for class <- PollCadence.poll_classes() -- [:dispatch] do
      PollCadence.publish_effective_interval_ms(class_effective_ms(state, class, repo, idle_factor), class: class)
    end

    :ok
  end

  defp publish_class_cadences(_state, _repo, _idle_factor), do: :ok

  defp class_effective_ms(%State{} = state, class, repo, idle_factor) do
    case effective_class_base_ms(class, repo) do
      # On-demand class: no timer, publish 0 so status shows `planning=0s` and
      # any tick-riding loop for the class is fully disabled (#2309).
      0 ->
        0

      base_ms ->
        webhook_ms = IntervalPolicy.poll_interval_ms(base_ms, repo)
        widened_ms = if idle_factor > 1.0, do: IntervalPolicy.widen(webhook_ms, idle_factor), else: webhook_ms

        case github_next_poll_delay_ms(state) do
          github_ms when is_integer(github_ms) -> max(github_ms, widened_ms)
          _none -> widened_ms
        end
    end
  end

  # The `:review` divergence is safe only while webhooks prove coverage: a repo
  # that polls for comments has no arrival signal, so its safety-net poll must
  # keep the dispatch rate no matter what `intervals.review` says — a wide
  # `review` on a polling repo would be a silent minutes-long floor on
  # operator-comment wakes. On a proven webhook-backed repo the configured
  # review cadence applies; on a polling repo it resolves to the dispatch
  # cadence (exactly the behaviour before this class existed).
  defp effective_class_base_ms(:review, repo) do
    if Webhooks.webhook_backed?(repo) do
      PollCadence.base_interval_ms(class: :review)
    else
      PollCadence.base_interval_ms(class: :dispatch)
    end
  end

  defp effective_class_base_ms(class, _repo), do: PollCadence.base_interval_ms(class: class)

  # The fleet is only actually idle when it has nothing to do AND has observed
  # that. Four conditions, all required:
  #
  #   * at least one poll cycle has completed (`poll_cycles_completed > 0`) — a
  #     freshly restarted daemon has observed no idleness, so it polls at the
  #     base interval first (#2138);
  #   * no agent is actively running;
  #   * the candidate snapshot is fresh — a cycle whose fetch failed observed
  #     nothing, so an unobserved queue must never count as an idle one. This is
  #     the daemon-side half of the CLI's "has not polled yet" rule (#2138,
  #     #2278);
  #   * either the daemon is globally paused or there is no queued dispatch
  #     demand — a live fleet with claimable tickets is not idle, it simply has
  #     not looked yet, and backing off there is exactly the "idles up to 20
  #     minutes with work waiting" defect this gates against (#2138).
  #
  # A globally paused fleet is treated as idle even with tickets waiting: it
  # cannot dispatch anyway, and unpausing wakes a prompt poll
  # (`GlobalPause.maybe_wake_after_unpause`).
  defp idle_fleet?(%State{} = state) do
    State.active_running_count(state.running) == 0 and
      state.poll_cycles_completed > 0 and
      state.candidate_snapshot_fresh? == true and
      (state.globally_paused == true or not queued_dispatch_demand?(state))
  end

  # Reuses the same dispatch-eligibility scan as the capacity snapshot so the
  # backoff never widens the poll while dispatchable work is waiting. Fails
  # toward demand (a prompt poll) rather than toward backoff: an unreadable
  # config — or any unexpected `ArgumentError` inside the scan — must never
  # silently become "no dispatchable demand" and widen the poll to the 10-minute
  # ceiling under a condition nobody will notice (#2138 review P1).
  defp queued_dispatch_demand?(%State{} = state) do
    DispatchPolicy.queued_dispatch_demand?(
      Map.values(state.last_polled_issues),
      state
    )
  rescue
    ArgumentError ->
      Logger.warning("Idle-backoff demand scan failed; assuming dispatchable demand (poll stays at base)")
      true
  end

  defp idle_widen_factor(opts) do
    factor =
      Keyword.get_lazy(opts, :idle_widen_factor, fn ->
        case Config.settings() do
          {:ok, settings} -> settings.polling.idle_widen_factor
          _error -> 1.0
        end
      end)

    IntervalPolicy.widen_factor(widen_factor: factor)
  end

  # A repo we cannot name cannot be looked up, so it keeps the configured
  # interval — the same default-to-polling answer `Aiur.Webhooks` gives for an
  # unknown repo.
  defp webhook_adjusted_interval_ms(%State{poll_interval_ms: base_ms}, opts)
       when is_integer(base_ms) and base_ms > 0 do
    case Keyword.get_lazy(opts, :repo, &Aiur.GitHub.Config.repo/0) do
      repo when is_binary(repo) -> IntervalPolicy.poll_interval_ms(base_ms, repo, opts)
      _unknown -> base_ms
    end
  end

  defp webhook_adjusted_interval_ms(%State{poll_interval_ms: base_ms}, _opts), do: base_ms

  @doc false
  @spec github_next_poll_delay_ms(State.t()) :: non_neg_integer() | nil
  def github_next_poll_delay_ms(%State{github_poll_delays: delays}) when is_map(delays) do
    delays
    |> Map.values()
    |> Enum.filter(&(is_integer(&1) and &1 >= 0))
    |> Enum.max(fn -> nil end)
  end

  def github_next_poll_delay_ms(_state), do: nil

  defp emit_github_connectivity_alert(alert) do
    message = GitHubConnectivity.alert_message(alert, repo: Aiur.GitHub.Config.repo())

    Alerts.emit_custom("system.github.connectivity_lost", message,
      reason: message,
      needs_attention: true,
      severity: "warning"
    )
  end

  @spec ensure_tracker_preflight(State.t()) :: {:ok, State.t()} | {:error, term(), State.t()}
  def ensure_tracker_preflight(%State{} = state) do
    case Config.validate!() do
      :ok ->
        case Config.tracker_kind() do
          "github" -> ensure_github_auth_preflight(state)
          _ -> {:ok, state}
        end

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  # `ensure_auth_preflight/0`, not `auth_preflight/0`: this runs on every poll
  # cycle, and re-proving a credential that has not changed cost 12 billed REST
  # requests an hour at idle. The memo behind it is dropped the moment GitHub
  # answers a call unauthenticated, so a revoked token still lands here as the
  # normal preflight diagnostic on the next cycle.
  defp ensure_github_auth_preflight(%State{} = state) do
    case GitHubTracker.ensure_auth_preflight() do
      :ok -> {:ok, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  @spec log_tracker_preflight_error(term()) :: :ok
  def log_tracker_preflight_error({:github_auth_preflight_failed, _diagnostic} = reason) do
    Logger.error(GitHubClient.format_auth_preflight_error(reason))
  end

  def log_tracker_preflight_error(:missing_linear_api_token),
    do: Logger.error("Linear API token missing in .aiur/config")

  def log_tracker_preflight_error(:missing_linear_project_slug),
    do: Logger.error("Linear project slug missing in .aiur/config")

  def log_tracker_preflight_error(:missing_tracker_kind),
    do: Logger.error("Tracker kind missing in .aiur/config")

  def log_tracker_preflight_error({:unsupported_tracker_kind, kind}),
    do: Logger.error("Unsupported tracker kind in .aiur/config: #{inspect(kind)}")

  def log_tracker_preflight_error({:invalid_workflow_config, message}),
    do: Logger.error("Invalid .aiur/config config: #{message}")

  def log_tracker_preflight_error({:missing_workflow_file, path, reason}),
    do: Logger.error("Missing .aiur/config at #{path}: #{inspect(reason)}")

  def log_tracker_preflight_error({:missing_prompt_file, path, reason}),
    do: Logger.error("Missing prompt_file at #{path}: #{inspect(reason)}")

  def log_tracker_preflight_error(:workflow_front_matter_not_a_map),
    do: Logger.error("Failed to parse .aiur/config: top-level YAML must be a map")

  def log_tracker_preflight_error({:workflow_parse_error, reason}),
    do: Logger.error("Failed to parse .aiur/config: #{inspect(reason)}")

  def log_tracker_preflight_error({:missing_hooks_file, path, reason}),
    do: Logger.error("Missing hooks_file at #{path}: #{inspect(reason)}")

  def log_tracker_preflight_error({:invalid_hooks_file, path, reason}),
    do: Logger.error("Invalid hooks_file at #{path}: #{inspect(reason)}")

  def log_tracker_preflight_error(reason),
    do: Logger.error("Tracker preflight failed for #{tracker_log_label()}: #{inspect(reason)}")

  @spec log_tracker_fetch_error(term()) :: :ok
  def log_tracker_fetch_error(reason) do
    Logger.error("Failed to fetch from #{tracker_log_label()}: #{inspect(reason)}")
  end

  defp tracker_log_label do
    case Config.settings() do
      {:ok, settings} -> settings.tracker.kind || "tracker"
      _ -> "tracker"
    end
  end
end
