defmodule Aiur.GitHub.LocalHold do
  @moduledoc """
  Wait out short, self-clearing local budget holds and budget broker timeouts
  instead of failing the operation that hit them (#2444, #2457).

  A local GitHub budget hold is a local counter trip that names its own
  release time (`reset_at`): the request guard throttled a shared resource
  before the request reached GitHub, so the hold is transient by construction
  — GitHub never saw the request, and once `reset_at` passes the next attempt
  is admitted again. Treating it as a terminal failure turned a four-second
  hold into a terminated agent run, a declined dispatch, or a stranded rework
  ticket.

  A budget broker timeout (`:github_budget_broker_timeout`) is the same
  situation one layer down: the broker was asked for admission and never
  answered before its deadline, which is a recoverable infrastructure fault
  rather than a terminal one. It is already classified transient by the shared
  classifier (#2430); it just has no `reset_at` to aim at, so it is backed off
  instead of waited out to a deadline — same bound, same attempt cap, same
  fail-closed.

  This is the shared helper the call sites that used to give up on a fault all
  use now — auth preflight, dispatch revalidation and rework re-queue — so
  the wait logic and its bounds live in exactly one place instead of three
  copies of the same loop.

  ## The bounds, and why they are the guard against swallowing the error

  * `max_wait_ms/0` is the ceiling. A hold whose `reset_at` is further out
    than this is a genuine capacity problem, not a transient blip; the
    operation still fails, so waiting can never mask real starvation. A
    broker-timeout backoff never exceeds this ceiling either.
  * `max_waits/0` caps the number of consecutive waits. A pathologically
    re-armed hold — or a persistently unreachable broker — terminates instead
    of pinning the caller indefinitely.
  * `jitter_ms/0` is the max jitter added on top of a `reset_at` or a backoff,
    so concurrent waiters do not all wake and retry at the same instant and
    re-trip the smoother in a stampede.

  A hold whose `reset_at` has already passed by the time the failure is
  produced (the daemon-restart burst) is retried immediately with no sleep.

  ## The error shapes it matches

  `run/2` retries the transient budget-layer faults in both the raw classified
  form `{:error, {:github, kind, detail}}` produced by
  `Aiur.GitHub.Errors.classify_error/1` and the auth-preflight diagnostic form
  `{:error, %{classification: kind, detail: detail}}`:

    * a local budget hold — waited out to its `reset_at`
      (`{:github, :local_hold, %{hold: %{reset_at: ...}}}`);
    * a budget broker timeout — backed off
      (`{:github, :timeout, %{reason: :github_budget_broker_timeout}}`).

  A malformed broker reply (`:github_budget_broker_unavailable`) is permanent
  and passes through unchanged, as does anything outside the budget layer. The
  transient verdict routes through `Errors.retryable_github_error?/1` — the
  single shared source of truth for this taxonomy (#2430) — so `run/2` never
  carries its own copy of what is transient. The original error shape is
  returned on give-up so each caller keeps its own error contract.
  """

  require Logger

  alias Aiur.GitHub.Errors

  @max_wait_ms 60_000
  @max_waits 3
  @jitter_ms 500
  # Base of the exponential broker-timeout backoff: the first wait is this,
  # each subsequent wait doubles it (capped at `max_wait_ms`).
  @backoff_base_ms 1_000

  @doc "The ceiling: a hold whose reset is beyond this still fails (no starvation masking)."
  @spec max_wait_ms() :: pos_integer()
  def max_wait_ms, do: @max_wait_ms

  @doc "The cap on consecutive waits, so a re-armed hold terminates."
  @spec max_waits() :: pos_integer()
  def max_waits, do: @max_waits

  @doc "The max jitter added on top of a hold's reset, so concurrent waiters desynchronize."
  @spec jitter_ms() :: non_neg_integer()
  def jitter_ms, do: @jitter_ms

  @doc "The base of the exponential budget-broker-timeout backoff."
  @spec backoff_base_ms() :: pos_integer()
  def backoff_base_ms, do: @backoff_base_ms

  @doc """
  Runs `attempt_fun` and, when it fails with a short self-clearing local
  budget hold or a budget broker timeout, sleeps and retries — up to
  `max_waits/0` times, each wait bounded by `max_wait_ms/0`. A hold is waited
  out to its `reset_at`; a broker timeout (no `reset_at`) is backed off with
  an exponential backoff starting at `backoff_base_ms/0`.

  `opts` accepts `:sleep_fun` (default `&Process.sleep/1`), `:max_wait_ms`
  and `:max_waits` for test injection and per-site tuning.
  """
  @spec run((-> term()), keyword()) :: term()
  def run(attempt_fun, opts \\ []) when is_function(attempt_fun, 0) do
    max_wait_ms = Keyword.get(opts, :max_wait_ms, @max_wait_ms)
    max_waits = Keyword.get(opts, :max_waits, @max_waits)
    sleep_fun = Keyword.get(opts, :sleep_fun, &Process.sleep/1)
    do_run(attempt_fun, max_wait_ms, max_waits, sleep_fun, 0)
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

  # `retries` is the number of waits already consumed, so the broker-timeout
  # backoff can grow exponentially across consecutive retries.
  defp do_run(attempt_fun, max_wait_ms, max_waits, sleep_fun, retries) do
    case attempt_fun.() do
      {:error, error} = full_error ->
        case retry_plan(error, max_wait_ms, max_waits, retries) do
          {:wait, wait_ms, detail} ->
            log_and_sleep(detail, wait_ms, sleep_fun)
            do_run(attempt_fun, max_wait_ms, max_waits - 1, sleep_fun, retries + 1)

          :keep ->
            full_error
        end

      other ->
        other
    end
  end

  # Decides whether a budget-layer fault is worth waiting out. The transient
  # verdict routes through `Errors.retryable_github_error?/1` — the single
  # shared source of truth for this taxonomy (#2430) — so `run/2` never
  # carries its own copy of what is transient. Within that:
  #
  #   * a local budget hold carries its own `reset_at`, so it is waited out to
  #     that deadline (bounded by `max_wait_ms`);
  #   * a budget broker timeout has no `reset_at`, so it is backed off instead
  #     (#2457) — same bound, same attempt cap, same fail-closed;
  #   * a malformed broker reply (`:github_budget_broker_unavailable`) is
  #     permanent per the classifier and fails closed, as does anything
  #     outside the budget layer.
  #
  # Returns `{:wait, wait_ms, detail}` when the fault should be slept off and
  # retried, or `:keep` to pass the original error through unchanged.
  defp retry_plan(error, max_wait_ms, max_waits, retries) when max_waits > 0 do
    case budget_layer_fault(error) do
      {:hold, detail} ->
        hold_plan(detail, max_wait_ms)

      {:backoff, detail} ->
        if Errors.retryable_github_error?({:github, :timeout, detail}) do
          {:wait, backoff_ms(detail, max_wait_ms, retries), detail}
        else
          :keep
        end

      _permanent_or_other ->
        :keep
    end
  end

  defp retry_plan(_error, _max_wait_ms, _max_waits, _retries), do: :keep

  # A local budget hold is waited out to its `reset_at` (bounded by
  # `max_wait_ms`) when the shared classifier still calls it transient; a hold
  # beyond the ceiling, or one the classifier no longer considers transient,
  # fails closed.
  defp hold_plan(detail, max_wait_ms) do
    if Errors.retryable_github_error?({:github, :local_hold, detail}) do
      case wait_ms(detail, max_wait_ms) do
        {:wait, wait_ms} -> {:wait, wait_ms, detail}
        :no_wait -> :keep
      end
    else
      :keep
    end
  end

  # Recognizes the transient budget-layer fault families `run/2` waits out, in
  # both the raw classified error shape and the auth-preflight diagnostic
  # shape:
  #
  #   * `{:hold, detail}` — a local budget hold, waited out to its `reset_at`;
  #   * `{:backoff, detail}` — a budget broker timeout, backed off;
  #   * `:permanent` — a recognized budget-layer fault that must fail closed
  #     (a malformed broker reply);
  #   * `:none` — anything outside the budget layer, passed through unchanged.
  #
  # This matches the fault *shapes*, not a transient-reason list: what is
  # transient stays the classifier's job (see `retry_plan/4`).
  defp budget_layer_fault({:github, :local_hold, detail}), do: {:hold, detail}

  defp budget_layer_fault({:github, :timeout, %{reason: :github_budget_broker_timeout} = detail}),
    do: {:backoff, detail}

  defp budget_layer_fault({:github, :transport, %{reason: :github_budget_broker_unavailable}}),
    do: :permanent

  # The auth-preflight diagnostic carries the classification in `classification`
  # and the classified tuple's detail map in `detail`; a held diagnostic
  # carries the hold map directly in `detail`.
  defp budget_layer_fault(%{classification: :local_hold, detail: detail}), do: {:hold, detail}

  defp budget_layer_fault(%{classification: :timeout, detail: %{reason: :github_budget_broker_timeout} = detail}),
    do: {:backoff, detail}

  defp budget_layer_fault(%{classification: :transport, detail: %{reason: :github_budget_broker_unavailable}}),
    do: :permanent

  defp budget_layer_fault(_error), do: :none

  # Exponential backoff for a fault with no `reset_at`, capped at the same
  # per-wait ceiling as the hold path and jittered so concurrent waiters
  # desynchronize. `retries` is the number of waits already consumed, so the
  # first wait is `backoff_base_ms`, each subsequent wait doubles.
  defp backoff_ms(_detail, max_wait_ms, retries) do
    scaled = @backoff_base_ms * Integer.pow(2, retries)
    min(scaled, max_wait_ms) + :rand.uniform(@jitter_ms + 1) - 1
  end

  defp log_and_sleep(detail, wait_ms, sleep_fun) do
    Logger.info("GitHub call #{wait_kind(detail)}, waiting #{wait_ms}ms then retrying")

    if wait_ms > 0, do: sleep_fun.(wait_ms)
  end

  defp wait_kind(%{hold: %{reset_at: reset_at}}),
    do: "held by local budget (reset_at=#{inspect(reset_at)})"

  defp wait_kind(_detail), do: "blocked on a budget broker timeout"
end
