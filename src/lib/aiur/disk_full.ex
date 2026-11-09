defmodule Aiur.DiskFull do
  @moduledoc """
  Turns a daemon-owned write that fails with `:enospc` into one
  `system.disk.pressure` alert naming the path, instead of a crash (#7925).

  The shared write helpers (`Aiur.Fs.atomic_write/3`, `Aiur.Journal`) pass
  every result through `observe/2`. The first `:enospc` opens an episode and
  raises the alert; later failures in the same episode are silent. The next
  successful write closes the episode, so writes resume without operator
  action, and a fresh failure after at least `@realert_ms` alerts again. The
  failed write itself is dropped by its caller, which already handles
  `{:error, _}`.

  State is two atomics, not a process, so a write in any process (including
  the alert path's own writes) never waits on or crashes a server. The alert
  runs in a detached task for the same reason.
  """

  require Logger

  @topic "system.disk.pressure"
  @key {__MODULE__, :state}
  @realert_ms 10 * 60_000

  @doc "Passes `result` through, recording an `:enospc` failure or a recovery for `path`."
  @spec observe(Path.t(), result) :: result when result: term()
  def observe(path, {_outcome, :enospc} = result) do
    failed(path)
    result
  end

  def observe(_path, result) when result in [:ok, :accepted] do
    ref = state()
    if :atomics.compare_exchange(ref, 1, 1, 0) == :ok, do: Logger.info("disk_full: writes succeed again; space returned")
    result
  end

  def observe(_path, result), do: result

  @doc "Records an `:enospc` failure for `path`; raises the alert once per episode."
  @spec failed(Path.t()) :: :ok
  def failed(path) do
    ref = state()
    now = System.monotonic_time(:millisecond)
    last = :atomics.get(ref, 2)

    if :atomics.compare_exchange(ref, 1, 0, 1) == :ok and (last == 0 or now - last >= Application.get_env(:aiur, :disk_full_realert_ms, @realert_ms)) do
      :atomics.put(ref, 2, now)
      alert = Application.get_env(:aiur, :disk_full_alert_fun, &emit/2)
      {:ok, _pid} = Task.start(fn -> alert.(@topic, alert_opts(path)) end)
    end

    :ok
  end

  @doc false
  @spec reset() :: :ok
  def reset do
    ref = state()
    :atomics.put(ref, 1, 0)
    :atomics.put(ref, 2, 0)
  end

  # The kernel sits below the alert pipeline, so it reaches the configured sink the way `Aiur.Signal` does.
  defp emit(topic, opts) do
    case Application.get_env(:aiur, :signal, [])[:alert_sink] do
      nil -> :ok
      sink -> sink.emit_system(topic, opts)
    end
  end

  defp alert_opts(path) do
    [
      message: "Disk full: a daemon write to #{path} failed",
      reason: "No space left on device writing #{path}. The daemon keeps running and drops writes that fail until space returns.",
      severity: "critical",
      needs_attention: true
    ]
  end

  # ponytail: two first callers can race to create the ref; the loser's single write is unlatched, which costs at most one extra alert.
  defp state do
    case :persistent_term.get(@key, nil) do
      nil ->
        ref = :atomics.new(2, signed: true)
        :persistent_term.put(@key, ref)
        ref

      ref ->
        ref
    end
  end
end
