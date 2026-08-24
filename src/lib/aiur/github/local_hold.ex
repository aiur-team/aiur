defmodule Aiur.GitHub.LocalHold do
  @moduledoc """
  Wait out short, self-clearing local budget holds instead of failing the
  operation that hit them (#2444).

  A local GitHub budget hold is a local counter trip that names its own
  release time (`reset_at`): the request guard throttled a shared resource
  before the request reached GitHub, so the hold is transient by construction
  — GitHub never saw the request, and once `reset_at` passes the next attempt
  is admitted again. Treating it as a terminal failure turned a four-second
  hold into a terminated agent run, a declined dispatch, or a stranded rework
  ticket.

  This is the shared helper the call sites that used to give up on a hold all
  use now — auth preflight, dispatch revalidation and rework re-queue — so
  the wait logic and its bounds live in exactly one place instead of three
  copies of the same loop.

  ## The bounds, and why they are the guard against swallowing the error

  * `max_wait_ms/0` is the ceiling. A hold whose `reset_at` is further out
    than this is a genuine capacity problem, not a transient blip; the
    operation still fails, so waiting can never mask real starvation.
  * `max_waits/0` caps the number of consecutive waits. A pathologically
    re-armed hold (each wait produces a fresh hold) terminates instead of
    pinning the caller indefinitely.
  * `jitter_ms/0` is the max jitter added on top of `reset_at`, so concurrent
    waiters do not all wake and retry at the same instant and re-trip the
    smoother in a stampede.

  A hold whose `reset_at` has already passed by the time the failure is
  produced (the daemon-restart burst) is retried immediately with no sleep.

  ## The error shapes it matches

  `run/2` retries either the raw classified error
  `{:error, {:github, :local_hold, detail}}` produced by
  `Aiur.GitHub.Errors.classify_error/1`, or the auth-preflight diagnostic
  `{:error, %{classification: :local_hold, detail: detail}}`; both carry the
  same hold detail (`%{hold: %{reset_at: ...}}`), and the original shape is
  returned on give-up so each caller keeps its own error contract.
  """

  require Logger

  @max_wait_ms 60_000
  @max_waits 3
  @jitter_ms 500

  @doc "The ceiling: a hold whose reset is beyond this still fails (no starvation masking)."
  @spec max_wait_ms() :: pos_integer()
  def max_wait_ms, do: @max_wait_ms

  @doc "The cap on consecutive waits, so a re-armed hold terminates."
  @spec max_waits() :: pos_integer()
  def max_waits, do: @max_waits

  @doc "The max jitter added on top of a hold's reset, so concurrent waiters desynchronize."
  @spec jitter_ms() :: non_neg_integer()
  def jitter_ms, do: @jitter_ms

  @doc """
  Runs `attempt_fun` and, when it fails with a short self-clearing local
  budget hold, sleeps until the hold's `reset_at` and retries — up to
  `max_waits/0` times, each wait bounded by `max_wait_ms/0`.

  `opts` accepts `:sleep_fun` (default `&Process.sleep/1`), `:max_wait_ms`
  and `:max_waits` for test injection and per-site tuning.
  """
  @spec run((-> term()), keyword()) :: term()
  def run(attempt_fun, opts \\ []) when is_function(attempt_fun, 0) do
    max_wait_ms = Keyword.get(opts, :max_wait_ms, @max_wait_ms)
    max_waits = Keyword.get(opts, :max_waits, @max_waits)
    sleep_fun = Keyword.get(opts, :sleep_fun, &Process.sleep/1)
    do_run(attempt_fun, max_wait_ms, max_waits, sleep_fun)
  end

  @doc false
  # Maps a caller's `local_hold_*` keyword options onto `run/2`'s own opt
  # names, so every call site accepts the same `local_hold_sleep_fun`,
  # `local_hold_max_wait_ms` and `local_hold_max_waits` keys its tests already
  # use.
  @spec caller_opts(keyword()) :: keyword()
  def caller_opts(opts) when is_list(opts) do
    [
      sleep_fun: Keyword.get(opts, :local_hold_sleep_fun, &Process.sleep/1),
      max_wait_ms: Keyword.get(opts, :local_hold_max_wait_ms, max_wait_ms()),
      max_waits: Keyword.get(opts, :local_hold_max_waits, max_waits())
    ]
  end

  @doc false
  # Decides how long to wait for a hold detail map, or `:no_wait` when the
  # hold is beyond the ceiling or does not carry a usable `reset_at`. A
  # `reset_at` already in the past is `{:wait, 0}` — the hold has cleared by
  # the time the failure was produced, so retry immediately.
  @spec wait_ms(map(), pos_integer()) :: {:wait, non_neg_integer()} | :no_wait
  def wait_ms(%{hold: %{reset_at: %DateTime{} = reset_at}}, max_wait_ms) do
    wait_ms =
      DateTime.diff(reset_at, DateTime.utc_now(), :millisecond) +
        :rand.uniform(@jitter_ms + 1) - 1

    if wait_ms > max_wait_ms, do: :no_wait, else: {:wait, max(wait_ms, 0)}
  end

  def wait_ms(_detail, _max_wait_ms), do: :no_wait

  defp do_run(attempt_fun, max_wait_ms, max_waits, sleep_fun) do
    case attempt_fun.() do
      {:error, {:github, :local_hold, detail}} = error ->
        retry_or_keep(error, detail, attempt_fun, max_wait_ms, max_waits, sleep_fun)

      {:error, %{classification: :local_hold, detail: detail}} = error ->
        retry_or_keep(error, detail, attempt_fun, max_wait_ms, max_waits, sleep_fun)

      other ->
        other
    end
  end

  defp retry_or_keep(error, detail, attempt_fun, max_wait_ms, max_waits, sleep_fun) do
    case wait_ms(detail, max_wait_ms) do
      {:wait, wait_ms} when max_waits > 0 ->
        log_and_sleep(detail, wait_ms, sleep_fun)
        do_run(attempt_fun, max_wait_ms, max_waits - 1, sleep_fun)

      _other ->
        error
    end
  end

  defp log_and_sleep(detail, wait_ms, sleep_fun) do
    Logger.info(
      "GitHub call held by local budget, waiting #{wait_ms}ms " <>
        "(reset_at=#{hold_reset_at(detail)}) then retrying"
    )

    if wait_ms > 0, do: sleep_fun.(wait_ms)
  end

  defp hold_reset_at(%{hold: %{reset_at: reset_at}}), do: inspect(reset_at)
  defp hold_reset_at(_detail), do: "(unknown)"
end
