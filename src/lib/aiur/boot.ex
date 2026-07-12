defmodule Aiur.Boot do
  @moduledoc """
  Records the monotonic time at which Aiur's BEAM started, so every
  subsystem can emit `elapsed_ms=<N>` in its phase logs. Also mints the
  one opaque `run_id` for this BEAM-lifetime run — every subsystem that
  needs a run identity (audit records, debug telemetry) reads it from
  here instead of minting its own.

  Set once at application start via `mark/0`; readers call `elapsed_ms/0`
  to get a stable millisecond delta from boot. Pure persistent_term, no
  GenServer — readers stay cheap.
  """

  @key {__MODULE__, :start_ms}
  @epoch_key {__MODULE__, :start_epoch_seconds}
  @started_at_key {__MODULE__, :started_at}
  @run_id_key {__MODULE__, :run_id}

  @doc """
  Capture the current monotonic time as the boot reference. Idempotent —
  re-marking is a no-op so test setup that brings Aiur up multiple times
  doesn't lose the original timestamp.
  """
  @spec mark() :: :ok
  def mark do
    case :persistent_term.get(@key, :unset) do
      :unset ->
        # Wall-clock epoch is needed by subsystems that compare against
        # external timestamps (e.g. GitHub event `created_at` for the
        # pre-boot drop filter); `started_at/0` needs sub-second precision
        # for telemetry. Both derive from the same `DateTime.utc_now()` so
        # they can never disagree, alongside the monotonic mark.
        now = DateTime.utc_now()
        :persistent_term.put(@key, System.monotonic_time(:millisecond))
        :persistent_term.put(@epoch_key, DateTime.to_unix(now, :second))
        :persistent_term.put(@started_at_key, now)
        ensure_run_id()
        :ok

      _ ->
        :ok
    end
  end

  @doc """
  Force re-mark — only for test resets. Mints a new `run_id` together
  with the clock reset so a test simulating a reboot within one VM sees
  a new run identity too, not just new clocks.
  """
  @spec remark() :: :ok
  def remark do
    now = DateTime.utc_now()
    :persistent_term.put(@key, System.monotonic_time(:millisecond))
    :persistent_term.put(@epoch_key, DateTime.to_unix(now, :second))
    :persistent_term.put(@started_at_key, now)
    :persistent_term.put(@run_id_key, generate_run_id())
    :ok
  end

  @doc """
  Wall-clock unix epoch seconds at which `mark/0` was called. Returns
  the current epoch when `mark/0` hasn't been called yet — that's only
  hit in tests that bypass application start, where a "right now"
  fallback is the safest behavior for filters that gate on boot time.
  """
  @spec epoch_seconds() :: integer()
  def epoch_seconds do
    case :persistent_term.get(@epoch_key, :unset) do
      :unset -> System.os_time(:second)
      start when is_integer(start) -> start
    end
  end

  @doc """
  Milliseconds elapsed since `mark/0` was called. Returns `0` if
  `mark/0` has not been called yet.
  """
  @spec elapsed_ms() :: integer()
  def elapsed_ms do
    case :persistent_term.get(@key, :unset) do
      :unset -> 0
      start when is_integer(start) -> System.monotonic_time(:millisecond) - start
    end
  end

  @doc """
  Opaque identity for this BEAM-lifetime run. Stable once minted; lazily
  mints and caches on first read if `mark/0` hasn't run yet, so callers
  that bypass full application boot (unit tests) still get one stable
  value per process lifetime.
  """
  @spec run_id() :: String.t()
  def run_id do
    case :persistent_term.get(@run_id_key, :unset) do
      :unset -> ensure_run_id()
      id when is_binary(id) -> id
    end
  end

  @doc """
  Sub-second wall-clock start time of this run. Falls back to "now"
  when `mark/0` hasn't run yet, matching `epoch_seconds/0`'s bypass
  behavior for tests that skip full application boot.
  """
  @spec started_at() :: DateTime.t()
  def started_at do
    case :persistent_term.get(@started_at_key, :unset) do
      :unset -> DateTime.utc_now()
      %DateTime{} = value -> value
    end
  end

  defp ensure_run_id do
    case :persistent_term.get(@run_id_key, :unset) do
      :unset ->
        id = generate_run_id()
        :persistent_term.put(@run_id_key, id)
        id

      id when is_binary(id) ->
        id
    end
  end

  defp generate_run_id do
    12 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end
end
