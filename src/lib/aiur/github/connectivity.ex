defmodule Aiur.GitHub.Connectivity do
  require Logger

  @moduledoc """
  Backoff + escalation policy keyed off the `Aiur.GitHub.Client` error
  taxonomy (`{:github, classification, detail}`).

  GitHub fetch failures used to only `Logger.warning` forever (#617), so an
  Executor never learned that agent workspaces had lost DNS or auth access
  while everything quietly stalled. This module turns the *classification* of
  a failure into an Executor-facing decision:

    * `:dns` / `:timeout` / `:tls` / `:transport` — capped exponential backoff;
      a sustained streak of the *fixable* connectivity class (`:dns`) raises a
      loud, Executor-visible blocker.
    * `:rate_limited` — hold until GitHub's reset when present, otherwise honor
      `Retry-After` / `X-Poll-Interval`.
    * `:auth` — escalate immediately (never silently retry an expired token),
      and a sustained streak raises the same Executor-visible blocker.

  The streak state is a plain map so each poller can keep it inside its own
  GenServer state. `note_failure/3` is pure and only *returns* the alerts
  that should fire; `record_failure/5` is the shared poller fold that emits
  them and derives the normalized backoff delay.
  """

  # Classes that represent a sustained, Executor-fixable break in connectivity
  # or credentials. A streak of these is what we escalate; transient classes
  # (`:timeout`, `:rate_limited`, `:http`, `:tls`, `:transport`) self-heal or
  # are GitHub-side and would only spam the Executor.
  @escalating_classes [:dns, :auth]

  @escalation_threshold 3

  @base_backoff_ms 1_000
  @max_backoff_ms 60_000
  @max_reset_backoff_ms 3_600_000

  @type source :: atom()
  @type classification :: atom()
  @type streaks :: %{optional(source()) => {classification(), pos_integer()}}
  @type alert :: %{source: source(), classification: classification(), count: pos_integer()}

  @doc "Consecutive same-class failures required before an Executor alert fires."
  @spec escalation_threshold() :: pos_integer()
  def escalation_threshold, do: @escalation_threshold

  @doc "Upper bound on exponential backoff, in milliseconds."
  @spec max_backoff_ms() :: pos_integer()
  def max_backoff_ms, do: @max_backoff_ms

  @doc """
  Records one classified failure for `source`. Returns the updated streak map
  and a (possibly empty) list of Executor alerts that should be emitted now.

  An alert fires exactly once, on the failure that crosses the threshold for a
  sustained `:dns`/`:auth` streak — repeated failures past the threshold stay
  silent until `note_success/2` re-arms the source.
  """
  @spec note_failure(streaks(), source(), classification()) :: {streaks(), [alert()]}
  def note_failure(streaks, source, classification)
      when is_map(streaks) and is_atom(source) and is_atom(classification) do
    count =
      case Map.get(streaks, source) do
        {^classification, n} -> n + 1
        # A new source or a switch to a different class restarts the streak.
        _ -> 1
      end

    streaks = Map.put(streaks, source, {classification, count})

    alerts =
      if classification in @escalating_classes and count == @escalation_threshold do
        [%{source: source, classification: classification, count: count}]
      else
        []
      end

    {streaks, alerts}
  end

  @doc "Clears the streak for `source` after a successful poll, re-arming escalation."
  @spec note_success(streaks(), source()) :: streaks()
  def note_success(streaks, source) when is_map(streaks) and is_atom(source) do
    Map.delete(streaks, source)
  end

  @doc """
  Shared poller-side fold over one classified failure (dup-infra.md
  cluster 2). Calls `note_failure/3`, emits the
  `system.github.connectivity_lost` Executor blocker for every returned
  alert, then derives the next delay from `backoff_ms/3` using the
  source's current streak count, normalizing `:escalate` to
  `max_backoff_ms/0` and any non-integer result to `base_interval_ms`.

  Options:

    * `:repo` — `"owner/repo"` for the alert message (optional).
    * `:detail` — detail map forwarded to `backoff_ms/3` (default `%{}`).
    * `:emit_fun` — `(name, message, opts) -> term` alert emitter
      override for tests (default `Aiur.Alerts.emit_custom/3`).
  """
  @spec record_failure(streaks(), source(), classification(), non_neg_integer(), keyword()) ::
          {streaks(), non_neg_integer()}
  def record_failure(streaks, source, classification, base_interval_ms, opts \\ []) do
    {streaks, alerts} = note_failure(streaks, source, classification)
    emit_fun = Keyword.get(opts, :emit_fun, &Aiur.Alerts.emit_custom/3)

    Enum.each(alerts, fn alert ->
      message = alert_message(alert, repo: Keyword.get(opts, :repo))

      emit_fun.("system.github.connectivity_lost", message,
        reason: message,
        needs_attention: true,
        severity: "warning"
      )
    end)

    delay_ms =
      classification
      |> backoff_ms(streak_count(streaks, source), Keyword.get(opts, :detail, %{}))
      |> normalize_backoff_ms(base_interval_ms)

    {streaks, delay_ms}
  end

  @doc """
  Current consecutive-failure count for `source`, defaulting to 1 when
  the source has no recorded streak (used as the attempt count for
  `backoff_ms/3`).
  """
  @spec streak_count(streaks(), source()) :: pos_integer()
  def streak_count(streaks, source) when is_map(streaks) and is_atom(source) do
    case Map.get(streaks, source) do
      {_classification, count} when is_integer(count) and count > 0 -> count
      _ -> 1
    end
  end

  defp normalize_backoff_ms(:escalate, _base_interval_ms), do: @max_backoff_ms

  defp normalize_backoff_ms(delay_ms, _base_interval_ms)
       when is_integer(delay_ms) and delay_ms >= 0,
       do: delay_ms

  defp normalize_backoff_ms(_delay_ms, base_interval_ms), do: base_interval_ms

  @doc """
  Returns how long to wait before the next attempt for a classified failure.

    * `:rate_limited` — wait until `reset_at` if present, else use
      `retry_after` (seconds), `poll_interval`, or the capped exponential
      default. Reset waits may exceed the ordinary transport cap, but are
      bounded to one hour.
    * `:dns` / `:timeout` / `:tls` / `:transport` / `:http` — capped exponential
      backoff that grows with `attempt`.
    * `:local_hold` — the hold carries its own `reset_at`; back off only until
      it (a bounded window, never the exponential escalation curve). A hold with
      no `reset_at` falls back to the base backoff.
    * `:unclassified` — the reason did not match a known shape. Conservative
      base backoff, no escalation: an unknown reason must not be treated as lost
      connectivity, which is exactly the misattribution #2429 removes.
    * `:auth` — `:escalate` (don't retry an expired/invalid token).
  """
  @spec backoff_ms(classification(), pos_integer(), map()) :: non_neg_integer() | :escalate
  def backoff_ms(:auth, _attempt, _detail), do: :escalate

  def backoff_ms(:local_hold, _attempt, detail) do
    case hold_reset_delay_ms(detail) do
      delay_ms when is_integer(delay_ms) and delay_ms >= 0 -> delay_ms
      _missing_or_passed -> @base_backoff_ms
    end
  end

  def backoff_ms(:unclassified, _attempt, _detail), do: @base_backoff_ms

  def backoff_ms(:rate_limited, attempt, detail) do
    cond do
      reset_delay = reset_delay_ms(detail) ->
        reset_delay

      is_integer(detail[:retry_after]) and detail[:retry_after] > 0 ->
        cap_backoff(detail[:retry_after] * 1_000)

      is_integer(detail[:poll_interval]) and detail[:poll_interval] > 0 ->
        cap_backoff(detail[:poll_interval] * 1_000)

      true ->
        exponential(attempt)
    end
  end

  def backoff_ms(_classification, attempt, _detail), do: exponential(attempt)

  defp cap_backoff(delay_ms), do: min(delay_ms, @max_backoff_ms)

  # A local budget hold names its own release time as a `%DateTime{}` in the
  # hold map (unlike `:rate_limited`'s ISO-8601 string). The wait is bounded by
  # that reset: seconds-long holds back off for seconds, and a hold whose
  # reset already passed (or carried no reset) waits nothing, so polling resumes
  # immediately instead of riding a network-failure escalation curve (#2429).
  defp hold_reset_delay_ms(detail) do
    case get_in(detail, [:hold, :reset_at]) do
      %DateTime{} = reset_at ->
        now = Map.get(detail, :now, DateTime.utc_now())
        max(DateTime.diff(reset_at, now, :millisecond), 0)

      _missing ->
        nil
    end
  end

  defp reset_delay_ms(detail) do
    now = Map.get(detail, :now, DateTime.utc_now())

    with raw_reset_at when is_binary(raw_reset_at) <- Map.get(detail, :reset_at),
         {:ok, reset_at, _offset} <- DateTime.from_iso8601(raw_reset_at),
         delay_ms when delay_ms > 0 <- DateTime.diff(reset_at, now, :millisecond) do
      cap_reset_backoff(delay_ms, raw_reset_at)
    else
      _missing_or_expired -> nil
    end
  end

  defp cap_reset_backoff(delay_ms, raw_reset_at) when delay_ms > @max_reset_backoff_ms do
    Logger.warning("github_reset_backoff_clamped raw_reset_at=#{inspect(raw_reset_at)} computed_delay_ms=#{delay_ms} max_delay_ms=#{@max_reset_backoff_ms}")

    @max_reset_backoff_ms
  end

  defp cap_reset_backoff(delay_ms, _raw_reset_at), do: delay_ms

  defp exponential(attempt) when is_integer(attempt) and attempt >= 1 do
    cap_backoff(@base_backoff_ms * 2 ** (attempt - 1))
  end

  defp exponential(_attempt), do: @base_backoff_ms

  @doc """
  Classifies a `git ls-remote` failure (the `LsRemoteTicker`'s surface) into
  the same taxonomy. `git` reports DNS outages as "Could not resolve host"
  (exactly the #617 symptom) and auth failures as "could not read
  Username"/"Authentication failed"; everything else is a generic transport
  break.
  """
  @spec classify_ls_remote(term()) :: classification()
  def classify_ls_remote({:git_ls_remote_failed, _exit_code, output}) when is_binary(output) do
    classify_ls_remote_output(output)
  end

  def classify_ls_remote({:git_ls_remote_exception, message}) when is_binary(message) do
    classify_ls_remote_output(message)
  end

  def classify_ls_remote({:git_ls_remote_timeout, _timeout_ms, _output}), do: :timeout

  def classify_ls_remote({:git_ls_remote_timeout, _timeout_ms}), do: :timeout

  def classify_ls_remote(_reason), do: :transport

  defp classify_ls_remote_output(output) do
    down = String.downcase(output)

    cond do
      String.contains?(down, "could not resolve host") -> :dns
      String.contains?(down, "name or service not known") -> :dns
      String.contains?(down, "temporary failure in name resolution") -> :dns
      String.contains?(down, "authentication failed") -> :auth
      String.contains?(down, "could not read username") -> :auth
      String.contains?(down, "permission denied") -> :auth
      String.contains?(down, "timed out") -> :timeout
      true -> :transport
    end
  end

  @doc """
  Builds the Executor-facing alert message for an escalated connectivity
  blocker. Used by pollers to drive `Aiur.Alerts.emit_custom/3`.
  """
  @spec alert_message(alert(), keyword()) :: String.t()
  def alert_message(%{source: source, classification: classification, count: count}, opts \\ []) do
    repo = Keyword.get(opts, :repo)
    repo_suffix = if repo, do: " for #{repo}", else: ""

    "GitHub #{classification_phrase(classification)} from #{source}#{repo_suffix}: " <>
      "#{count} consecutive failures. Agents cannot reach GitHub while the Executor shell may. " <>
      "Check DNS/proxy/credentials in the agent workspace environment."
  end

  defp classification_phrase(:dns), do: "DNS resolution failures"
  defp classification_phrase(:auth), do: "authentication failures"
  defp classification_phrase(other), do: "#{other} failures"
end
