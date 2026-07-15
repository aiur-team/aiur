defmodule Aiur.Opencode.ChatCompletions.StreamPolicy do
  @moduledoc """
  Pure close/idle/watchdog decisions plus the timing constants behind them.

  All functions are pure — no process interaction, no side effects. Every
  threshold is an `Application.get_env/3` override so live tuning needs no
  code change; the defaults encode the values validated against opencode 1.17.x.
  """

  @watchdog_ms 600_000
  # Segmented turn streams: close the per-turn SSE at natural boundaries so
  # opencode flushes its TUI-local input queue between segments (typed
  # Executor text otherwise sits QUEUED for the whole turn). A continuation
  # marker (`__aiur_turn__:<parent>-s<N>`) posted just before the close
  # re-opens streaming for the rest of the turn. Threshold is app-env so
  # live tuning needs no code change.
  @default_segment_threshold_ms 20_000
  # SSE keepalive interval. Empirically opencode-attach's HTTP client
  # times out the chat-completion request after ~28-30s of silence and
  # reopens it, which used to create multiple bridge subscribers (3x
  # rendering of every transcript event). Sending an empty-delta chunk
  # well under that timeout keeps the connection warm so each turn has
  # exactly one bridge process.
  @heartbeat_ms 15_000
  # An empty continuation segment (one that has streamed nothing yet) still
  # idle-closes so queued Executor input flushes during a long quiet claude-repl
  # thinking phase — but only after this many heartbeats of silence, so a slow
  # tool run with nothing to flush churns at most one marker per ~2 heartbeats.
  @empty_continuation_idle_factor 2

  @spec watchdog_ms() :: pos_integer()
  def watchdog_ms, do: @watchdog_ms

  @spec heartbeat_ms() :: pos_integer()
  def heartbeat_ms, do: @heartbeat_ms

  @spec empty_continuation_idle_factor() :: pos_integer()
  def empty_continuation_idle_factor, do: @empty_continuation_idle_factor

  @spec segment_threshold_ms() :: pos_integer()
  def segment_threshold_ms do
    Application.get_env(:aiur, :turn_segment_threshold_ms, @default_segment_threshold_ms)
  end

  @doc false
  # Event-driven segment boundary: true when the just-streamed event is a
  # tool/command block end (a natural chat-block boundary for both the codex
  # and claude-repl event shapes) and the segment has been open at least
  # `threshold_ms`. Pure so tests need no Plug scaffolding.
  @spec segment_boundary?(atom(), non_neg_integer(), pos_integer()) :: boolean()
  def segment_boundary?(role, elapsed_ms, threshold_ms) do
    role in [:tool, :command] and elapsed_ms >= threshold_ms
  end

  @doc false
  # Idle boundary, evaluated on heartbeat ticks: the segment is older than
  # the threshold AND event-silent for at least one heartbeat. Only a
  # segment that streamed content (or the turn-opening segment 0, so a
  # quiet turn start can't strand typed input) may idle-close — an empty
  # continuation segment closing on idle would churn markers through a
  # long silent tool run.
  @spec idle_segment_boundary?(
          boolean(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          pos_integer(),
          pos_integer()
        ) :: boolean()
  def idle_segment_boundary?(streamed?, seg_n, elapsed_ms, silent_ms, threshold_ms, heartbeat_ms) do
    # Streamed content (or the turn-opening segment 0) flushes after the
    # threshold plus one heartbeat of silence. An empty continuation segment
    # waits a longer silence before flushing, so a slow quiet tool run doesn't
    # churn a marker every heartbeat — but it still eventually flushes typed
    # Executor input rather than stranding it for the whole thinking phase.
    required_silence =
      if streamed? or seg_n == 0,
        do: heartbeat_ms,
        else: @empty_continuation_idle_factor * heartbeat_ms

    elapsed_ms >= threshold_ms and silent_ms >= required_silence
  end

  @doc false
  # Decide what the `{:turn_watchdog}` timer does when it fires, given how
  # long the stream has been event-silent (`silent_ms` — bumped only by real
  # transcript/event deltas, never by the 15s heartbeat). At/over the window
  # we `{:close, silent_ms}` (idle-close); otherwise `{:reschedule, delay_ms}`
  # for the remaining window so an actively-streaming turn is never cut at the
  # 10-minute mark. `delay_ms` is always strictly positive (the reschedule
  # branch only runs when `silent_ms < watchdog_ms`). Pure so the close-vs-
  # reschedule arithmetic is unit-testable without Plug/process scaffolding.
  @spec watchdog_action(non_neg_integer(), pos_integer()) ::
          {:close, non_neg_integer()} | {:reschedule, pos_integer()}
  def watchdog_action(silent_ms, watchdog_ms) do
    if silent_ms >= watchdog_ms do
      {:close, silent_ms}
    else
      {:reschedule, watchdog_ms - silent_ms}
    end
  end
end
