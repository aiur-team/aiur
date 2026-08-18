defmodule Aiur.Executor.Roster do
  @moduledoc """
  Who is listening to the Executor wake stream, and — the part that matters —
  whether they are actually working.

  Multiple executors are a supported configuration, so a peer is information,
  not a fault. The hard case is the stalled one: a backgrounded or wedged
  consumer still holds its claim, still renews its lease, and still appears in
  every list of listeners. A roster derived from presence reports it as fine.

  So state is derived only from evidence, and only positively:

    * `active` — positive evidence that **this** consumer consumed: it
      acknowledged inside the stall window, or its own acknowledgement count
      rose since the previous observation.
    * `idle` — lease live, nothing pending, cursor legitimately still.
    * `stalled` — lease renewing, but acknowledgements are frozen while records
      pile up. This is the "backgrounded stuck" case.
    * `expired` — the lease lapsed; a successor may take over with no operator
      action.
    * `unknown` — the evidence needed to tell is missing. Never upgraded to
      `active`.

  The shared cursor position is reported, and whether it moved, because an
  operator needs it — but movement is deliberately **not** what makes a consumer
  `active`. The cursor is global: it also moves when a *different* consumer
  acknowledges, and when the inbox evicts unread records at its bound. Either
  would have promoted a wedged consumer to `active` on someone else's work.
  Only per-consumer acknowledgement counts as positive evidence.

  There is no rule that returns `active` from the *absence* of a failure
  signal. That shape has already cost this project real time (`SUPERVISION
  99/99 healthy` printed beside a stale fleet view; #2059; #2053).
  """

  alias Aiur.Executor.Claims
  alias Aiur.ExecutorWakeInbox

  @default_stall_after_ms 300_000

  @type entry :: map()

  @doc """
  Builds the roster and records a fresh observation for every consumer.

  The observation is what makes "did this consumer acknowledge anything since
  last time?" answerable on the next read; pass `record?: false` to inspect
  without disturbing it.
  """
  @spec build(keyword()) :: %{cursor: non_neg_integer(), pending_count: non_neg_integer(), executors: [entry()]}
  def build(opts \\ []) do
    now = Keyword.get(opts, :now) || DateTime.utc_now()
    cursor = Keyword.get_lazy(opts, :cursor, fn -> safe_cursor(opts) end)
    pending_count = Keyword.get_lazy(opts, :pending_count, fn -> safe_pending_count(opts) end)
    claim_opts = Keyword.take(opts, [:path, :now])

    executors =
      claim_opts
      |> Claims.entries()
      |> Enum.map(&describe(&1, cursor, pending_count, now, opts))

    if Keyword.get(opts, :record?, true) do
      _ = Claims.record_observations(observation(now, cursor, pending_count, executors), claim_opts)
    end

    %{cursor: cursor, pending_count: pending_count, executors: executors}
  end

  @doc "Human-readable evidence line for one roster entry."
  @spec describe_line(entry()) :: String.t()
  def describe_line(entry) do
    "EXECUTOR #{entry.id} state=#{entry.state} role=#{entry.role} host=#{entry.host} pid=#{entry.pid} " <>
      "claimed_at=#{or_none(entry.claimed_at)} last_renewed_at=#{or_none(entry.last_renewed_at)} " <>
      "last_acknowledged_at=#{or_none(entry.last_acknowledged_at)} acknowledged_count=#{entry.acknowledged_count} " <>
      "pending=#{entry.pending_count} cursor=#{entry.cursor_position} cursor_moved=#{inspect(entry.cursor_moved)}"
  end

  # One observation for the whole roster, written once. Per-consumer
  # acknowledgement counts are recorded alongside the shared readings so the
  # next build can tell each consumer's own progress from everyone else's.
  defp observation(now, cursor, pending_count, executors) do
    %{
      "observed_at" => DateTime.to_iso8601(now),
      "cursor" => cursor,
      "pending" => pending_count,
      "acknowledged_counts" => Map.new(executors, &{&1.id, &1.acknowledged_count})
    }
  end

  defp describe(record, cursor, pending_count, now, opts) do
    previous = record["observation"]

    entry = %{
      id: record["id"],
      role: record["role"] || "observer",
      host: record["host"],
      pid: record["pid"],
      claimed_at: record["claimed_at"],
      last_renewed_at: record["last_renewed_at"],
      last_acknowledged_at: record["last_acknowledged_at"],
      acknowledged_count: record["acknowledged_count"] || 0,
      pending_count: pending_count,
      cursor_position: cursor,
      cursor_moved: cursor_moved(previous, cursor),
      lease_expires_at: record["lease_expires_at"]
    }

    Map.put(entry, :state, derive_state(record, entry, previous, now, opts))
  end

  # Ordering is deliberate. Expiry and missing renewal evidence are answered
  # first, because neither can be overruled by anything below. `active` then
  # requires positive, per-consumer evidence; only after that can a renewing
  # consumer fall through to `stalled`, and `idle` needs an empty queue.
  # Anything left is `unknown` — never `active`.
  defp derive_state(record, entry, previous, now, opts) do
    cond do
      not Claims.live?(record, now) -> :expired
      not is_binary(entry.last_renewed_at) -> :unknown
      consumed?(entry, previous, now, opts) -> :active
      stalled?(entry, previous, now, opts) -> :stalled
      entry.pending_count == 0 and is_binary(entry.claimed_at) -> :idle
      true -> :unknown
    end
  end

  defp consumed?(entry, previous, now, opts) do
    acknowledged_recently?(entry, now, opts) or acknowledged_since?(entry, previous)
  end

  defp acknowledged_recently?(%{last_acknowledged_at: at}, now, opts) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, acked, _offset} -> DateTime.diff(now, acked, :millisecond) <= stall_after_ms(opts)
      _invalid -> false
    end
  end

  defp acknowledged_recently?(_entry, _now, _opts), do: false

  defp acknowledged_since?(entry, %{"acknowledged_counts" => %{} = counts}) do
    case Map.fetch(counts, entry.id) do
      {:ok, before} when is_integer(before) -> entry.acknowledged_count > before
      _absent -> false
    end
  end

  defp acknowledged_since?(_entry, _previous), do: false

  # Two independent witnesses of a stall, both requiring a live lease and a
  # non-empty queue: the queue grew since the previous observation while nothing
  # was acknowledged, or nothing has been acknowledged for longer than the stall
  # window since the claim was taken.
  defp stalled?(%{pending_count: 0}, _previous, _now, _opts), do: false

  defp stalled?(entry, previous, now, opts) do
    grew? = is_map(previous) and is_integer(previous["pending"]) and entry.pending_count > previous["pending"]
    grew? or overdue?(entry, now, opts)
  end

  defp overdue?(entry, now, opts) do
    reference = entry.last_acknowledged_at || entry.claimed_at

    case reference && DateTime.from_iso8601(reference) do
      {:ok, at, _offset} -> DateTime.diff(now, at, :millisecond) > stall_after_ms(opts)
      _unusable -> false
    end
  end

  defp cursor_moved(%{"cursor" => before}, cursor) when is_integer(before), do: cursor > before
  defp cursor_moved(_previous, _cursor), do: nil

  defp stall_after_ms(opts),
    do: Keyword.get(opts, :stall_after_ms) || Application.get_env(:aiur, :executor_stall_after_ms, @default_stall_after_ms)

  defp safe_cursor(opts) do
    ExecutorWakeInbox.cursor(Keyword.get(opts, :inbox, ExecutorWakeInbox))
  catch
    _kind, _reason -> 0
  end

  defp safe_pending_count(opts) do
    length(ExecutorWakeInbox.pending(Keyword.get(opts, :inbox, ExecutorWakeInbox)))
  catch
    _kind, _reason -> 0
  end

  defp or_none(nil), do: "none"
  defp or_none(value), do: value
end
