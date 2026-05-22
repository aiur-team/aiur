defmodule Aiur.Boot do
  @moduledoc """
  Records the monotonic time at which Aiur's BEAM started, so every
  subsystem can emit `elapsed_ms=<N>` in its phase logs.

  Set once at application start via `mark/0`; readers call `elapsed_ms/0`
  to get a stable millisecond delta from boot. Pure persistent_term, no
  GenServer — readers stay cheap.
  """

  @key {__MODULE__, :start_ms}

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
        :ok

      _ ->
        :ok
    end
  end

  @doc "Force re-mark — only for test resets."
  @spec remark() :: :ok
  def remark do
    :persistent_term.put(@key, System.monotonic_time(:millisecond))
    :ok
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
