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
  alias Aiur.Orchestrator.State
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

  defp connectivity_classification({:github, classification, _detail}), do: classification
  defp connectivity_classification({:github_api_status, 429}), do: :rate_limited
  defp connectivity_classification(_reason), do: :transport

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

  defp idle_fleet?(%State{running: running}), do: State.active_running_count(running) == 0
  defp idle_fleet?(_state), do: false

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

  defp ensure_github_auth_preflight(%State{} = state) do
    case GitHubTracker.auth_preflight() do
      :ok -> {:ok, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  @spec log_tracker_preflight_error(term()) :: :ok
  def log_tracker_preflight_error({:github_auth_preflight_failed, _diagnostic} = reason) do
    Logger.error(GitHubClient.format_auth_preflight_error(reason))
  end

  def log_tracker_preflight_error(:missing_linear_api_token),
    do: Logger.error("Linear API token missing in .aiurconfig")

  def log_tracker_preflight_error(:missing_linear_project_slug),
    do: Logger.error("Linear project slug missing in .aiurconfig")

  def log_tracker_preflight_error(:missing_tracker_kind),
    do: Logger.error("Tracker kind missing in .aiurconfig")

  def log_tracker_preflight_error({:unsupported_tracker_kind, kind}),
    do: Logger.error("Unsupported tracker kind in .aiurconfig: #{inspect(kind)}")

  def log_tracker_preflight_error({:invalid_workflow_config, message}),
    do: Logger.error("Invalid .aiurconfig config: #{message}")

  def log_tracker_preflight_error({:missing_workflow_file, path, reason}),
    do: Logger.error("Missing .aiurconfig at #{path}: #{inspect(reason)}")

  def log_tracker_preflight_error({:missing_prompt_file, path, reason}),
    do: Logger.error("Missing prompt_file at #{path}: #{inspect(reason)}")

  def log_tracker_preflight_error(:workflow_front_matter_not_a_map),
    do: Logger.error("Failed to parse .aiurconfig: top-level YAML must be a map")

  def log_tracker_preflight_error({:workflow_parse_error, reason}),
    do: Logger.error("Failed to parse .aiurconfig: #{inspect(reason)}")

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
