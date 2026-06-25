defmodule Aiur.GitHub.Connectivity do
  @moduledoc """
  Backoff + escalation policy keyed off the `Aiur.GitHub.Client` error
  taxonomy (`{:github, classification, detail}`).

  GitHub fetch failures used to only `Logger.warning` forever (#617), so an
  operator never learned that agent workspaces had lost DNS or auth access
  while everything quietly stalled. This module turns the *classification* of
  a failure into an operator-facing decision:

    * `:dns` / `:timeout` / `:tls` / `:transport` — capped exponential backoff;
      a sustained streak of the *fixable* connectivity class (`:dns`) raises a
      loud, operator-visible blocker.
    * `:rate_limited` — honor GitHub's `Retry-After` / `X-Poll-Interval`.
    * `:auth` — escalate immediately (never silently retry an expired token),
      and a sustained streak raises the same operator-visible blocker.

  The streak state is a plain map so each poller can keep it inside its own
  GenServer state; the functions here are pure (the alert *side effect* is the
  caller's job — `note_failure/3` only *returns* the alerts that should fire).
  """

  # Classes that represent a sustained, operator-fixable break in connectivity
  # or credentials. A streak of these is what we escalate; transient classes
  # (`:timeout`, `:rate_limited`, `:http`, `:tls`, `:transport`) self-heal or
  # are GitHub-side and would only spam the operator.
  @escalating_classes [:dns, :auth]

  @escalation_threshold 3

  @base_backoff_ms 1_000
  @max_backoff_ms 60_000

  @type source :: atom()
  @type classification :: atom()
  @type streaks :: %{optional(source()) => {classification(), pos_integer()}}
  @type alert :: %{source: source(), classification: classification(), count: pos_integer()}

  @doc "Consecutive same-class failures required before an operator alert fires."
  @spec escalation_threshold() :: pos_integer()
  def escalation_threshold, do: @escalation_threshold

  @doc "Upper bound on exponential backoff, in milliseconds."
  @spec max_backoff_ms() :: pos_integer()
  def max_backoff_ms, do: @max_backoff_ms

  @doc """
  Records one classified failure for `source`. Returns the updated streak map
  and a (possibly empty) list of operator alerts that should be emitted now.

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
  Returns how long to wait before the next attempt for a classified failure.

    * `:rate_limited` — `retry_after` (seconds) if present, else `poll_interval`,
      else the capped exponential default — all in milliseconds.
    * `:dns` / `:timeout` / `:tls` / `:transport` / `:http` — capped exponential
      backoff that grows with `attempt`.
    * `:auth` — `:escalate` (don't retry an expired/invalid token).
  """
  @spec backoff_ms(classification(), pos_integer(), map()) :: non_neg_integer() | :escalate
  def backoff_ms(:auth, _attempt, _detail), do: :escalate

  def backoff_ms(:rate_limited, attempt, detail) do
    cond do
      is_integer(detail[:retry_after]) and detail[:retry_after] > 0 ->
        detail[:retry_after] * 1_000

      is_integer(detail[:poll_interval]) and detail[:poll_interval] > 0 ->
        detail[:poll_interval] * 1_000

      true ->
        exponential(attempt)
    end
  end

  def backoff_ms(_classification, attempt, _detail), do: exponential(attempt)

  defp exponential(attempt) when is_integer(attempt) and attempt >= 1 do
    min(@base_backoff_ms * 2 ** (attempt - 1), @max_backoff_ms)
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
  Builds the operator-facing alert message for an escalated connectivity
  blocker. Used by pollers to drive `Aiur.Alerts.emit_custom/3`.
  """
  @spec alert_message(alert(), keyword()) :: String.t()
  def alert_message(%{source: source, classification: classification, count: count}, opts \\ []) do
    repo = Keyword.get(opts, :repo)
    repo_suffix = if repo, do: " for #{repo}", else: ""

    "GitHub #{classification_phrase(classification)} from #{source}#{repo_suffix}: " <>
      "#{count} consecutive failures. Agents cannot reach GitHub while the operator shell may. " <>
      "Check DNS/proxy/credentials in the agent workspace environment."
  end

  defp classification_phrase(:dns), do: "DNS resolution failures"
  defp classification_phrase(:auth), do: "authentication failures"
  defp classification_phrase(other), do: "#{other} failures"
end
