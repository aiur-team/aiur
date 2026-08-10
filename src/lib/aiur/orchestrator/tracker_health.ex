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
  @spec next_poll_delay_ms(State.t()) :: non_neg_integer()
  def next_poll_delay_ms(%State{} = state) do
    case github_next_poll_delay_ms(state) do
      github_ms when is_integer(github_ms) and is_integer(state.poll_interval_ms) ->
        max(github_ms, state.poll_interval_ms)

      github_ms when is_integer(github_ms) ->
        github_ms

      _none ->
        state.poll_interval_ms
    end
  end

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
