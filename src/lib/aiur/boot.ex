defmodule Aiur.Boot do
  @moduledoc """
  Records the monotonic time at which Aiur's BEAM started, so every
  subsystem can emit `elapsed_ms=<N>` in its phase logs.

  Set once at application start via `mark/0`; readers call `elapsed_ms/0`
  to get a stable millisecond delta from boot. Pure persistent_term, no
  GenServer — readers stay cheap.
  """

  @key {__MODULE__, :start_ms}
  @epoch_key {__MODULE__, :start_epoch_seconds}

  @doc """
  Capture the current monotonic time as the boot reference. Idempotent —
  re-marking is a no-op so test setup that brings Aiur up multiple times
  doesn't lose the original timestamp.
  """
  @spec mark() :: :ok
  def mark do
    case :persistent_term.get(@key, :unset) do
      :unset ->
        :persistent_term.put(@key, System.monotonic_time(:millisecond))
        # Wall-clock epoch is needed by subsystems that compare against
        # external timestamps (e.g. GitHub event `created_at` for the
        # pre-boot drop filter). Stored alongside the monotonic mark so
        # both readers stay cheap and consistent.
        :persistent_term.put(@epoch_key, System.os_time(:second))
        :ok

      _ ->
        :ok
    end
  end

  @doc "Force re-mark — only for test resets."
  @spec remark() :: :ok
  def remark do
    :persistent_term.put(@key, System.monotonic_time(:millisecond))
    :persistent_term.put(@epoch_key, System.os_time(:second))
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
end
