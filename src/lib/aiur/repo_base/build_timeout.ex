defmodule Aiur.RepoBase.BuildTimeout do
  @moduledoc false

  alias Aiur.Config

  @default_minutes 60
  @milliseconds_per_minute 60_000
  @max_timer_ms 4_294_967_294

  @spec timeout_ms(pos_integer() | nil) :: pos_integer()
  def timeout_ms(override_ms) when is_integer(override_ms) and override_ms > 0, do: override_ms

  def timeout_ms(nil) do
    case Config.settings() do
      {:ok, settings} -> settings.prewarm.build_timeout_minutes * @milliseconds_per_minute
      _ -> @default_minutes * @milliseconds_per_minute
    end
  end

  @spec deadline(pos_integer()) :: integer()
  def deadline(timeout_ms), do: System.monotonic_time(:millisecond) + timeout_ms

  @spec build_state(pid(), reference(), reference(), reference(), integer(), pos_integer()) :: map()
  def build_state(pid, ref, timeout_ref, timer, deadline, timeout_ms) do
    %{pid: pid, ref: ref, timeout_ref: timeout_ref, head: nil, os_pid: nil, os_processes: %{}, timer: timer, deadline: deadline, timeout_ms: timeout_ms}
  end

  @spec remaining(integer()) :: integer()
  def remaining(deadline), do: deadline - System.monotonic_time(:millisecond)

  @spec schedule(pid(), reference(), integer()) :: reference()
  def schedule(server, build_ref, deadline) do
    delay = deadline |> remaining() |> max(0) |> min(@max_timer_ms)
    Process.send_after(server, {:build_hold_timeout, build_ref}, delay)
  end
end
