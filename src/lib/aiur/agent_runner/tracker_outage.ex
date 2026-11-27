defmodule Aiur.AgentRunner.TrackerOutage do
  @moduledoc """
  Rides out a GitHub outage (5xx, timeout, DNS, TLS, dropped connection)
  without giving up the ticket.

  A worker whose between-turn state refresh fails this way keeps its session
  and retries the refresh with backoff, and the orchestrator's retry poll keeps
  the claim and keeps polling. Each raises one attention once the outage has
  lasted `alert_after_ms/0`. A rate limit, a local budget hold and a permanent
  refusal (401, 403, 404) are not outages; they keep their own handling.
  """

  require Logger

  alias Aiur.GitHub.Access
  alias Aiur.Signal

  @alert_after_ms 15 * 60 * 1_000
  @refresh_backoff_base_ms 10_000
  @refresh_backoff_max_ms 120_000

  @type t :: %{since_ms: integer(), failures: pos_integer(), alerted?: boolean()}

  @doc "How long an outage lasts before it raises an attention."
  @spec alert_after_ms() :: pos_integer()
  def alert_after_ms, do: @alert_after_ms

  @doc "The attention topic for `identifier`'s tracker outage."
  @spec topic(String.t()) :: String.t()
  def topic(identifier), do: "ticket.#{identifier}.agent.attention.tracker-outage"

  @doc "Whether `reason` is a GitHub outage worth waiting out rather than a refusal."
  @spec outage?(term()) :: boolean()
  def outage?({:issue_state_refresh_failed, reason}), do: outage?(reason)
  def outage?({:github, kind, _detail}) when kind in [:rate_limited, :local_hold], do: false
  def outage?({:github, :transport, %{reason: {:aiur, :locally_held, _hold}}}), do: false
  def outage?({:aiur, :locally_held, _hold}), do: false
  def outage?({:github_api_status, 429}), do: false
  def outage?(reason), do: Access.transient_github_error?(reason)

  @doc """
  Counts one failure of an outage that started at `outage.since_ms` (or now),
  raising the attention once it has lasted `alert_after_ms/0`.
  """
  @spec note(t() | nil, String.t(), term(), integer()) :: t()
  def note(outage, identifier, reason, now_ms) when is_integer(now_ms) do
    outage = outage || %{since_ms: now_ms, failures: 0, alerted?: false}
    outage = %{outage | failures: outage.failures + 1}

    if not outage.alerted? and now_ms - outage.since_ms >= @alert_after_ms,
      do: %{outage | alerted?: emit(identifier, outage, reason, now_ms) == :ok},
      else: outage
  end

  @doc """
  Fetches `issue`'s state, waiting out a GitHub outage with backoff instead of
  returning its error, so a live worker keeps its session through it.
  """
  @spec refresh(Aiur.Issue.t(), (list() -> term()), keyword()) :: term()
  def refresh(issue, fetcher, opts \\ []) do
    sleep = Keyword.get(opts, :sleep_fun, &Process.sleep/1)
    now_ms = Keyword.get(opts, :now_ms_fun, fn -> System.monotonic_time(:millisecond) end)

    do_refresh(issue, fetcher, sleep, now_ms, nil)
  end

  defp do_refresh(issue, fetcher, sleep, now_ms, outage) do
    case fetcher.([issue.id]) do
      {:error, reason} = error ->
        if outage?(reason) do
          outage = note(outage, issue.identifier, reason, now_ms.())
          delay_ms = refresh_backoff_ms(outage.failures)

          Logger.warning(
            "Tracker refresh failed for issue_id=#{issue.id} issue_identifier=#{issue.identifier} failure=#{outage.failures}; " <>
              "keeping the session and retrying in #{delay_ms}ms tracker_error=#{inspect(reason)}"
          )

          sleep.(delay_ms)
          do_refresh(issue, fetcher, sleep, now_ms, outage)
        else
          error
        end

      result ->
        result
    end
  end

  @doc false
  @spec refresh_backoff_ms(pos_integer()) :: pos_integer()
  def refresh_backoff_ms(failures) when is_integer(failures) and failures > 0 do
    min(@refresh_backoff_base_ms * Integer.pow(2, min(failures - 1, 10)), @refresh_backoff_max_ms)
  end

  defp emit(identifier, outage, reason, now_ms) do
    minutes = div(now_ms - outage.since_ms, 60_000)

    message =
      "Ticket #{identifier} cannot reach GitHub for #{minutes} min (#{outage.failures} failed tracker calls; " <>
        "last error #{inspect(reason)}). Aiur keeps the claim and the workspace and keeps retrying."

    Logger.warning(message)

    Signal.alert(topic(identifier),
      issue: identifier,
      message: message,
      reason: message,
      needs_attention: true,
      severity: "warning",
      central: true
    )
  end
end
